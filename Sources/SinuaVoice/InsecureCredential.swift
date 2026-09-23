import Foundation

/// The one rule about long-lived API keys, shared by every adapter that can be
/// handed one. The Swift port of `packages/voice/src/insecureCredential.ts`;
/// the message text is deliberately identical on all three platforms.
///
/// A production credential is short-lived and minted server-side: OpenAI's
/// `ek_…` (`POST /v1/realtime/client_secrets`) or Gemini's `auth_tokens/…`
/// (`POST /v1beta/auth_tokens`). A raw account key is a different object --
/// long-lived, unscoped and billable -- so it is **refused** unless the caller
/// opts in with `allowInsecureApiKey`. Prior art for the shape:
/// `openai-agents-js` refuses a raw key in a browser unless `useInsecureApiKey`
/// is set.
///
/// Placement rules this type exists to keep consistent:
///
/// - the check runs inside `connect()`, **never an initialiser** -- the Studio
///   builds a source outside its `do`/`catch`, so a throwing init would take
///   the panel down instead of showing the error inline;
/// - it runs before the microphone, the audio graph and the socket, so a
///   refused credential never opens a device or a connection.
public enum InsecureCredential {
    /// Raised by `check` when a raw key is used without the opt-in.
    public struct Refused: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Throws `Refused` for a raw key used without the opt-in; returns normally
    /// when the connect may go ahead. When a raw key *is* allowed, this warns
    /// once per call, so a local demo can't quietly turn into a deployment.
    ///
    /// - Parameter warn: the sink for that warning; overridable so tests can
    ///   observe it without printing.
    public static func check(
        vendor: String,
        isEphemeral: Bool,
        allowInsecureApiKey: Bool,
        ephemeralShape: String,
        mintHint: String,
        warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) throws {
        if isEphemeral { return }
        guard allowInsecureApiKey else {
            throw Refused(
                message:
                    "\(vendor): refusing a raw, long-lived API key. Pass a short-lived credential "
                    + "(\(ephemeralShape)) minted by your own backend (\(mintHint)). "
                    + "For a local demo only, set `allowInsecureApiKey: true`.")
        }
        warn(
            "\(vendor): connecting with a raw, long-lived API key because `allowInsecureApiKey` "
                + "is set. That key is exposed on the device -- this is for local demos, not for "
                + "shipping. In a product, send a \(ephemeralShape) minted by your backend (\(mintHint)).")
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
    public static let geminiMintHint = "POST https://generativelanguage.googleapis.com/v1beta/auth_tokens"
    public static let openAIShape = "ek_…"
    public static let openAIMintHint = "POST https://api.openai.com/v1/realtime/client_secrets"
}
