import AVFoundation
import Foundation

/// The device microphone as a `VoiceSource` -- `AVAudioEngine`'s input tap
/// feeding the same spec-exact `SpectrumAnalyser` -> `AudioAnalysis` path
/// the Web Studio's `LocalMicVoiceSource` uses (docs/audio-pipeline.md,
/// *Native*). 30 Hz metrics on main; `speaking` when level > 0.08, else
/// `listening` -- Web's heuristic.
///
/// The app must declare `NSMicrophoneUsageDescription` in its Info.plist;
/// `connect()` requests permission and throws `VoiceSourceError.permissionDenied`
/// when refused. `configureSession: false` leaves `AVAudioSession` alone for
/// apps that manage it themselves (e.g. an app already running a voice call).
public final class LocalMicVoiceSource: VoiceSource {
    public static let updateHz = 30.0
    private let configureSession: Bool
    private let engine = AVAudioEngine()
    private let ring = SampleRing(capacity: 4096)
    private let spectrum = SpectrumAnalyser()
    private let analysis = AudioAnalysis()
    private var timer: DispatchSourceTimer?
    private var tapInstalled = false
    private var metricsCb: ((VoiceMetrics) -> Void)?
    private var stateCb: ((AgentState) -> Void)?

    public init(configureSession: Bool = true) {
        self.configureSession = configureSession
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { stateCb = cb }

    public func connect() async throws {
        await MainActor.run { stateCb?(.initializing) }
        guard await Self.requestPermission() else {
            await MainActor.run { stateCb?(.idle) }
            throw VoiceSourceError.permissionDenied
        }
        do {
            try await MainActor.run { try start() }
        } catch {
            await MainActor.run {
                stop()
                stateCb?(.idle)
            }
            throw error
        }
    }

    public func disconnect() {
        stop()
        stateCb?(.idle)
    }

    private func start() throws {
        if configureSession {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceSourceError.noInput }
        let ring = self.ring
        // Audio thread: copy the first channel into the ring, nothing else.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            ring.write(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        spectrum.reset()
        analysis.reset()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.updateHz)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        stateCb?(.listening)
        t.resume()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if configureSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func tick() {
        spectrum.push(ring.drain())
        let m = analysis.read(spectrum.byteFrequencyData())
        metricsCb?(m)
        stateCb?(m.level > speakingLevel ? .speaking : .listening)
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }
}

public enum VoiceSourceError: Error, Equatable {
    case permissionDenied
    case noInput
}

/// Single-producer (audio thread) / single-consumer (main) sample hand-off.
/// Keeps only the newest `capacity` samples; the analyser needs the last 512.
final class SampleRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [Float]
    private var count = 0
    private var head = 0

    init(capacity: Int) {
        buf = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            buf[head] = s
            head = (head + 1) % buf.count
            count = min(count + 1, buf.count)
        }
    }

    /// Everything written since the last drain, oldest first.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var out = [Float](repeating: 0, count: count)
        let start = (head - count + buf.count) % buf.count
        for i in 0..<count { out[i] = buf[(start + i) % buf.count] }
        count = 0
        return out
    }
}
