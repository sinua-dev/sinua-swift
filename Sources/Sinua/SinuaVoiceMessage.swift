import CoreEngine
import SwiftUI

/// A recorded voice message's waveform (signal `playing`) with drag-to-seek: the
/// chat-bubble control.
///
/// ```swift
/// SinuaVoiceMessage(envelope: peaks, progress: player.position) { p in player.seek(to: p) }
///     .frame(width: 220, height: 40)
/// ```
///
/// Sinua decodes no audio: pass the clip's loudness as `envelope` (up to 64 values,
/// 0...1) and the position as `progress`. A drag or a tap reports the position under
/// the finger through `onSeek`, on the same row of bars the engine draws. VoiceOver:
/// an adjustable element (swipe up / down moves 5 %).
public struct SinuaVoiceMessage: View {
    public static let maxEnvelope = 64

    let envelope: [Double]
    let progress: Double
    let label: String
    let overrides: [String: Double]
    let theme: FxTheme
    let onSeek: ((Double) -> Void)?

    public init(
        envelope: [Double],
        progress: Double,
        label: String = "Voice message",
        overrides: [String: Double] = [:],
        theme: FxTheme = .auto,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.envelope = envelope
        self.progress = min(1, max(0, progress))
        self.label = label
        self.overrides = overrides
        self.theme = theme
        self.onSeek = onSeek
    }

    /// The position under a point `x` points from the left of a `size` box.
    public static func seek(size: CGSize, x: CGFloat) -> Double {
        guard size.width > 0, size.height > 0 else { return 0 }
        return playbackSeekProgress(aspect: Double(size.width / size.height), x: Double(x / size.height))
    }

    var engineKeys: [String: Double] {
        var o = overrides
        o["progress"] = progress
        for (i, v) in envelope.prefix(Self.maxEnvelope).enumerated() { o["envelope\(i)"] = v }
        return o
    }

    public var body: some View {
        GeometryReader { g in
            SinuaView(pattern: "playing", overrides: engineKeys, theme: theme, accessibilityLabel: "")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { onSeek?(Self.seek(size: g.size, x: $0.location.x)) }
                        .onEnded { onSeek?(Self.seek(size: g.size, x: $0.location.x)) },
                    including: onSeek == nil ? .none : .all
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((progress * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek?(min(1, progress + 0.05))
            case .decrement: onSeek?(max(0, progress - 0.05))
            @unknown default: break
            }
        }
    }
}
