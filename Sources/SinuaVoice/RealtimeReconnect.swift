import Foundation

/// OpenAI Realtime reconnect policy + transcript replay -- a port of
/// packages/voice/src/realtimeReconnect.ts. Realtime has no session
/// resumption: a drop is replaced by a new session with a fresh credential,
/// and the finalized transcript is replayed as `conversation.item.create`.
public enum RealtimeReconnect {
    public static let defaultAttempts = 3
    static let firstDelayMs = 100.0  // LiveKit's `_interval_for_retry(0)`
    static let baseDelayMs = 1000.0
    static let maxDelayMs = 8000.0
    static let jitter = 0.2

    /// Delay before attempt `attempt` (1-based); `random` in 0..<1.
    public static func delayMs(attempt: Int, random: Double = Double.random(in: 0..<1)) -> Int {
        let nominal = attempt <= 1 ? firstDelayMs : min(maxDelayMs, baseDelayMs * pow(2, Double(attempt - 2)))
        let j = 1 + jitter * (2 * random - 1)
        return max(0, Int((nominal * j).rounded()))
    }

    public static let fatalErrorCodes: Set<String> = [
        "insufficient_quota", "invalid_api_key", "account_deactivated", "billing_hard_limit_reached",
    ]

    public static func isFatalError(code: String?) -> Bool { code.map(fatalErrorCodes.contains) ?? false }

    public static func isRetryable(httpStatus: Int) -> Bool {
        httpStatus == 408 || httpStatus == 425 || httpStatus == 429 || httpStatus >= 500
    }
}

/// The finalized conversation, kept for replay after a reconnect.
public final class TranscriptLog {
    public enum Role: String { case user, assistant }
    public struct Turn: Equatable {
        public let role: Role
        public let text: String
    }

    private let maxChars: Int
    private let maxItems: Int
    private var turns: [Turn] = []

    public init(maxChars: Int = 8000, maxItems: Int = 40) {
        self.maxChars = maxChars
        self.maxItems = maxItems
    }

    public func add(_ role: Role, _ text: String?) {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        turns.append(Turn(role: role, text: t))
        if turns.count > maxItems * 2 { turns = window() }
    }

    public func clear() { turns.removeAll() }
    public var count: Int { turns.count }

    /// The newest turns within both budgets, oldest first.
    public func window() -> [Turn] {
        var out: [Turn] = []
        var chars = 0
        for turn in turns.reversed() {
            if out.count >= maxItems || chars + turn.text.count > maxChars { break }
            chars += turn.text.count
            out.append(turn)
        }
        return out.reversed()
    }

    /// `conversation.item.create` client events, in order, for a new session's data channel.
    public func replayEvents() -> [String] {
        window().map { turn in
            GeminiLiveSession.json([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": turn.role.rawValue,
                    "content": [["type": turn.role == .user ? "input_text" : "output_text", "text": turn.text]],
                ] as [String: Any],
            ])
        }
    }
}
