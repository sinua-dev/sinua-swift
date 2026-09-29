import SinuaVoiceTypes
import SwiftUI

/// A mic button bound to a voice source (docs/fx-view.md, *Voice button*): ready,
/// connecting, listening, muted or error, derived from the source. The logic is
/// `VoiceButtonController` (the same state table as Web and Android); the ring behind
/// the icon is an ordinary engine view.
///
/// ```swift
/// SinuaView(pattern: "glowing", voice: source)
/// SinuaVoiceButton(source: source)                      // tap: connect, then mute / unmute
/// SinuaVoiceButton(source: source, mode: .pushToTalk)   // hold to talk
/// ```
/// Give the view and the button the same source: both go through its
/// `SharedVoiceSource`, so neither steals the other's callbacks. A long press or the
/// small ✕ ends the session. The button is bound to the source it was created with;
/// to swap sources, give it a new identity (`.id(source)`).
public struct SinuaVoiceButton: View {
    @StateObject private var model: VoiceButtonViewModel
    private let labels: VoiceButtonLabels
    private let size: CGFloat
    @State private var pressStarted = false
    @State private var longPressFired = false
    @State private var longPress: DispatchWorkItem?

    /// Hold this long to end the session (also the ✕ and the "End voice session" action).
    public static let longPressSeconds = 0.6

    public init(
        source: VoiceSource,
        mode: VoiceButtonMode = .toggle,
        labels: VoiceButtonLabels = VoiceButtonLabels(),
        size: CGFloat = 56,
        onChange: ((VoiceButtonState, String?) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: VoiceButtonViewModel(source: source, mode: mode, onChange: onChange))
        self.labels = labels
        self.size = size
    }

    public var body: some View {
        let state = model.state
        let live = state == .connecting || state == .listening || state == .muted
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.07))
                if let ring = Self.ring(state) {
                    // The ring sits on the button's edge and swells outward with the level.
                    SinuaView(
                        pattern: ring.pattern, overrides: ring.overrides, speed: ring.speed, state: ring.state,
                        voiceOverrides: model.ringVoice.overrides, accessibilityLabel: ""
                    )
                    .frame(width: size * 1.28, height: size * 1.28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Image(systemName: icon(state))
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundColor(tint(state))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(pressGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(state))
            .accessibilityHint(voiceButtonHint(state, mode: model.mode, canMute: model.canMute))
            .accessibilityAddTraits(state == .muted ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.controller.assistiveActivate() }
            .accessibilityAction(named: Text(labels.end)) { if live { model.controller.end() } }

            if live {
                Button {
                    model.controller.end()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(.systemBackground)))
                        .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .offset(x: 6, y: -6)
                .accessibilityLabel(labels.end)
            }
        }
        .frame(width: size, height: size)
    }

    /// Toggle: a tap presses. Push-to-talk: touching presses, lifting releases. Either
    /// way, holding `longPressSeconds` ends the session instead.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressStarted else { return }
                pressStarted = true
                longPressFired = false
                if model.mode == .pushToTalk { model.controller.press() }
                let work = DispatchWorkItem {
                    let s = model.controller.state
                    guard s != .ready && s != .error else { return }
                    longPressFired = true
                    model.controller.end()
                }
                longPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressSeconds, execute: work)
            }
            .onEnded { _ in
                pressStarted = false
                longPress?.cancel()
                longPress = nil
                if longPressFired { return }
                if model.mode == .pushToTalk { model.controller.release() } else { model.controller.press() }
            }
    }

    private func label(_ s: VoiceButtonState) -> String {
        if s == .error, let reason = model.reason { return "\(labels.error): \(reason)" }
        return labels.label(s)
    }

    private func icon(_ s: VoiceButtonState) -> String {
        switch s {
        case .error: return "exclamationmark.circle"
        case .muted: return "mic.slash"
        default: return "mic"
        }
    }

    private func tint(_ s: VoiceButtonState) -> Color {
        switch s {
        case .error: return .red
        case .muted: return .secondary
        default: return .primary
        }
    }

    /// The inner ring per state (Web's `voiceButtonRing`): an engine view, or none.
    static func ring(_ s: VoiceButtonState)
        -> (pattern: String, state: String, overrides: [String: Double], speed: Double)?
    {
        let ring: [String: Double] = ["progress": 1, "strokeWidth": 0.045]
        switch s {
        case .connecting: return ("loading", "initializing", ["strokeWidth": 0.045, "trackOpacity": 0.15], 1)
        case .listening: return ("completing", "listening", ring, 1)
        case .muted: return ("completing", "listening", ring, 0.15)
        default: return nil
        }
    }
}

/// Holds the controller and the ring's own tracker for `SinuaVoiceButton`.
final class VoiceButtonViewModel: ObservableObject {
    let controller: VoiceButtonController
    /// The ring's tracker: a stronger pulse than a view's default (0.18 barely moves a ring this small).
    let ringVoice: SharedVoiceSource.Tracked
    @Published private(set) var state: VoiceButtonState = .ready
    @Published private(set) var reason: String?
    private var off: (() -> Void)?

    init(source: VoiceSource, mode: VoiceButtonMode, onChange: ((VoiceButtonState, String?) -> Void)?) {
        controller = VoiceButtonController(source: source, mode: mode)
        var options = VoiceOverridesOptions()
        options.audioStrength = 0.75
        ringVoice = controller.source.track(options: options)
        off = controller.onChange { [weak self] m in
            self?.state = m.state
            self?.reason = m.reason
            onChange?(m.state, m.reason)
        }
    }

    deinit { off?() }

    var mode: VoiceButtonMode { controller.mode }
    var canMute: Bool { controller.canMute }
}
