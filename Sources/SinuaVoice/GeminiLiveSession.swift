import Foundation

/// The I/O-free half of the native Gemini Live `VoiceSource` (the socket glue is
/// `SinuaGeminiLive`): a port of packages/voice/src/GeminiLiveVoiceSource.ts's
/// protocol and state machine. Wire format per ai.google.dev/api/live (checked
/// 2026-09-19). Main thread.
///
/// State mapping, as on Web (Gemini sends no user-VAD events): `setupComplete`
/// -> `listening`; an audio chunk received but not audible -> `thinking`;
/// audible -> `speaking`; drained after `turnComplete`/`generationComplete`/
/// `waitingForInput` -> `listening` (still generating -> `thinking`);
/// `interrupted` -> `listening`, plus a barge-in if there was output to cut;
/// input transcription -> `listening`.
public final class GeminiLiveSession {
    public static let inputRate = 16000
    public static let outputRate = 24000
    public static let defaultModel = "gemini-3.8-live"

    /// Side effects the glue performs on the audio graph / socket.
    public enum Action: Equatable {
        case setupComplete
        case enqueue([Float], rate: Int)
        case clearPlayback(fade: Bool)
        case reconnect(reason: String)
        case serverError(String)
    }

    public let model: String
    public let instructions: String?
    public private(set) var state: AgentState = .idle
    public private(set) var resumptionHandle: String?
    private var generationDone = true
    private var setupDone = false

    public var onState: ((AgentState) -> Void)?
    public var onInterrupt: (() -> Void)?

    public init(model: String = GeminiLiveSession.defaultModel, instructions: String? = nil) {
        self.model = model
        self.instructions = instructions
    }

    // MARK: - Credentials

    public struct Endpoint: Equatable {
        public let url: URL
        public let headers: [String: String]

        public init(url: URL, headers: [String: String]) {
            self.url = url
            self.headers = headers
        }
    }

    /// `auth_tokens/…` (ephemeral, minted by the app's backend) -> the
    /// Constrained method with `Authorization: Token …`; anything else is a raw
    /// API key (dev only) in `x-goog-api-key` -- both as headers, the way
    /// Google's own python-genai `live.py` connects, so no secret is in the URL.
    public static func endpoint(credential: String) -> Endpoint {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService."
        if c.hasPrefix("auth_tokens/") {
            return Endpoint(
                url: URL(string: base + "BidiGenerateContentConstrained")!, headers: ["Authorization": "Token \(c)"])
        }
        return Endpoint(url: URL(string: base + "BidiGenerateContent")!, headers: ["x-goog-api-key": c])
    }

    // MARK: - Messages

    public func setupMessage() -> String {
        var setup: [String: Any] = [
            "model": model.hasPrefix("models/") ? model : "models/\(model)",
            "generationConfig": ["responseModalities": ["AUDIO"]],
            // Gemini's own ASR of the user: the vendor-side "the user is being heard" signal.
            "inputAudioTranscription": [String: Any](),
            "sessionResumption": resumptionHandle.map { ["handle": $0] } ?? [String: Any](),
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
        ]
        if let instructions { setup["systemInstruction"] = ["parts": [["text": instructions]]] }
        return Self.json(["setup": setup])
    }

    public static func micMessage<C: Collection>(_ samples: C) -> String where C.Element == Float {
        json([
            "realtimeInput": [
                "audio": [
                    "data": Pcm.floatToPcm16(samples).base64EncodedString(),
                    "mimeType": "audio/pcm;rate=\(inputRate)",
                ]
            ]
        ])
    }

    // MARK: - Lifecycle

    /// Opening (or reopening) the socket.
    public func connecting() {
        setupDone = false
        generationDone = true
        setState(.initializing)
    }

    /// A fresh `connect()` starts a fresh session (Web's teardown clears the handle).
    public func reset() {
        resumptionHandle = nil
        setupDone = false
        generationDone = true
        setState(.idle)
    }

    /// One server frame (text or decoded binary). `playback` is the graph's current state.
    public func handle(_ text: String, playback: PlaybackState) -> [Action] {
        guard let data = text.data(using: .utf8),
            let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var actions: [Action] = []
        if msg["setupComplete"] != nil, !setupDone {
            setupDone = true
            setState(.listening)
            actions.append(.setupComplete)
            return actions
        }
        if let sc = msg["serverContent"] as? [String: Any] {
            if sc["interrupted"] as? Bool == true {
                // The Live guide: stop playing and clear the queue. A barge-in only if there was output to cut.
                if state == .speaking || playback != .drained { onInterrupt?() }
                actions.append(.clearPlayback(fade: true))
                generationDone = true
                setState(.listening)
            }
            if sc["interimInputTranscription"] != nil || sc["inputTranscription"] != nil, state != .speaking {
                setState(.listening)
            }
            let parts = ((sc["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                    let b64 = inline["data"] as? String,
                    let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                    let bytes = Data(base64Encoded: b64)
                else { continue }
                actions.append(.enqueue(Pcm.pcm16ToFloat(bytes), rate: Pcm.parseRate(mime, fallback: Self.outputRate)))
                generationDone = false
                // Received, not audible yet: tick() promotes to speaking when playback reaches it.
                if state != .speaking { setState(.thinking) }
            }
            if sc["generationComplete"] as? Bool == true || sc["turnComplete"] as? Bool == true
                || sc["waitingForInput"] as? Bool == true
            {
                generationDone = true
            }
        }
        if let upd = msg["sessionResumptionUpdate"] as? [String: Any],
            upd["resumable"] as? Bool == true, let h = upd["newHandle"] as? String, !h.isEmpty
        {
            resumptionHandle = h
        }
        if let goAway = msg["goAway"] as? [String: Any] {
            actions.append(.reconnect(reason: "goAway (timeLeft \(goAway["timeLeft"] as? String ?? "?"))"))
        }
        if let err = msg["error"] { actions.append(.serverError(String(describing: err))) }
        return actions
    }

    /// 30 Hz, only while connected: the playback-timeline gate.
    public func tick(playback: PlaybackState) {
        guard setupDone else { return }
        switch playback {
        case .audible: setState(.speaking)
        case .drained:
            if state == .speaking || state == .thinking { setState(generationDone ? .listening : .thinking) }
        case .queued: break
        }
    }

    private func setState(_ s: AgentState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }

    static func json(_ obj: [String: Any]) -> String {
        // Key order and slash escaping as JSON.stringify writes it.
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
