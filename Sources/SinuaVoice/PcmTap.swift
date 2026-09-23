import Foundation

/// Analyses PCM tapped from a playing stream (e.g. a remote WebRTC track's
/// renderer): the audio thread writes into `sink`, the main thread's `read()`
/// drains it through the same `SpectrumAnalyser` -> `AudioAnalysis` path as the
/// mic. The tap sits on the playout path, so it reads what is being played.
/// (`LiveKitAgentTracker` bundles the same pieces with LiveKit's rules.)
public final class PcmTap {
    public let sink = LiveKitPcmSink()
    private let spectrum = SpectrumAnalyser()
    private let analysis = AudioAnalysis()

    public init() {}

    public func reset() {
        _ = sink.ring.drain()
        spectrum.reset()
        analysis.reset()
    }

    /// Main thread, ~30 Hz.
    public func read() -> VoiceMetrics {
        spectrum.push(sink.ring.drain())
        return analysis.read(spectrum.byteFrequencyData())
    }
}
