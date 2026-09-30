import Foundation

/// OpenAI GPT-Live WebRTC signaling without WebRTC, shared by the glue and its tests
/// (packages/voice/src/OpenAILiveVoiceSource.ts). GPT-Live has no client credential:
/// your server opens the session (`POST /v1/live/sessions` with its project key), so the
/// offer goes to *your* endpoint as `{ "sdp": … }` JSON, and the answer is OpenAI's 201
/// JSON passed through (`{ session: { id }, transport: { sdp } }`) or the bare SDP text.
public enum OpenAILiveSignaling {
    /// The offer -> your session endpoint, with your own token when you have one.
    public static func sessionRequest(sdpOffer: String, token: String?, url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["sdp": sdpOffer])
        return r
    }

    /// The SDP answer (and the session id, when the JSON carries it) from a 2xx answer.
    public static func answer(status: Int, body: Data) throws -> (sdp: String, sessionId: String?) {
        let text = String(decoding: body, as: UTF8.self)
        try OpenAIRealtimeSignaling.check(status: status, body: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v=") { return (text, nil) }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let sdp = (json["transport"] as? [String: Any])?["sdp"] as? String,
            sdp.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v=")
        else {
            throw OpenAIRealtimeSignaling.SignalingError.malformed(
                "the session endpoint answered without an SDP answer (expected OpenAI's { session, transport: { sdp } } JSON or the SDP text)"
            )
        }
        return (sdp, (json["session"] as? [String: Any])?["id"] as? String)
    }
}
