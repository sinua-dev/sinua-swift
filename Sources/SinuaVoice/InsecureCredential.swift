import Foundation

/// The one rule about long-lived API keys, shared by every adapter that could be
/// handed one: **a raw key is always refused.** The Swift port of
/// `packages/voice/src/insecureCredential.ts`; the message text is identical on
/// all three platforms.
///
/// A production credential is short-lived and minted server-side: OpenAI's
/// `ek_…` (`POST /v1/realtime/client_secrets`) or Gemini's `auth_tokens/…`
/// (`POST /v1beta/auth_tokens`). A raw account key is long-lived, unscoped and
/// billable. The `allowInsecureApiKey` opt-in is gone: `npx @sinua/voice
/// dev-proxy` mints real short-lived credentials on localhost, and
/// `@sinua/voice/server` does it in a backend.
///
/// Placement: the check runs inside `connect()` (never an initialiser -- the
/// Studio builds a source outside its `do`/`catch`), on every credential a
/// source resolves, before the permission prompt, the microphone and the socket.
public enum InsecureCredential {
    /// The refusal message for anything that isn't the short-lived shape, or `nil`.
    public static func refusal(vendor: String, isEphemeral: Bool, ephemeralShape: String) -> String? {
        if isEphemeral { return nil }
        return "\(vendor): expected a short-lived credential (\(ephemeralShape)); refusing what looks like a raw, "
            + "long-lived API key. Mint one in your backend with @sinua/voice/server, or run "
            + "`npx @sinua/voice dev-proxy` and pass `credentialUrl`."
    }

    /// Throws a fatal `CredentialError` for anything that isn't the short-lived shape.
    public static func check(vendor: String, isEphemeral: Bool, ephemeralShape: String) throws {
        if let message = refusal(vendor: vendor, isEphemeral: isEphemeral, ephemeralShape: ephemeralShape) {
            throw CredentialError.fatal(message)
        }
    }

    /// `auth_tokens/…` is Gemini's ephemeral shape.
    public static func isGeminiEphemeral(_ credential: String) -> Bool {
        credential.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("auth_tokens/")
    }

    /// `ek_…` is OpenAI's ephemeral shape.
    public static func isOpenAIEphemeral(_ credential: String) -> Bool {
        credential.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ek_")
    }

    public static let geminiShape = "auth_tokens/…"
    public static let openAIShape = "ek_…"
}
