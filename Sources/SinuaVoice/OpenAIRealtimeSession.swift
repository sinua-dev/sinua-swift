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
    public static let speakingTailFrames = 9  // ~300 ms at 30 Hz

    public private(set) var state: AgentState = .idle
    public let transcript = TranscriptLog()
    /// A fatal `error.code` seen this session (e.g. `invalid_api_key`): don't reconnect.
    public private(set) var fatalCode: String?
    private var responseActive = false
    private var sawOutputBufferEvents = false
    private var quietFrames = 0

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?

    public init() {}

    public func connecting() {
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
    }

    /// A server event from the `oai-events` data channel.
    public func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
            let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = ev["type"] as? String
        else { return }
        switch type {
        case "input_audio_buffer.speech_started":
            // Barge-in only over audible output; speech over `thinking` isn't one.
            if state == .speaking { onInterrupt?() }
            setState(.listening)
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
        case "error":
            let code = (ev["error"] as? [String: Any])?["code"] as? String
            if RealtimeReconnect.isFatalError(code: code) { fatalCode = code }
        default:
            break
        }
    }

    /// 30 Hz with the remote track's current level: the energy fallback only.
    public func tick(level: Double) {
        if level > Self.speakingLevel {
            quietFrames = 0
            if state == .thinking, responseActive, !sawOutputBufferEvents { setState(.speaking) }
        } else if state == .speaking, !sawOutputBufferEvents, !responseActive {
            quietFrames += 1
            if quietFrames >= Self.speakingTailFrames { setState(.listening) }
        }
    }

    private func setState(_ s: AgentState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}
