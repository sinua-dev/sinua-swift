import Foundation

/// A one-shot feedback effect to play on a `SinuaView` (docs/fx-view.md, *One-shot
/// effects*). Each value carries a fresh id, so assigning a new one plays it once, even
/// for the same kind:
///
/// ```swift
/// @State var effect: SinuaEffectTrigger?
/// SinuaView(pattern: "tracking", effect: effect)
/// effect = SinuaEffectTrigger(.celebrate)
/// ```
public struct SinuaEffectTrigger: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A green tint, a ring and a tick (0.9 s); spoken "Done".
        case success
        /// A short shake with a red tint (0.5 s); spoken "Something went wrong".
        case error
        /// A burst of particles (1.4 s); spoken "Well done".
        case celebrate
        /// A character's tap hop (0.6 s), silent; other families draw nothing for it.
        /// A `SinuaView` with `tap` plays it on a tap, glancing toward the tap.
        case hop
    }

    public let kind: Kind
    public let id: UUID

    public init(_ kind: Kind) {
        self.kind = kind
        id = UUID()
    }
}
