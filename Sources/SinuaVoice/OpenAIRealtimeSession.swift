import Foundation

/// The I/O-free half of the native OpenAI Realtime `VoiceSource` (the WebRTC glue
/// is `SinuaOpenAI`): a port of packages/voice/src/OpenAIRealtimeVoiceSource.ts's
/// event handling and tick rules. Main thread.
///
/// Vendor events drive state (server VAD, response lifecycle); the WebRTC-only
/// `output_audio_buffer.started/stopped/cleared` say when the model is audible
/// and when it drained. They are documented inconsistently, so until one is
/// seen an energy fallback on the remote track decides `speaking` (above 0.05
/// during a response; left after ~300 ms of quiet once `response.done`).
public final class OpenAIRealtimeSession {
    public static let speakingLevel = 0.05
    /// The Live session's adaptive tail (design note 31, V7), counted in this session's ticks.
    public static var speakingTailFrames: Int { OpenAILiveSession.speakingTailFrames }

    public private(set) var state: AgentState = .idle
    public let transcript = TranscriptLog()
    /// A fatal `error.code` seen this session (e.g. `invalid_api_key`): don't reconnect.
    public private(set) var fatalCode: String?
    private var responseActive = false
    private var sawOutputBufferEvents = false
    private var quietFrames = 0
    /// 30 Hz ticks since the current speaking stretch began.
    private var speakingTicks = 0

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?
    /// Events for the data channel (the glue sends them): turning the input transcription on.
    public var onSend: ((String) -> Void)?

    /// Live transcripts (design note 39; not the replay log above): no times from Realtime, so
    /// `none` timing; the user's turn ends at `.completed`.
    public let captions: TranscriptAssembler
    /// Setting it also asks for the session's input transcription (see `init`).
    public var onTranscript: ((TranscriptUpdate) -> Void)? {
        get { captions.onUpdate }
        set {
            captions.onUpdate = newValue
            captionsWanted = newValue != nil
            transcribeUserIfNeeded()
        }
    }
    private let transcribeModel: String?
    private var captionsWanted = false
    private var sessionCreated = false
    /// This session's input transcription is on (its own, or ours).
    private var userTranscribed = false

    /// `transcribeUser`: opt in to the user's side of transcripts with an input transcription model
    /// (e.g. "gpt-4o-mini-transcribe"), turned on when something listens and the session has none.
    /// OpenAI bills it per minute, so it is never turned on by default: `nil` (the default) gives the
    /// assistant's text only, unless your backend's session transcribes.
    public init(syncToAudio: Bool = true, transcribeUser: String? = nil) {
        captions = TranscriptAssembler(timing: .none, sync: syncToAudio, explicitUserEnd: true)
        transcribeModel = transcribeUser
    }

    private func transcribeUserIfNeeded() {
        guard captionsWanted, sessionCreated, !userTranscribed, let model = transcribeModel else { return }
        userTranscribed = true
        onSend?(
            GeminiLiveSession.json([
                "type": "session.update",
                "session": ["type": "realtime", "audio": ["input": ["transcription": ["model": model]]]],
            ]))
    }

    public func connecting() {
        // A new call: open transcript turns end; ids keep counting.
        captions.stop()
        sessionCreated = false
        userTranscribed = false
        responseActive = false
        sawOutputBufferEvents = false
        quietFrames = 0
        fatalCode = nil
        setState(.initializing)
    }

    /// The data channel opened: the session is live.
    public func connected() { setState(.listening) }

    public func stopped() {
        responseActive = false
        setState(.idle)
        captions.stop()
    }

    /// A server event from the `oai-events` data channel; `now` (seconds) times the transcript.
    public func handle(_ text: String, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard let data = text.data(using: .utf8),
            let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = ev["type"] as? String
        else { return }
        let ms = now * 1000
        switch type {
        case "session.created":
            // A new session: its own input transcription, if any, stands.
            let input = ((ev["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any]
            userTranscribed = input?["transcription"].map { !($0 is NSNull) } ?? false
            sessionCreated = true
            transcribeUserIfNeeded()
        case "input_audio_buffer.speech_started":
            // Barge-in only over audible output; speech over `thinking` isn't one.
            if state == .speaking {
                onInterrupt?()
                captions.cut()
            }
            setState(.listening)
        case "response.output_audio_transcript.delta":
            if let d = ev["delta"] as? String { captions.assistantDelta(d, now: ms) }
        case "conversation.item.input_audio_transcription.delta":
            if let d = ev["delta"] as? String { captions.userDelta(d, now: ms) }
        case "input_audio_buffer.speech_stopped":
            setState(.thinking)
        case "response.created":
            responseActive = true
            quietFrames = 0
            setState(.thinking)
        case "output_audio_buffer.started":
            sawOutputBufferEvents = true
            setState(.speaking)
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            sawOutputBufferEvents = true
            responseActive = false
            setState(.listening)
        case "response.done":
            responseActive = false
            // A response with no audio never gets output_audio_buffer.stopped -- don't hang.
            if state == .thinking { setState(.listening) }
        case "response.output_audio_transcript.done":
            transcript.add(.assistant, ev["transcript"] as? String)
        case "conversation.item.input_audio_transcription.completed":
            transcript.add(.user, ev["transcript"] as? String)
            captions.userDone(ev["transcript"] as? String, now: ms)
        case "error":
            let code = (ev["error"] as? [String: Any])?["code"] as? String
            if RealtimeReconnect.isFatalError(code: code) { fatalCode = code }
        default:
            break
        }
    }

    /// 30 Hz with the remote track's current level: the energy fallback, and the transcript.
    public func tick(level: Double, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        captions.tick(now: now * 1000, level: level, speaking: state == .speaking)
        if state == .speaking { speakingTicks += 1 }
        if level > Self.speakingLevel {
            quietFrames = 0
            if state == .thinking, responseActive, !sawOutputBufferEvents { setState(.speaking) }
        } else if state == .speaking, !sawOutputBufferEvents, !responseActive {
            quietFrames += 1
            let tail = OpenAILiveSession.speakingTail(ms: Double(speakingTicks) * 1000 / 30)
            if quietFrames >= tail { setState(.listening) }
        }
    }

    private func setState(_ s: AgentState) {
        guard s != state else { return }
        if s == .speaking { speakingTicks = 0 }
        // The reply is over (played out, cut just before, or a reconnect): its turn ends if it was heard.
        if s == .listening || s == .initializing || s == .idle { captions.speakingEnded() }
        state = s
        onState?(s)
    }
}
