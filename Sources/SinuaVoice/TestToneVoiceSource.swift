import Foundation

/// A `VoiceSource` needing no microphone and no vendor: Web's test tone
/// (`TestToneGenerator`), synthesized in software and run through the exact
/// same `SpectrumAnalyser` -> `AudioAnalysis` path as the mic. Nothing is
/// played (Web routes its tone at zero gain too). 30 Hz ticks on main.
public final class TestToneVoiceSource: VoiceSource {
    public static let updateHz = 30.0
    private let sampleRate: Double
    private var generator: TestToneGenerator
    private let spectrum = SpectrumAnalyser()
    private let analysis = AudioAnalysis()
    private var timer: DispatchSourceTimer?
    private var metricsCb: ((VoiceMetrics) -> Void)?
    private var stateCb: ((AgentState) -> Void)?
    private var connectionCb: ((Bool) -> Void)?
    private var muted = false

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        generator = TestToneGenerator(sampleRate: sampleRate)
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { stateCb = cb }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) { connectionCb = cb }
    public var reportsConnection: Bool { true }
    public var supportsMute: Bool { true }
    /// Muted, the tone stands in for a muted mic: the level reads 0.
    public func setMuted(_ muted: Bool) { self.muted = muted }

    public func connect() async throws {
        await MainActor.run {
            stateCb?(.initializing)
            generator = TestToneGenerator(sampleRate: sampleRate)
            spectrum.reset()
            analysis.reset()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 1 / Self.updateHz)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            stateCb?(.listening)
            connectionCb?(true)
            t.resume()
        }
    }

    public func disconnect() {
        let was = timer != nil
        timer?.cancel()
        timer = nil
        stateCb?(.idle)
        if was { connectionCb?(false) }
    }

    private func tick() {
        let n = Int(sampleRate / Self.updateHz)
        let samples = generator.next(n)
        spectrum.push(muted ? [Float](repeating: 0, count: n) : samples)
        let m = analysis.read(spectrum.byteFrequencyData())
        metricsCb?(m)
        stateCb?(m.level > speakingLevel ? .speaking : .listening)
    }
}

/// `LocalMicVoiceSource`/`TestToneVoiceSource`'s energy heuristic threshold -- Web's 0.08.
let speakingLevel = 0.08
