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
    /// Optional: mute or unmute the microphone (see Web's `VoiceSource.setMuted`). Silence
    /// goes out and the session stays up. A no-op by default; `supportsMute` says whether it
    /// does anything. Call it through `SharedVoiceSource` so views show the muted cue.
    func setMuted(_ muted: Bool)
    /// Whether `setMuted` does anything. False by default.
    var supportsMute: Bool { get }
    /// Optional: `true` once the session is up, `false` when it ends -- `disconnect()`, a
    /// remote hang-up, a drop the source gave up on. An agent can be `idle` while connected,
    /// so the state can't say this. A no-op by default; see `reportsConnection`.
    func onConnectionChange(_ cb: @escaping (Bool) -> Void)
    /// Whether `onConnectionChange` ever fires. False by default.
    var reportsConnection: Bool { get }
}

extension VoiceSource {
    public func onInterrupt(_ cb: @escaping () -> Void) {}
    public func setMuted(_ muted: Bool) {}
    public var supportsMute: Bool { false }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) {}
    public var reportsConnection: Bool { false }
}

/// `primitives::audio_band`'s cap: keys `audioBand0`...`audioBand15` exist, nothing beyond.
public let maxAudioBands = 16
