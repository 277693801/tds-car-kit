// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Plays a muted, looping silence buffer so the `audio` background mode stays
/// active while CarPlay has no media. This keeps the receiver, sockets and the
/// CoreAccessories session alive when the app is backgrounded.
final class BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000) else { return }
            buffer.frameLength = 8000
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            try engine.start()
            player.play()
            started = true
            installObservers()
        } catch {
            // Keep-alive is best-effort; audio/media sessions still work without it.
        }
    }

    func stop() {
        guard started else { return }
        removeObservers()
        player.stop()
        engine.stop()
        started = false
    }

    private func installObservers() {
        removeObservers()
        let name = AVAudioSession.interruptionNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  typeValue == AVAudioSession.InterruptionType.ended.rawValue else { return }
            self.restart()
        }
        observers.append(observer)
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func restart() {
        guard started else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }
}
