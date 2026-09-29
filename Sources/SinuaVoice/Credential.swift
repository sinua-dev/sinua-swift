import Foundation

/// The one credential contract every vendor source takes, on every platform --
/// the Swift port of `packages/voice/src/credential.ts` (docs/audio-pipeline.md,
/// *Credentials for a real integration*).
///
/// Your backend mints a short-lived credential and answers with this JSON, the
/// same shape for OpenAI (`ek_…`), Gemini (`auth_tokens/…`), ElevenLabs (a signed
/// `wss://` URL) and LiveKit (a room JWT plus the server `url`):
/// `{ "credential": "…", "expiresAt": 1790000000, "url": "wss://…" }`.
public struct SinuaCredential: Equatable, Sendable {
    /// The short-lived credential itself.
    public let credential: String
    /// When it stops working, in Unix seconds, if the vendor says.
    public let expiresAt: Double?
    /// LiveKit only: the server URL the token is for.
    public let url: String?

    public init(credential: String, expiresAt: Double? = nil, url: String? = nil) {
        self.credential = credential
        self.expiresAt = expiresAt
        self.url = url
    }
}

/// A credential failure. `fatal` is one a retry can't fix (a 4xx, a bad
/// shape, a refused raw key); `retryable` is a network error, a 429 or a 5xx.
/// The credential itself never appears in the message.
public enum CredentialError: LocalizedError, Equatable {
    case fatal(String)
    case retryable(String)

    public var errorDescription: String? {
        switch self {
        case .fatal(let m), .retryable(let m): return m
        }
    }

    public var isFatal: Bool {
        if case .fatal = self { return true }
        return false
    }
}

/// How a `credentialUrl` is fetched: (request) -> (HTTP status, body). Tests pass a fake.
public typealias CredentialHTTP = @Sendable (URLRequest) async throws -> (Int, Data)

/// Where a source gets its credential. Asked again on **every** connect and
/// reconnect, so an expired or spent credential is never reused.
public struct CredentialSource: Sendable {
    /// True when a reconnect can get a *new* credential (a provider or a URL).
    public let canRefresh: Bool
    private let fetch: @Sendable (String) async throws -> SinuaCredential

    /// One fixed value: a credential pasted for a single session, or
    /// ElevenLabs' public agent id.
    public static func value(_ credential: String) -> CredentialSource {
        CredentialSource(canRefresh: false) { vendor in try parse(vendor: vendor, credential) }
    }

    /// The production shape: your code fetches a fresh credential from your backend.
    public static func provider(_ provide: @escaping @Sendable () async throws -> SinuaCredential) -> CredentialSource {
        CredentialSource(canRefresh: true) { vendor in
            let c = try await provide()
            return try parse(vendor: vendor, c.credential, expiresAt: c.expiresAt, url: c.url)
        }
    }

    /// Shorthand for a provider that `POST`s to your endpoint (no body, no
    /// cache) and reads a `SinuaCredential` back -- the same on every platform.
    public static func url(_ url: URL, http: @escaping CredentialHTTP = CredentialSource.urlSession) -> CredentialSource
    {
        CredentialSource(canRefresh: true) { vendor in
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let status: Int
            let body: Data
            do {
                (status, body) = try await http(req)
            } catch {
                throw CredentialError.retryable(
                    "\(vendor): \(url.absoluteString) failed: \(error.localizedDescription)")
            }
            guard (200..<300).contains(status) else {
                let message = "\(vendor): \(url.absoluteString) returned \(status)"
                throw isRetryableHTTPStatus(status)
                    ? CredentialError.retryable(message) : CredentialError.fatal(message)
            }
            return try decode(vendor: vendor, body)
        }
    }

    /// `URLSession.shared`, as a `CredentialHTTP`.
    public static let urlSession: CredentialHTTP = { req in
        let (data, res) = try await URLSession.shared.data(for: req)
        return ((res as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    init(canRefresh: Bool, fetch: @escaping @Sendable (String) async throws -> SinuaCredential) {
        self.canRefresh = canRefresh
        self.fetch = fetch
    }

    /// The credential for this (re)connect. `needsURL`: LiveKit, whose answer must carry `url`.
    public func resolve(vendor: String, needsURL: Bool = false) async throws -> SinuaCredential {
        let c = try await fetch(vendor)
        if needsURL, (c.url ?? "").isEmpty {
            throw CredentialError.fatal("\(vendor): the credential has no `url` (LiveKit needs { credential, url })")
        }
        return c
    }

    /// Validates an endpoint's JSON answer against `SinuaCredential`.
    public static func decode(vendor: String, _ body: Data) throws -> SinuaCredential {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else {
            throw CredentialError.fatal("\(vendor): the credential endpoint did not return JSON")
        }
        guard let o = obj as? [String: Any] else { throw CredentialError.fatal("\(vendor): a credential is required") }
        guard let c = o["credential"] as? String else {
            let keys = o.keys.sorted().joined(separator: ", ")
            throw CredentialError.fatal(
                "\(vendor): expected { credential: string, expiresAt?, url? }, got keys [\(keys)]")
        }
        var expiresAt: Double?
        if let e = o["expiresAt"], !(e is NSNull) {
            guard let n = e as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                throw CredentialError.fatal("\(vendor): `expiresAt` must be Unix seconds (a number)")
            }
            expiresAt = n.doubleValue
        }
        var url: String?
        if let u = o["url"], !(u is NSNull) {
            guard let s = u as? String else { throw CredentialError.fatal("\(vendor): `url` must be a string") }
            url = s
        }
        return try parse(vendor: vendor, c, expiresAt: expiresAt, url: url)
    }

    static func parse(vendor: String, _ credential: String, expiresAt: Double? = nil, url: String? = nil) throws
        -> SinuaCredential
    {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { throw CredentialError.fatal("\(vendor): a credential is required") }
        return SinuaCredential(credential: c, expiresAt: expiresAt, url: url)
    }

    /// Timeouts, rate limits and server errors are worth retrying; any other 4xx isn't.
    static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || status >= 500
    }
}
