import AVFoundation
import Foundation

/// `PcmAudioDevice` on one `AVAudioEngine`: the mic tap converted to the
/// vendor's input rate (mono float), and an `AVAudioPlayerNode` at its output
/// rate whose own sample clock is the timeline's "now".
///
/// Voice processing (Apple's echo canceller) is on by default: with a
/// speaker, the model would otherwise hear itself and barge in on its own
/// voice. Web gets the same from `getUserMedia`'s default `echoCancellation`.
/// The app must declare `NSMicrophoneUsageDescription`; ask with
/// `requestPermission()` first. `configureSession: false` leaves
/// `AVAudioSession` to an app that manages it.
public final class AVPcmAudioDevice: PcmAudioDevice {
    public static let captureChunk = 1024  // samples per mic chunk at the input rate (~64 ms at 16 kHz), as on Web

    private let configureSession: Bool
    private let voiceProcessing: Bool
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    public var onClockReset: (() -> Void)?

    public init(configureSession: Bool = true, voiceProcessing: Bool = true) {
        self.configureSession = configureSession
        self.voiceProcessing = voiceProcessing
    }

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    public func start(inputRate: Int, outputRate: Int, onCapture: @escaping @Sendable ([Float]) -> Void) throws {
        if configureSession {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        }
        let input = engine.inputNode
        if voiceProcessing { try input.setVoiceProcessingEnabled(true) }

        // Capture: whatever the hardware gives -> mono float at inputRate, chunked.
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: target)
        else { throw VoiceSourceError.noInput }
        let chunker = Chunker(size: Self.captureChunk, emit: onCapture)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inFormat.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData?[0] else { return }
            chunker.push(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        }
        tapInstalled = true

        // Playback: a player node at the vendor's rate; the mixer resamples to the hardware.
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate), channels: 1, interleaved: false)
        else { throw VoiceSourceError.noInput }
        outputFormat = outFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        // AVAudioEngine stops itself on a configuration change (enabling voice
        // processing can trigger one right after start; on a phone, a route
        // change such as headphones or Bluetooth does) and must be restarted.
        // The player's clock and queue are gone then -- the graph is told.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.recoverFromConfigurationChange() }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func recoverFromConfigurationChange() {
        guard tapInstalled, !engine.isRunning || !player.isPlaying else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
            onClockReset?()
        } catch {
            NSLog("AVPcmAudioDevice: engine restart after a configuration change failed: %@", String(describing: error))
        }
    }

    public var playedFrames: Int64 {
        guard player.isPlaying, let node = player.lastRenderTime, let t = player.playerTime(forNodeTime: node) else {
            return 0
        }
        return max(0, t.sampleTime)
    }

    public func schedule(_ samples: [Float], atFrame frame: Int64) {
        guard let fmt = outputFormat, !samples.isEmpty,
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(
            buf, at: AVAudioTime(sampleTime: frame, atRate: fmt.sampleRate), options: [], completionHandler: nil)
    }

    public func resetPlayback(fade: Bool) {
        // `stop()` is the player node's way to drop everything scheduled. `fade`
        // is ignored here for now: the Web 30 ms ramp has no per-node gain
        // automation to port to, and whether the hard cut clicks audibly is a
        // device check that hasn't been done (docs/audio-pipeline.md).
        player.stop()
        player.play()  // the player clock restarts at 0, matching PlaybackTimeline.clear()
    }

    public func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        player.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        if configureSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Audio thread: accumulate converted samples, emit fixed-size chunks (the Web worklet's job).
    private final class Chunker: @unchecked Sendable {
        private var buf: [Float]
        private var n = 0
        private let emit: @Sendable ([Float]) -> Void

        init(size: Int, emit: @escaping @Sendable ([Float]) -> Void) {
            buf = [Float](repeating: 0, count: size)
            self.emit = emit
        }

        func push(_ samples: UnsafeBufferPointer<Float>) {
            for s in samples {
                buf[n] = s
                n += 1
                if n == buf.count {
                    emit(buf)
                    n = 0
                }
            }
        }
    }
}
