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

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        generator = TestToneGenerator(sampleRate: sampleRate)
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { stateCb = cb }

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
            t.resume()
        }
    }

    public func disconnect() {
        timer?.cancel()
        timer = nil
        stateCb?(.idle)
    }

    private func tick() {
        spectrum.push(generator.next(Int(sampleRate / Self.updateHz)))
        let m = analysis.read(spectrum.byteFrequencyData())
        metricsCb?(m)
        stateCb?(m.level > speakingLevel ? .speaking : .listening)
    }
}

/// `LocalMicVoiceSource`/`TestToneVoiceSource`'s energy heuristic threshold -- Web's 0.08.
let speakingLevel = 0.08
