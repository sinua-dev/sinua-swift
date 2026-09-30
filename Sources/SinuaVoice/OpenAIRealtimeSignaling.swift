import Foundation

/// OpenAI Realtime WebRTC signaling without WebRTC: the call request and its
/// response handling (developers.openai.com `guides/voice-webrtc`), shared by the
/// glue and its tests. The `ek_` itself is minted by your backend
/// (`@sinua/voice/server`), never on the device.
public enum OpenAIRealtimeSignaling {
    public static let callsURL = URL(string: "https://api.openai.com/v1/realtime/calls")!
    public static let defaultModel = "gpt-realtime"
    public static let defaultVoice = "marin"

    public enum SignalingError: Error, Equatable {
        /// 400/401/403 and other non-retryable statuses: don't retry.
        case fatal(status: Int, body: String)
        case retryable(status: Int, body: String)
        case malformed(String)
    }

    /// WARP's pre-negotiated event channel id (any free id works; the same one goes in `dcid`).
    public static let warpDataChannelId: Int32 = 1
    /// WARP's libwebrtc field trials (developers.openai.com `guides/realtime-webrtc-warp`):
    /// DTLS 1.3, SNAP and SPED. Process-wide, and only read before the first peer connection factory.
    public static let warpFieldTrials =
        "WebRTC-ForceDtls13/Enabled/WebRTC-Sctp-Snap/Enabled/WebRTC-IceHandshakeDtls/Enabled/"

    /// The SDP offer -> `POST /v1/realtime/calls` with the ephemeral key; the answer SDP comes back
    /// as text. `dcid`: WARP's pre-negotiated event channel id, sent along as `?dcid=`.
    public static func callsRequest(sdpOffer: String, ephemeralKey: String, url: URL = callsURL, dcid: Int32? = nil)
        -> URLRequest
    {
        var target = url
        if let dcid, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let kept = (c.queryItems ?? []).filter { $0.name != "dcid" }
            c.queryItems = kept + [URLQueryItem(name: "dcid", value: String(dcid))]
            target = c.url ?? url
        }
        var r = URLRequest(url: target)
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
