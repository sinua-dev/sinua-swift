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

    /// OpenAI's own API host: a credential sent here must be an `ek_`.
    public static let openAIHost = "api.openai.com"

    /// True when `url` is on OpenAI's own API host (a URL without a host counts as OpenAI: the strict rule).
    public static func isOpenAIHost(_ url: URL) -> Bool {
        guard let host = url.host else { return true }
        return host == openAIHost
    }

    /// OpenAI Realtime's rule, by where the credential goes: to OpenAI it must be an `ek_…`; to
    /// your own calls endpoint (the "sideband" setup, which opens the session server-side) it's
    /// your own short-lived token, any shape except a raw `sk-…` key. The same rule and message
    /// as `openAICredentialRefusal` on the Web and Android.
    public static func openAIRefusal(
        credential: String, callsURL: URL, vendor: String = "OpenAIRealtimeVoiceSource"
    ) -> String? {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if isOpenAIHost(callsURL) {
            return refusal(vendor: vendor, isEphemeral: c.hasPrefix("ek_"), ephemeralShape: openAIShape)
        }
        if c.hasPrefix("sk-") {
            return "\(vendor): your own calls endpoint takes your own short-lived token, never a raw OpenAI key "
                + "(sk-…); keep the key in your backend."
        }
        return nil
    }

    /// Throws a fatal `CredentialError` when `openAIRefusal` refuses.
    public static func checkOpenAI(credential: String, callsURL: URL, vendor: String = "OpenAIRealtimeVoiceSource")
        throws
    {
        if let message = openAIRefusal(credential: credential, callsURL: callsURL, vendor: vendor) {
            throw CredentialError.fatal(message)
        }
    }

    /// OpenAI GPT-Live's rule: the session is only ever opened by your server (there is no
    /// `ek_`), so the session URL must be your own endpoint, never `api.openai.com`, and a
    /// credential for it (optional) is your own token, never a raw `sk-…` key. The same rule
    /// and messages as `openAILiveRefusal` on the Web and Android.
    public static func openAILiveRefusal(
        sessionURL: URL, credential: String?, vendor: String = "OpenAILiveVoiceSource"
    ) -> String? {
        if isOpenAIHost(sessionURL) {
            return "\(vendor): sessionUrl must be your own endpoint; GPT-Live sessions are opened by your server "
                + "with its key (POST /v1/live/sessions), never from the app."
        }
        if let c = credential?.trimmingCharacters(in: .whitespacesAndNewlines), c.hasPrefix("sk-") {
            return "\(vendor): your session endpoint takes your own short-lived token, never a raw OpenAI key "
                + "(sk-…); keep the key in your backend."
        }
        return nil
    }

    /// Throws a fatal `CredentialError` when `openAILiveRefusal` refuses.
    public static func checkOpenAILive(
        sessionURL: URL, credential: String?, vendor: String = "OpenAILiveVoiceSource"
    ) throws {
        if let message = openAILiveRefusal(sessionURL: sessionURL, credential: credential, vendor: vendor) {
            throw CredentialError.fatal(message)
        }
    }
}
