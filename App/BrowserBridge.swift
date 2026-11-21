// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import UIKit
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage
import CryptoKit

func browserOutputCallback(
    _ decompressionOutputRefCon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTDecodeInfoFlags,
    _ imageBuffer: CVImageBuffer?,
    _ presentationTimeStamp: CMTime,
    _ duration: CMTime
) {
    guard status == noErr, let decompressionOutputRefCon, let imageBuffer else { return }
    let bridge = Unmanaged<BrowserBridge>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
    bridge.handleDecodedFrame(imageBuffer)
}

final class BrowserBridge {

    private let queue = DispatchQueue(label: "TDSCarKit.browser")
    private var listener: NWListener?
    private var clients: [Client] = []

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var ciContext: CIContext?
    private var lastEmit = Date.distantPast
    private var videoSize = CGSize(width: 1280, height: 720)

    var onTouch: ((UInt16, UInt16, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    func start(port: UInt16) {
        queue.async { [weak self] in self?.startOnQueue(port: port) }
    }

    func push(accessUnit: Data) {
        queue.async { [weak self] in self?.decode(accessUnit) }
    }

    func reset() {
        queue.async { [weak self] in self?.teardownDecoder() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardownDecoder()
            self?.listener?.cancel()
            self?.listener = nil
            self?.clients.removeAll()
        }
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Decode

    private func decode(_ accessUnit: Data) {
        guard let nals = try? AnnexB.units(in: accessUnit) else { return }
        var pictures: [Data] = []
        var changed = false

        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7:
                if sps != nal { sps = nal; changed = true }
            case 8:
                if pps != nal { pps = nal; changed = true }
            default:
                pictures.append(nal)
            }
        }

        if (changed || format == nil), let sps, let pps {
            setupDecoder(sps: sps, pps: pps)
        }

        guard !pictures.isEmpty, let format, let session else { return }
        guard let avcc = try? AnnexB.lengthPrefixed(pictures) else { return }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { return }

        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { return }

        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }

    private func setupDecoder(sps: Data, pps: Data) {
        teardownDecoder()

        var newFormat: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { sRaw in
            pps.withUnsafeBytes { pRaw in
                guard let s = sRaw.bindMemory(to: UInt8.self).baseAddress,
                      let p = pRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                let pointers: [UnsafePointer<UInt8>] = [s, p]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else {
            onLog?("Browser bridge: H.264 parameters rejected (\(status))")
            return
        }

        let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
        videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferWidthKey: Int(dims.width),
            kCVPixelBufferHeightKey: Int(dims.height),
        ]

        let outputCallback: VTDecompressionOutputCallback = browserOutputCallback
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &newSession)

        guard createStatus == noErr, let newSession else {
            onLog?("Browser bridge: decoder session failed (\(createStatus))")
            return
        }

        format = newFormat
        session = newSession
        ciContext = nil
        onLog?("Browser bridge: video decoder ready \(Int(dims.width))×\(Int(dims.height))")
    }

    fileprivate func handleDecodedFrame(_ imageBuffer: CVImageBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 1.0 / 15.0 else { return }
        lastEmit = now

        if ciContext == nil {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        guard let ciContext else { return }

        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6)
        broadcast(jpeg)
    }

    private func teardownDecoder() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        sps = nil
        pps = nil
        ciContext = nil
    }

    // MARK: - Server

    private func startOnQueue(port: UInt16) {
        do {
            let params = NWParameters.tcp
            let candidate = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            candidate.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate else { return }
                switch state {
                case .ready:
                    let actualPort = candidate.port?.rawValue ?? port
                    let host = ReceiverConfiguration.localIPv4Addresses().first ?? "<设备IP>"
                    self.onLog?("Browser display ready: http://\(host):\(actualPort)")
                case .failed(let error):
                    if case .posix(.EADDRINUSE) = error {
                        self.onLog?("Browser bridge port \(port) is busy; using a free port")
                        candidate.cancel()
                        self.listener = nil
                        self.startOnQueue(port: 0)
                    } else {
                        self.onLog?("Browser bridge failed: \(error.localizedDescription)")
                    }
                default:
                    break
                }
            }
            self.listener = candidate
            candidate.start(queue: queue)
        } catch {
            onLog?("Browser bridge failed: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        client.server = self
        clients.append(client)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready: client.beginReceiving()
            case .failed, .cancelled: self.remove(client)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ client: Client) {
        clients.removeAll { $0 === client }
    }

    private func broadcast(_ jpeg: Data?) {
        guard let jpeg, !jpeg.isEmpty else { return }
        let packet = Client.encodeFrame(opcode: 0x2, payload: jpeg)
        for client in clients where client.phase == .websocket {
            client.send(data: packet)
        }
    }

    private func announceSize() {
        let payload = try? JSONSerialization.data(withJSONObject: [
            "type": "size", "w": Int(videoSize.width), "h": Int(videoSize.height)
        ])
        guard let payload else { return }
        let packet = Client.encodeFrame(opcode: 0x1, payload: payload)
        for client in clients where client.phase == .websocket {
            client.send(data: packet)
        }
    }

    static let webPage = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<title>TDS Car Kit Browser</title>
<style>
html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}
canvas{display:block;width:100%;height:100%;touch-action:none;}
#pill{position:fixed;top:12px;left:50%;transform:translateX(-50%);background:rgba(0,0,0,.6);color:#fff;font-size:13px;padding:6px 14px;border-radius:999px;z-index:5;}
#pill.ok{color:#6ee787;}
#pill.err{color:#ff7b72;}
</style>
</head>
<body>
<div id="pill">正在连接…</div>
<canvas id="cv"></canvas>
<script>
(function(){
  var canvas=document.getElementById('cv');
  var ctx=canvas.getContext('2d');
  var pill=document.getElementById('pill');
  var img=new Image();
  var hasFrame=false;
  var VW=1280,VH=720;
  var ws=null;
  var active=false;
  var proto=location.protocol==='https:'?'wss:':'ws:';
  var wsUrl=proto+'//'+location.host+'/ws';

  function setPill(text,state){pill.textContent=text;pill.className=(state===true)?'ok':(state===false?'err':'');}

  function draw(){
    var cw=canvas.width,ch=canvas.height;
    if(cw===0||ch===0)return;
    var scale=Math.min(cw/VW,ch/VH);
    var dw=VW*scale,dh=VH*scale;
    var ox=(cw-dw)/2,oy=(ch-dh)/2;
    ctx.fillStyle='#000';
    ctx.fillRect(0,0,cw,ch);
    ctx.drawImage(img,ox,oy,dw,dh);
  }

  function resize(){
    var dpr=window.devicePixelRatio||1;
    canvas.width=Math.floor(window.innerWidth*dpr);
    canvas.height=Math.floor(window.innerHeight*dpr);
    canvas.style.width=window.innerWidth+'px';
    canvas.style.height=window.innerHeight+'px';
    if(hasFrame){draw();}
  }

  function open(){
    ws=new WebSocket(wsUrl);
    ws.binaryType='arraybuffer';
    ws.onopen=function(){setPill('已连接，可触摸操作',true);};
    ws.onclose=function(){setPill('连接断开，正在重连…',false);setTimeout(open,1500);};
    ws.onerror=function(){};
    ws.onmessage=function(ev){
      if(typeof ev.data==='string'){
        try{
          var msg=JSON.parse(ev.data);
          if(msg.type==='size'){VW=msg.w;VH=msg.h;if(hasFrame){draw();}}
        }catch(e){}
        return;
      }
      var blob=new Blob([ev.data],{type:'image/jpeg'});
      var url=URL.createObjectURL(blob);
      img.onload=function(){hasFrame=true;draw();URL.revokeObjectURL(url);};
      img.src=url;
    };
  }

  function send(down,x,y){
    if(ws&&ws.readyState===WebSocket.OPEN){
      ws.send(JSON.stringify({type:'touch',x:Math.round(x),y:Math.round(y),down:down}));
    }
  }

  function norm(ev){
    var cw=canvas.width,ch=canvas.height;
    var scale=Math.min(cw/VW,ch/VH);
    var dw=VW*scale,dh=VH*scale;
    var ox=(cw-dw)/2,oy=(ch-dh)/2;
    var px=ev.clientX*(cw/window.innerWidth);
    var py=ev.clientY*(ch/window.innerHeight);
    var nx=(px-ox)/dw,ny=(py-oy)/dh;
    nx=Math.max(0,Math.min(1,nx));
    ny=Math.max(0,Math.min(1,ny));
    return [nx*(VW-1),ny*(VH-1)];
  }

  canvas.addEventListener('pointerdown',function(ev){
    if(active){return;}
    active=true;
    if(canvas.setPointerCapture){canvas.setPointerCapture(ev.pointerId);}
    var n=norm(ev);send(true,n[0],n[1]);
  });
  canvas.addEventListener('pointermove',function(ev){
    if(!active){return;}
    var n=norm(ev);send(true,n[0],n[1]);
  });
  canvas.addEventListener('pointerup',function(ev){
    if(!active){return;}
    active=false;
    var n=norm(ev);send(false,n[0],n[1]);
  });
  canvas.addEventListener('pointercancel',function(ev){
    active=false;
    var n=norm(ev);send(false,n[0],n[1]);
  });

  window.addEventListener('resize',resize);
  resize();
  open();
})();
</script>
</body>
</html>
"""
}

// MARK: - WebSocket client

extension BrowserBridge {

    final class Client {
        enum Phase { case http, websocket }
        let connection: NWConnection
        weak var server: BrowserBridge?
        var phase: Phase = .http
        private var buffer = Data()

        init(connection: NWConnection) { self.connection = connection }

        func beginReceiving() { receive() }

        func send(data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if error != nil || isComplete {
                    self.connection.cancel()
                    return
                }
                self.receive()
            }
        }

        private func ingest(_ data: Data) {
            switch phase {
            case .http:
                buffer.append(data)
                let terminator = Data("\r\n\r\n".utf8)
                if let range = buffer.range(of: terminator) {
                    let header = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    let leftover = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                    buffer.removeAll()
                    handleHTTP(header)
                    if !leftover.isEmpty {
                        buffer.append(leftover)
                        if phase == .websocket { processFrames() }
                    }
                }
            case .websocket:
                buffer.append(data)
                processFrames()
            }
        }

        private func handleHTTP(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else {
                respondAndClose(status: "400 Bad Request", body: Data("Bad Request".utf8))
                return
            }
            let headers: [String: String] = Dictionary(uniqueKeysWithValues: text
                .components(separatedBy: "\r\n").dropFirst().compactMap { line -> (String, String)? in
                    let kv = line.split(separator: ":", maxSplits: 1)
                    guard kv.count == 2 else { return nil }
                    return (String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased(),
                            String(kv[1]).trimmingCharacters(in: .whitespaces))
                })
            let key = headers["sec-websocket-key"] ?? ""
            if headers["upgrade"]?.lowercased() == "websocket", !key.isEmpty {
                phase = .websocket
                let accept = Self.acceptKey(key)
                var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                send(data: Data(response.utf8))
                server?.announceSize()
            } else {
                respondAndClose(status: "200 OK", body: Data(BrowserBridge.webPage.utf8))
            }
        }

        private func respondAndClose(status: String, body: Data) {
            var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }

        private func processFrames() {
            while true {
                guard let frame = Self.decodeFrame(buffer) else { return }
                buffer.removeFirst(frame.consumed)
                handleFrame(opcode: frame.opcode, payload: frame.payload)
            }
        }

        private func handleFrame(opcode: UInt8, payload: Data) {
            switch opcode {
            case 0x1:
                if let text = String(data: payload, encoding: .utf8) { parse(text) }
            case 0x8:
                connection.cancel()
            case 0x9:
                send(data: Self.encodeFrame(opcode: 0xA, payload: payload))
            default:
                break
            }
        }

        private func parse(_ text: String) {
            guard let data = text.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data),
                  let obj = raw as? [String: Any],
                  obj["type"] as? String == "touch" else { return }
            let x = (obj["x"] as? NSNumber)?.intValue ?? 0
            let y = (obj["y"] as? NSNumber)?.intValue ?? 0
            let down = obj["down"] as? Bool ?? true
            server?.onTouch?(UInt16(clamping: x), UInt16(clamping: y), down)
        }

        // MARK: codec

        static func acceptKey(_ key: String) -> String {
            let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
            return Data(digest).base64EncodedString()
        }

        static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
            var frame = Data()
            frame.append(0x80 | (opcode & 0x0F))
            let length = UInt64(payload.count)
            if length < 126 {
                frame.append(UInt8(length))
            } else if length <= 0xFFFF {
                frame.append(126)
                frame.append(UInt8((length >> 8) & 0xFF))
                frame.append(UInt8(length & 0xFF))
            } else {
                frame.append(127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
                }
            }
            frame.append(payload)
            return frame
        }

        static func decodeFrame(_ data: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
            let bytes = [UInt8](data)
            guard bytes.count >= 2 else { return nil }
            let opcode = bytes[0] & 0x0F
            let masked = (bytes[1] & 0x80) != 0
            var length = UInt64(bytes[1] & 0x7F)
            var offset = 2

            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = UInt64(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                var value: UInt64 = 0
                for i in 0..<8 { value = (value << 8) | UInt64(bytes[2 + i]) }
                length = value
                offset = 10
            }

            var maskKey: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return nil }
                maskKey = Array(bytes[offset..<offset + 4])
                offset += 4
            }

            guard bytes.count >= offset + Int(length) else { return nil }
            var payload = [UInt8](repeating: 0, count: Int(length))
            if masked {
                for i in 0..<Int(length) { payload[i] = bytes[offset + i] ^ maskKey[i % 4] }
            } else {
                payload = Array(bytes[offset..<offset + Int(length)])
            }
            return (opcode, Data(payload), offset + Int(length))
        }
    }
}
