import SwiftUI

/// An image in a circle with the ring `talking` round it: the "who is speaking"
/// indicator for call grids, agent lists and chat headers.
///
/// ```swift
/// SinuaAvatar(Image("ada"), label: "Ada", voice: source)
///     .frame(width: 56, height: 56)
/// ```
///
/// The image's diameter is `2 × innerRadius` of the (square) view, the same
/// `innerRadius` the ring draws round, so the two can't drift apart. The ring is
/// decorative; `label` names the avatar for VoiceOver.
public struct SinuaAvatar: View {
    /// Default image radius: the ring `talking`'s own `innerRadius` default.
    public static let defaultInnerRadius = 0.34

    let image: Image
    let label: String
    let innerRadius: Double
    let overrides: [String: Double]
    let state: String?
    let voice: VoiceSource?
    let theme: FxTheme
    let paused: Bool

    public init(
        _ image: Image,
        label: String,
        innerRadius: Double = SinuaAvatar.defaultInnerRadius,
        overrides: [String: Double] = [:],
        state: String? = nil,
        voice: VoiceSource? = nil,
        theme: FxTheme = .auto,
        paused: Bool = false
    ) {
        self.image = image
        self.label = label
        self.innerRadius = min(0.44, max(0.1, innerRadius))
        self.overrides = overrides
        self.state = state
        self.voice = voice
        self.theme = theme
        self.paused = paused
    }

    /// The image's diameter in a view `side` points across.
    static func imageDiameter(side: CGFloat, innerRadius: Double) -> CGFloat {
        side * CGFloat(2 * innerRadius)
    }

    public var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let d = Self.imageDiameter(side: side, innerRadius: innerRadius)
            ZStack {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: d, height: d)
                    .clipShape(Circle())
                    .accessibilityLabel(label)
                SinuaView(
                    pattern: "talking", overrides: overrides.merging(["innerRadius": innerRadius]) { $1 },
                    state: state, voice: voice, theme: theme, paused: paused, accessibilityLabel: ""
                )
                .frame(width: side, height: side)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
