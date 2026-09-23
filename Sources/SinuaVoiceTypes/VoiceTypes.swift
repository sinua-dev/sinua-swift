// The voice contract, mirrored from packages/core/src/voice.ts (Web). Same
// vocabulary, same encodings, so a native app feeds the engine the exact
// opts keys the Web path does. See docs/audio-pipeline.md, *Native*.

/// LiveKit Agents' `AgentState` vocabulary, verbatim -- same raw strings as Web's `AgentState`.
public enum AgentState: String, CaseIterable, Sendable {
    case initializing, idle, listening, thinking, speaking

    /// `voiceStateCode` -- mirrors `VoiceState` in crates/core_engine/src/signal/modes/bar.rs
    /// and Web's `VOICE_STATE_CODE`.
    public var voiceStateCode: Double {
        switch self {
        case .idle: return 0
        case .initializing: return 1
        case .listening: return 2
        case .thinking: return 3
        case .speaking: return 4
        }
    }
}

/// A smoothed, normalized reading: overall level and per-band levels, 0...1, low frequency first.
public struct VoiceMetrics: Equatable, Sendable {
    public var level: Double
    public var bands: [Double]

    public init(level: Double, bands: [Double]) {
        self.level = level
        self.bands = bands
    }

    public static let silent = VoiceMetrics(level: 0, bands: [])
}

/// One source of voice readings (a mic, a test tone, later a vendor
/// transport). Callbacks arrive on the main thread.
public protocol VoiceSource: AnyObject {
    func connect() async throws
    func disconnect()
    func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void)
    func onStateChange(_ cb: @escaping (AgentState) -> Void)
    /// Optional barge-in moment (see Web's `VoiceSource.onInterrupt`); a no-op by default.
    func onInterrupt(_ cb: @escaping () -> Void)
}

extension VoiceSource {
    public func onInterrupt(_ cb: @escaping () -> Void) {}
}

/// `primitives::audio_band`'s cap: keys `audioBand0`...`audioBand15` exist, nothing beyond.
public let maxAudioBands = 16
