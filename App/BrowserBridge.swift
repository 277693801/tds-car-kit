// SPDX-License-Identifier: GPL-3.0-or-later
// Browser bridge: forwards the received H.264 Annex-B access units to a LAN
// browser unchanged, where WebCodecs decodes them. Each binary frame is
// prefixed with one keyframe flag byte (1 = key, 0 = delta).
import Foundation
import Network
import UIKit
import CryptoKit

final class BrowserBridge {

    private let queue = DispatchQueue(label: "TDSCarKit.browser")
    private var listener: NWListener?
    private var clients: [Client] = []

    var onTouch: ((UInt16, UInt16, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    func start(port: UInt16) {
        queue.async { [weak self] in self?.startOnQueue(port: port) }
    }

    func push(accessUnit: Data) {
        queue.async { [weak self] in self?.forward(accessUnit) }
    }

    func reset() {
        // Decoding happens in the browser now; nothing to tear down on device.
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.clients.removeAll()
        }
    }

    // MARK: - Forwarding

    private func forward(_ accessUnit: Data) {
        guard !accessUnit.isEmpty else { return }
        var packet = Data([Self.isKeyframe(accessUnit) ? 1 : 0])
        packet.append(accessUnit)
        broadcast(packet)
    }

    private static func isKeyframe(_ accessUnit: Data) -> Bool {
        guard let nals = try? AnnexB.units(in: accessUnit) else { return false }
        return nals.contains { nal in
            guard let first = nal.first else { return false }
            return (first & 0x1f) == 5
        }
    }

    private func broadcast(_ data: Data) {
        let packet = Client.encodeFrame(opcode: 0x2, payload: data)
        for client in clients where client.phase == .websocket {
            client.send(data: packet)
        }
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
  var VW=1280,VH=720;
  var canvas=document.getElementById('cv');
  var ctx=canvas.getContext('2d');
  var pill=document.getElementById('pill');
  var ws=null;
  var active=false;
  var decoder=null;
  var currentFrame=null;
  var pending=[];
  var ts=0;
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
    if(currentFrame){
      try{ctx.drawImage(currentFrame,ox,oy,dw,dh);}catch(e){}
    }
  }

  function resize(){
    var dpr=window.devicePixelRatio||1;
    canvas.width=Math.floor(window.innerWidth*dpr);
    canvas.height=Math.floor(window.innerHeight*dpr);
    canvas.style.width=window.innerWidth+'px';
    canvas.style.height=window.innerHeight+'px';
    draw();
  }

  function onFrame(frame){
    if(currentFrame){try{currentFrame.close();}catch(e){}}
    currentFrame=frame;
    draw();
  }

  function ensureDecoder(){
    if(decoder)return;
    if(typeof VideoDecoder==='undefined'){
      setPill('浏览器不支持 WebCodecs(H.264)',false);
      return;
    }
    try{
      decoder=new VideoDecoder({
        output:onFrame,
        error:function(e){setPill('解码错误：'+e.message,false);}
      });
      decoder.configure({codec:'avc'});
      setPill('已连接，可触摸操作',true);
    }catch(e){
      setPill('WebCodecs 初始化失败：'+e.message,false);
    }
  }

  function flush(){
    if(!decoder||decoder.state!=='configured')return;
    while(pending.length){
      var c=pending.shift();
      try{decoder.decode(c);}catch(e){}
    }
  }

  function feed(data,key){
    ensureDecoder();
    pending.push(new EncodedVideoChunk({type:key?'key':'delta',timestamp:ts++,data:data}));
    flush();
  }

  function open(){
    ws=new WebSocket(wsUrl);
    ws.binaryType='arraybuffer';
    ws.onopen=function(){setPill('已连接，可触摸操作',true);};
    ws.onclose=function(){
      setPill('连接断开，正在重连…',false);
      if(decoder){try{decoder.close();}catch(e){}}
      decoder=null;currentFrame=null;pending=[];
      setTimeout(open,1500);
    };
    ws.onerror=function(){};
    ws.onmessage=function(ev){
      if(typeof ev.data==='string'){return;}
      var arr=new Uint8Array(ev.data);
      if(arr.length<2){return;}
      var key=arr[0]===1;
      var data=arr.slice(1);
      feed(data,key);
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
            var headers: [String: String] = [:]
            for line in text.components(separatedBy: "\r\n").dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                headers[String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
            let key = headers["sec-websocket-key"] ?? ""
            if headers["upgrade"]?.lowercased() == "websocket", !key.isEmpty {
                phase = .websocket
                let accept = Self.acceptKey(key)
                var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                send(data: Data(response.utf8))
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
