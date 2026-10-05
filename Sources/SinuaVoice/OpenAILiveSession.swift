import Foundation

/// The I/O-free half of the native OpenAI GPT-Live `VoiceSource` (the WebRTC glue is
/// `SinuaOpenAI`'s `OpenAILiveVoiceSource`): a port of packages/voice/src/openaiLive.ts,
/// held to the same table (spec/openai-live-cases.json). Main thread.
///
/// GPT-Live sends no turn events, so: the model's audio level drives `speaking` (above
/// 0.05, left after ~300 ms of quiet); an open backend delegation drives `thinking` while
/// the model is quiet (`session.delegation.created` or a nested `response.created`, until
/// its nested terminal Responses event, the `session.commentary.appended` that delivers a
/// client delegation's result -- it carries no `delegation_id`, so the oldest open client
/// delegation closes -- or 30 s without news); user speech over the model's audio
/// that stops it within 1 s is a barge-in (full duplex: a "mhm" under continuing speech isn't).
public final class OpenAILiveSession {
    public static let speakingLevel = 0.05
    /// Speaking ends after a quiet tail that grows with how long the agent has been speaking
    /// (design note 31, V7): `speakingTailFrames` 30 Hz ticks plus `speakingTailPerSecond` per
    /// second of the stretch, at most `speakingTailMaxFrames` -- a short reply hands back in
    /// ~0.7 s, a long answer survives natural pauses. After ~300 ms when the user just spoke
    /// (a barge-in stays instant).
    public static let speakingTailFrames = 21
    public static let speakingTailPerSecond = 4.0
    public static let speakingTailMaxFrames = 51
    public static let bargeInTailFrames = 9
    public static let bargeInWindowMs = 1000.0
    public static let delegationTimeoutMs = 30_000.0
    static let terminalResponseEvents: Set<String> = [
        "response.completed", "response.failed", "response.incomplete", "response.cancelled",
    ]

    public private(set) var state: AgentState = .idle
    /// `session.started`'s `session.id`, once seen.
    public private(set) var sessionId: String?
    /// A fatal `error.code` seen this session (e.g. `insufficient_quota`): don't reconnect.
    public private(set) var fatalCode: String?
    /// `session.closed`'s `reason`, once seen.
    public private(set) var closedReason: String?
    public private(set) var isStarted = false

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?
    public var onClosed: ((String) -> Void)?

    private var quietFrames = 0
    /// When the current speaking stretch began (ms).
    private var speakingSince = 0.0
    private var bargeInAt: Double?
    /// Open delegations: id -> last news (ms), the order it opened in, and whether the app's
    /// backend answers it (target `client`).
    private var delegations: [String: (at: Double, order: Int, client: Bool)] = [:]
    private var opened = 0

    public init() {}

    public func connecting() {
        reset()
        setState(.initializing)
    }

    public func stopped() {
        reset()
        setState(.idle)
    }

    /// A server event from the `oai-events` data channel, at `now` ms.
    public func handle(_ text: String, now: Double) {
        guard let data = text.data(using: .utf8),
            let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = ev["type"] as? String
        else { return }
        switch type {
        case "session.started":
            if let id = (ev["session"] as? [String: Any])?["id"] as? String { sessionId = id }
            isStarted = true
            setState(.listening)
        case "session.input_transcript.delta":
            if state == .speaking, bargeInAt == nil { bargeInAt = now }
        case "session.delegation.created":
            if let d = ev["delegation"] as? [String: Any], let id = d["id"] as? String {
                open(id, now, client: d["target"] as? String == "client")
            }
        case "response.event":
            guard let id = ev["delegation_id"] as? String,
                let inner = (ev["event"] as? [String: Any])?["type"] as? String
            else { break }
            if Self.terminalResponseEvents.contains(inner) {
                close(id)
            } else if inner == "response.created" || delegations[id] != nil {
                open(id, now, client: false)
            }
        case "session.commentary.appended":
            // A client delegation's result was delivered: the named one, else the oldest owed.
            let oldest = delegations.filter { $0.value.client }.min { $0.value.order < $1.value.order }?.key
            if let id = ev["delegation_id"] as? String ?? oldest { close(id) }
        case "session.closed":
            let reason = ev["reason"] as? String ?? "unknown"
            closedReason = reason
            onClosed?(reason)
        case "error":
            let code = (ev["error"] as? [String: Any])?["code"] as? String
            if RealtimeReconnect.isFatalError(code: code) { fatalCode = code }
        default:
            break
        }
    }

    /// 30 Hz with the remote track's current level, at `now` ms.
    public func tick(level: Double, now: Double) {
        guard isStarted else { return }
        delegations = delegations.filter { now - $0.value.at <= Self.delegationTimeoutMs }
        if level > Self.speakingLevel {
            quietFrames = 0
            if state != .speaking { speakingSince = now }
            setState(.speaking)
        } else if state == .speaking {
            quietFrames += 1
            let userSpoke = bargeInAt.map { now - $0 <= Self.bargeInWindowMs } ?? false
            let tail = userSpoke ? Self.bargeInTailFrames : Self.speakingTail(ms: now - speakingSince)
            guard quietFrames >= tail else { return }
            let armed = bargeInAt
            bargeInAt = nil
            quietFrames = 0
            setState(delegations.isEmpty ? .listening : .thinking)
            if let armed, now - armed <= Self.bargeInWindowMs { onInterrupt?() }
        } else {
            settle()
        }
    }

    private func open(_ id: String, _ now: Double, client: Bool) {
        if let known = delegations[id] {
            delegations[id] = (now, known.order, known.client)
        } else {
            opened += 1
            delegations[id] = (now, opened, client)
        }
        settle()
    }

    private func close(_ id: String) {
        if delegations.removeValue(forKey: id) != nil { settle() }
    }

    /// Listening <-> thinking by open delegations; speaking is left alone.
    private func settle() {
        guard isStarted, state != .speaking else { return }
        setState(delegations.isEmpty ? .listening : .thinking)
    }

    private func reset() {
        isStarted = false
        sessionId = nil
        fatalCode = nil
        closedReason = nil
        quietFrames = 0
        bargeInAt = nil
        delegations.removeAll()
    }

    /// The quiet ticks that end a speaking stretch `ms` long (the constants above).
    public static func speakingTail(ms: Double) -> Int {
        let grown = (Double(speakingTailFrames) + speakingTailPerSecond * ms / 1000).rounded()
        return min(speakingTailMaxFrames, max(speakingTailFrames, Int(grown)))
    }

    private func setState(_ s: AgentState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}
