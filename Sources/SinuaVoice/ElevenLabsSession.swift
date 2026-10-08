import Foundation

/// The I/O-free half of the native ElevenLabs `VoiceSource` (the socket glue is
/// `SinuaElevenLabs`): a port of packages/voice/src/ElevenLabsVoiceSource.ts's
/// protocol and state machine. Wire format per ElevenLabs' Agents-platform
/// WebSocket reference (AsyncAPI, checked 2026-09-19). Main thread; the clock is
/// passed in so the 4 s thinking guard is testable.
///
/// State mapping, as on Web:
/// - `vad_score` > 0.5 (the vendor's user-speech probability) -> `listening`;
///   falling below with nothing queued -> `thinking`;
/// - `user_transcript` (finalized utterance) -> `thinking`, unless audible;
/// - a chunk received but not audible -> `thinking`; audible -> `speaking`;
/// - the reply's end is the server's signal: `agent_response_complete` (or an
///   `audio` chunk with `is_final`). Drained *after* it -> `listening`; drained
///   *before* it (a network stall mid-reply) -> `thinking`, not `listening`.
///   A reply with no audio (text-only / empty) ends `thinking` at once;
/// - `interruption` -> clear playback -> `listening`, a barge-in only if there
///   was output to cut; later chunks with a lower `event_id` are dropped;
/// - `thinking` with no audio for 4 s -> `listening` (VAD-flicker guard), or,
///   while a reply is open, 10 s without audio -> `listening` (a lost `complete`).
public final class ElevenLabsSession {
    public static let vadThreshold = 0.5
    public static let thinkingTimeout: TimeInterval = 4
    /// A reply that went quiet without `agent_response_complete`: give up after this.
    public static let stallTimeout: TimeInterval = 10
    public static let subprotocol = "convai"

    public enum Action: Equatable {
        /// `conversation_initiation_metadata`: the negotiated formats (start the graph with these).
        case metadata(input: Pcm.AudioFormat, output: Pcm.AudioFormat)
        case send(String)
        case enqueue([Float], rate: Int)
        case clearPlayback(fade: Bool)
    }

    public private(set) var state: AgentState = .idle
    private var output = Pcm.AudioFormat(codec: .pcm, rate: 16000)
    private var graphReady = false
    private var pendingAudio: [(id: Int, b64: String, isFinal: Bool, alignment: [String: Any]?)] = []
    /// The transcript (design note 39): `chars` timing from each chunk's alignment, synced to
    /// the played audio unless `syncToAudio` is false; the user's text comes final.
    public let transcript: TranscriptAssembler
    public var onTranscript: ((TranscriptUpdate) -> Void)? {
        get { transcript.onUpdate }
        set { transcript.onUpdate = newValue }
    }
    /// Audio of the current reply queued so far (ms): where the next chunk's alignment starts.
    private var replyAudioMs = 0.0
    /// The current reply's text, shown untimed at its end if no chunk carried an alignment.
    private var replyText = ""
    private var replyAligned = false
    /// No reply in flight: `agent_response_complete` / a final chunk / an interruption since the last one began.
    private var responseDone = true
    /// The reply was closed this turn: trailing chunks after `complete` don't reopen it;
    /// the user's next turn (speech, transcript, barge-in) does.
    private var closedThisTurn = false
    private var lastAudioAt: TimeInterval = 0
    private var lastInterruptEventId = 0
    private var userSpeaking = false
    private var thinkingSince: TimeInterval = 0

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?

    public init(syncToAudio: Bool = true) {
        transcript = TranscriptAssembler(timing: .chars, sync: syncToAudio, explicitUserEnd: true)
    }

    /// An agent id -> the public-agent URL; a `wss://…` signed URL (minted by your backend) is used as-is.
    public static func endpoint(credential: String) -> URL? {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("wss://") { return URL(string: c) }
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/convai/conversation")!
        comps.queryItems = [URLQueryItem(name: "agent_id", value: c)]
        return comps.url
    }

    public static func initMessage(overrides: [String: Any]? = nil) -> String {
        var m: [String: Any] = ["type": "conversation_initiation_client_data"]
        if let overrides { m["conversation_config_override"] = overrides }
        return GeminiLiveSession.json(m)
    }

    public static func micMessage<C: Collection>(_ samples: C) -> String where C.Element == Float {
        GeminiLiveSession.json(["user_audio_chunk": Pcm.floatToPcm16(samples).base64EncodedString()])
    }

    public func connecting(now: TimeInterval) {
        reset()
        setState(.initializing, now: now)
    }

    /// The graph is up at the negotiated rates: audio that arrived meanwhile is flushed now.
    public func graphStarted(output format: Pcm.AudioFormat, now: TimeInterval) -> [Action] {
        output = format
        graphReady = true
        let flushed = pendingAudio.map { enqueueAction($0.b64, isFinal: $0.isFinal, alignment: $0.alignment, now: now) }
        pendingAudio = []
        if state == .initializing { setState(.listening, now: now) }
        return flushed
    }

    public func reset() {
        graphReady = false
        pendingAudio = []
        lastInterruptEventId = 0
        userSpeaking = false
        responseDone = true
        closedThisTurn = false
    }

    public func stopped(now: TimeInterval) {
        reset()
        transcript.stop()
        setState(.idle, now: now)
    }

    /// One server frame. `playback` is the graph's current state.
    public func handle(_ text: String, playback: PlaybackState, now: TimeInterval) -> [Action] {
        guard let data = text.data(using: .utf8),
            let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = ev["type"] as? String
        else { return [] }
        switch type {
        case "conversation_initiation_metadata":
            let m = ev["conversation_initiation_metadata_event"] as? [String: Any] ?? [:]
            return [
                .metadata(
                    input: Pcm.parseAudioFormat(m["user_input_audio_format"] as? String),
                    output: Pcm.parseAudioFormat(m["agent_output_audio_format"] as? String))
            ]
        case "ping":
            // Keep-alive: answered immediately with the same event_id, as the SDK does.
            guard let id = (ev["ping_event"] as? [String: Any])?["event_id"] as? Int else { return [] }
            return [.send(GeminiLiveSession.json(["type": "pong", "event_id": id]))]
        case "audio":
            let a = ev["audio_event"] as? [String: Any] ?? [:]
            let id = a["event_id"] as? Int ?? 0
            // Late chunks of an interrupted response: dropped, the SDK's own rule.
            guard id >= lastInterruptEventId, let b64 = a["audio_base_64"] as? String, !b64.isEmpty else { return [] }
            let isFinal = a["is_final"] as? Bool ?? false
            let alignment = a["alignment"] as? [String: Any]
            if !graphReady {
                pendingAudio.append((id, b64, isFinal, alignment))
                return []
            }
            return [enqueueAction(b64, isFinal: isFinal, alignment: alignment, now: now)]
        case "agent_response":
            // The reply's text: a reply is under way (its audio may still be coming).
            if !closedThisTurn { responseDone = false }
            replyText = (ev["agent_response_event"] as? [String: Any])?["agent_response"] as? String ?? ""
            lastAudioAt = now
            return []
        case "agent_response_complete":
            endResponse(playback: playback, now: now)
            return []
        case "interruption":
            if let id = (ev["interruption_event"] as? [String: Any])?["event_id"] as? Int { lastInterruptEventId = id }
            if state == .speaking || playback != .drained || !pendingAudio.isEmpty { onInterrupt?() }
            transcript.cut()
            pendingAudio = []
            responseDone = true
            closedThisTurn = false
            setState(.listening, now: now)
            return [.clearPlayback(fade: true)]
        case "vad_score":
            let score = (ev["vad_score_event"] as? [String: Any])?["vad_score"] as? Double ?? 0
            let speaking = score > Self.vadThreshold
            if speaking, !userSpeaking {
                userSpeaking = true
                closedThisTurn = false
                if state == .speaking { transcript.hold() }
                if state != .speaking { setState(.listening, now: now) }
            } else if !speaking, userSpeaking {
                userSpeaking = false
                if state == .listening, playback == .drained { setState(.thinking, now: now) }
            }
            return []
        case "user_transcript":
            let text = (ev["user_transcription_event"] as? [String: Any])?["user_transcript"] as? String
            transcript.userDone(text, now: now * 1000)
            closedThisTurn = false
            if state != .speaking { setState(.thinking, now: now) }
            return []
        default:
            // agent_response_correction / tool calls / metadata events: no bearing on the visual.
            return []
        }
    }

    /// 30 Hz once the graph is up: the playback-timeline gate + the thinking guard; `level` is
    /// the played audio's (for the transcript).
    public func tick(playback: PlaybackState, level: Double = 0, now: TimeInterval) {
        guard graphReady else { return }
        transcript.tick(now: now * 1000, level: level, speaking: state == .speaking)
        switch playback {
        case .audible: setState(.speaking, now: now)
        case .drained:
            if state == .speaking {
                // Drained mid-reply is a stall (more audio is coming), not the end of the turn.
                setState(responseDone ? .listening : .thinking, now: now)
            } else if state == .thinking {
                if responseDone {
                    if now - thinkingSince > Self.thinkingTimeout { setState(.listening, now: now) }
                } else if now - lastAudioAt > Self.stallTimeout {
                    responseDone = true
                    setState(.listening, now: now)
                }
            }
        case .queued: break
        }
    }

    private func enqueueAction(_ b64: String, isFinal: Bool, alignment: [String: Any]?, now: TimeInterval) -> Action {
        let bytes = Data(base64Encoded: b64) ?? Data()
        let samples = output.codec == .ulaw ? Pcm.ulawToFloat(bytes) : Pcm.pcm16ToFloat(bytes)
        if let al = alignment, let chars = al["chars"] as? [String], !chars.isEmpty,
            let starts = al["char_start_times_ms"] as? [NSNumber]
        {
            replyAligned = true
            let durations = (al["char_durations_ms"] as? [NSNumber]) ?? []
            for f in TranscriptAssembler.alignmentFragments(
                chars: chars, startsMs: starts.map(\.doubleValue), durationsMs: durations.map(\.doubleValue),
                offsetMs: replyAudioMs)
            {
                transcript.assistantDelta(f.text, now: now * 1000, startMs: f.startMs, endMs: f.endMs)
            }
        }
        replyAudioMs += Double(samples.count) / Double(output.rate) * 1000
        lastAudioAt = now
        if isFinal {
            responseDone = true
            closedThisTurn = true
        } else if !closedThisTurn {
            responseDone = false
        }
        // Received, not audible yet: tick() promotes to speaking when playback reaches it.
        if state != .speaking { setState(.thinking, now: now) }
        return .enqueue(samples, rate: output.rate)
    }

    /// `agent_response_complete`: the reply is over. With nothing left to play (a text-only
    /// or empty reply, or audio already drained) the turn ends now; otherwise tick() ends
    /// it when playback drains.
    private func endResponse(playback: PlaybackState, now: TimeInterval) {
        responseDone = true
        closedThisTurn = true
        // No chunk carried an alignment: the reply's text, untimed.
        if !replyAligned, !replyText.isEmpty { transcript.assistantDelta(replyText, now: now * 1000) }
        replyText = ""
        if state == .thinking, playback == .drained, pendingAudio.isEmpty { setState(.listening, now: now) }
    }

    private func setState(_ s: AgentState, now: TimeInterval) {
        guard s != state else { return }
        // The reply is over (drained, stalled out, or cut just before): its turn ends if it was
        // heard, and the next reply's audio starts at 0 ms.
        if s == .listening || s == .idle {
            transcript.speakingEnded()
            replyAudioMs = 0
            replyAligned = false
        }
        state = s
        if s == .thinking { thinkingSince = now }
        onState?(s)
    }
}
