import Foundation

/// OpenAI Realtime WebRTC signaling without WebRTC: the two HTTP requests and
/// their response handling (developers.openai.com `guides/voice-webrtc`,
/// `realtime/client_secrets`), shared by the glue and its tests.
public enum OpenAIRealtimeSignaling {
    public static let callsURL = URL(string: "https://api.openai.com/v1/realtime/calls")!
    public static let clientSecretsURL = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!
    public static let defaultModel = "gpt-realtime"
    public static let defaultVoice = "marin"

    public enum SignalingError: Error, Equatable {
        /// 400/401/403 and other non-retryable statuses: don't retry.
        case fatal(status: Int, body: String)
        case retryable(status: Int, body: String)
        case malformed(String)
    }

    /// The SDP offer -> `POST /v1/realtime/calls` with the ephemeral key; the answer SDP comes back as text.
    public static func callsRequest(sdpOffer: String, ephemeralKey: String, url: URL = callsURL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(sdpOffer.utf8)
        return r
    }

    public static func answer(status: Int, body: Data) throws -> String {
        let text = String(decoding: body, as: UTF8.self)
        try check(status: status, body: text)
        guard text.hasPrefix("v=") else { throw SignalingError.malformed("the calls response isn't an SDP answer") }
        return text
    }

    /// **DEV ONLY** -- minting an `ek_` on the device with a raw API key, the
    /// Web Studio's demo path. A product mints on its backend and hands the app
    /// the `ek_` (docs/audio-pipeline.md, *Credentials for a real integration*).
    public static func clientSecretRequest(
        apiKey: String, model: String = defaultModel, voice: String = defaultVoice,
        instructions: String? = nil, url: URL = clientSecretsURL
    ) -> URLRequest {
        var session: [String: Any] = [
            "type": "realtime",
            "model": model,
            // server_vad explicitly: speech_started/stopped are documented as emitted in that mode.
            "audio": ["input": ["turn_detection": ["type": "server_vad"]], "output": ["voice": voice]],
        ]
        if let instructions { session["instructions"] = instructions }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(
            GeminiLiveSession.json(["expires_after": ["anchor": "created_at", "seconds": 600], "session": session]).utf8
        )
        return r
    }

    public static func clientSecret(status: Int, body: Data) throws -> String {
        try check(status: status, body: String(decoding: body, as: UTF8.self))
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let value = obj["value"] as? String, !value.isEmpty
        else {
            throw SignalingError.malformed("the client_secrets response had no `value`")
        }
        return value
    }

    /// Performs a signaling request (the glue's HTTP path; tests pass a stubbed session).
    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> (
        status: Int, body: Data
    ) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func check(status: Int, body: String) throws {
        guard !(200..<300).contains(status) else { return }
        if RealtimeReconnect.isRetryable(httpStatus: status) {
            throw SignalingError.retryable(status: status, body: body)
        }
        throw SignalingError.fatal(status: status, body: body)
    }
}
