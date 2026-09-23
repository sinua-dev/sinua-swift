import Foundation

// The SDK-free half of the native LiveKit `VoiceSource` (the Swift glue lives
// in packages/ios-livekit, `SinuaLiveKit`, so apps that never use LiveKit
// don't pull the SDK). A port of packages/voice/src/livekitAgent.ts plus
// the state machine of the Web `LiveKitVoiceSource`, driven by plain events so
// it can be tested without a Room. Sources: the vendors' public docs and SDK sources.
// (livekit/protocol `ParticipantInfo.Kind`, components-js agent attributes,
// client-sdk-swift 2.17.0 `Room.agentParticipant` -- the same rule).

public enum LiveKitAgent {
    public static let agentStateAttribute = "lk.agent.state"
    public static let publishOnBehalfAttribute = "lk.publish_on_behalf"

    /// The agent's published lifecycle state, or nil if absent/unknown.
    public static func agentState(fromAttributes attrs: [String: String]) -> AgentState? {
        attrs[agentStateAttribute].flatMap(AgentState.init(rawValue:))
    }

    /// components-js's rule: an AGENT-kind participant that is not publishing on someone else's behalf.
    public static func isPrimaryAgent(isAgentKind: Bool, attributes: [String: String]) -> Bool {
        isAgentKind && attributes[publishOnBehalfAttribute] == nil
    }

    /// A worker participant carrying media for `agentIdentity` (e.g. an avatar worker).
    public static func publishesForAgent(isAgentKind: Bool, attributes: [String: String], agentIdentity: String) -> Bool
    {
        isAgentKind && attributes[publishOnBehalfAttribute] == agentIdentity
    }

    /// LiveKit gives a frontend no interruption event, so barge-in is inferred:
    /// the agent leaves `speaking` for `listening`/`thinking` while the local
    /// user is an active speaker. Same known false positive as Web (LiveKit's
    /// "false interruption" recovery still flashes).
    public static func isInferredBargeIn(prev: AgentState, next: AgentState, userSpeaking: Bool) -> Bool {
        prev == .speaking && (next == .listening || next == .thinking) && userSpeaking
    }
}

/// What a participant is to the tracker; the glue attaches audio for `.agent` and `.agentWorker`.
public enum LiveKitParticipantRole: Equatable, Sendable {
    case agent, agentWorker, other
}

/// The Web adapter's state machine without the SDK. The glue calls the event
/// methods on the main thread, `sink.write` from the audio thread, and `tick` at
/// 30 Hz on main. Until the agent publishes `lk.agent.state`, an energy
/// fallback on its audio drives the state (audible -> `speaking`, else
/// `listening`) -- older agents never publish one.
public final class LiveKitAgentTracker {
    /// Energy-fallback threshold: Web `LiveKitVoiceSource`'s 0.05, not the mic's 0.08.
    public static let speakingLevel = 0.05

    public private(set) var agentIdentity: String?
    public private(set) var state: AgentState = .idle
    public private(set) var hasAudio = false
    private var agentStateSeen = false
    private var running = false

    /// Handed to the SDK's audio tap: the only part touched off the main thread.
    public let sink = LiveKitPcmSink()
    private var ring: SampleRing { sink.ring }
    private let spectrum = SpectrumAnalyser()
    private let analysis = AudioAnalysis()

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?
    public var onMetrics: ((VoiceMetrics) -> Void)?

    public init() {}

    /// Connected (or connecting): `initializing` until an agent shows up.
    public func start() {
        running = true
        setState(.initializing)
    }

    public func stop() {
        running = false
        agentIdentity = nil
        agentStateSeen = false
        audioDetached()
        setState(.idle)
    }

    public func role(identity: String, isAgentKind: Bool, attributes: [String: String]) -> LiveKitParticipantRole {
        if let agent = agentIdentity {
            if identity == agent { return .agent }
            return LiveKitAgent.publishesForAgent(
                isAgentKind: isAgentKind, attributes: attributes, agentIdentity: agent)
                ? .agentWorker : .other
        }
        return .other
    }

    /// A participant is present (already in the room, just joined, or its
    /// track was subscribed). Adopts it if it is the first primary agent.
    @discardableResult
    public func participantSeen(identity: String, isAgentKind: Bool, attributes: [String: String])
        -> LiveKitParticipantRole
    {
        if agentIdentity == nil, LiveKitAgent.isPrimaryAgent(isAgentKind: isAgentKind, attributes: attributes) {
            agentIdentity = identity
            if let s = LiveKitAgent.agentState(fromAttributes: attributes) {
                agentStateSeen = true
                setState(s)
            }
        }
        return role(identity: identity, isAgentKind: isAgentKind, attributes: attributes)
    }

    /// `didUpdateAttributes`. `changed` is the SDK's diff; `attributes` the participant's full set.
    @discardableResult
    public func attributesChanged(
        identity: String, isAgentKind: Bool, attributes: [String: String],
        changed: [String: String], localSpeaking: Bool
    ) -> LiveKitParticipantRole {
        // Attributes can land after the participant itself did.
        guard agentIdentity != nil else {
            return participantSeen(identity: identity, isAgentKind: isAgentKind, attributes: attributes)
        }
        if identity == agentIdentity, changed[LiveKitAgent.agentStateAttribute] != nil,
            let s = LiveKitAgent.agentState(fromAttributes: attributes)
        {
            agentStateSeen = true
            if LiveKitAgent.isInferredBargeIn(prev: state, next: s, userSpeaking: localSpeaking) { onInterrupt?() }
            setState(s)
        }
        return role(identity: identity, isAgentKind: isAgentKind, attributes: attributes)
    }

    /// Returns true when the agent itself left: the glue drops its audio tap.
    @discardableResult
    public func participantLeft(identity: String) -> Bool {
        guard identity == agentIdentity else { return false }
        agentIdentity = nil
        agentStateSeen = false
        audioDetached()
        if running { setState(.initializing) }
        return true
    }

    /// The glue attached its tap to an agent (or worker) audio track.
    public func audioAttached() {
        _ = ring.drain()
        spectrum.reset()
        analysis.reset()
        hasAudio = true
    }

    public func audioDetached() {
        hasAudio = false
        _ = ring.drain()
    }

    /// 30 Hz on main: drain -> spectrum -> metrics; the energy fallback until a state is seen.
    public func tick() {
        guard hasAudio else { return }
        spectrum.push(ring.drain())
        let m = analysis.read(spectrum.byteFrequencyData())
        onMetrics?(m)
        if running, agentIdentity != nil, !agentStateSeen {
            setState(m.level > Self.speakingLevel ? .speaking : .listening)
        }
    }

    private func setState(_ s: AgentState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}

/// The audio-thread side of `LiveKitAgentTracker`: copies the first channel
/// into a locked ring (the same `SampleRing` hand-off `LocalMicVoiceSource` uses).
public final class LiveKitPcmSink: @unchecked Sendable {
    let ring = SampleRing(capacity: 4096)

    /// Normalized float samples, first channel of a non-interleaved buffer.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        ring.write(samples)
    }

    /// Interleaved int16 PCM; keeps channel 0, scaled `/32768` like WebRTC's own float conversion.
    public func write(int16 samples: UnsafeBufferPointer<Int16>, channels: Int = 1) {
        let stride = max(1, channels)
        let n = samples.count / stride
        guard n > 0 else { return }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(samples[i * stride]) / 32768 }
        out.withUnsafeBufferPointer { ring.write($0) }
    }
}
