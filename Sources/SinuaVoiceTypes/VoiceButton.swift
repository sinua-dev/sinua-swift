import Foundation

// The voice button's logic -- the Swift mirror of `@sinua/core`'s voiceButton.ts
// (docs/fx-view.md, *Voice button*). A pure state machine plus a controller that runs
// its effects on a source. spec/voice-button-cases.json holds all three platforms to
// the same table. The SwiftUI control is `SinuaVoiceButton` in `Sinua`.

/// `toggle`: a press connects, then mutes and unmutes. `pushToTalk`: hold to talk.
public enum VoiceButtonMode: String, Sendable {
    case toggle, pushToTalk
}

public enum VoiceButtonState: String, Sendable {
    case ready, connecting, listening, muted, error
}

public enum VoiceButtonEvent: Equatable, Sendable {
    case press, release
    /// A long-press or the ✕: end the session.
    case end
    case connectOk
    case connectFail(String)
    /// The session ended on the source's side (a remote hang-up, a drop it gave up on).
    case dropped
    /// The mute changed elsewhere.
    case muteChanged(Bool)
}

public enum VoiceButtonEffect: String, Sendable {
    case connect, disconnect, mute, unmute
}

public struct VoiceButtonModel: Equatable, Sendable {
    public var state: VoiceButtonState = .ready
    /// The last failure, for `.error`.
    public var reason: String?
    /// Push-to-talk: held down right now.
    public var held = false
    public init() {}
}

/// One event in, the next model and the effects to run on the source, in order.
public func voiceButtonStep(
    _ m: VoiceButtonModel, _ e: VoiceButtonEvent, mode: VoiceButtonMode, canMute: Bool
) -> (model: VoiceButtonModel, effects: [VoiceButtonEffect]) {
    func to(
        _ s: VoiceButtonState, _ fx: [VoiceButtonEffect] = [], held: Bool? = nil
    ) -> (VoiceButtonModel, [VoiceButtonEffect]) {
        var n = m
        n.state = s
        if s != .error { n.reason = nil }
        if let held { n.held = held }
        return (n, fx)
    }
    let same = (m, [VoiceButtonEffect]())
    let ptt = mode == .pushToTalk && canMute
    let live = m.state == .listening || m.state == .muted
    switch e {
    case .press:
        if m.state == .ready || m.state == .error { return to(.connecting, [.connect], held: ptt) }
        if m.state == .connecting { return ptt ? to(.connecting, held: true) : same }
        if ptt { return m.state == .muted ? to(.listening, [.unmute], held: true) : to(.listening, held: true) }
        if !canMute { return to(.ready, [.disconnect]) }
        return m.state == .listening ? to(.muted, [.mute]) : to(.listening, [.unmute])
    case .release:
        guard ptt, m.held else { return same }
        if m.state == .listening { return to(.muted, [.mute], held: false) }
        var n = m
        n.held = false
        return (n, [])
    case .end:
        if m.state == .connecting || live { return to(.ready, [.disconnect], held: false) }
        if m.state == .error { return to(.ready, held: false) }
        return same
    case .connectOk:
        guard m.state == .connecting else { return same }
        return ptt && !m.held ? to(.muted, [.mute]) : to(.listening)
    case .connectFail(let reason):
        guard m.state == .connecting else { return same }
        var n = VoiceButtonModel()
        n.state = .error
        n.reason = reason
        return (n, [])
    case .dropped:
        return live ? to(.ready, held: false) : same
    case .muteChanged(let muted):
        guard live else { return same }
        return to(muted ? .muted : .listening)
    }
}

/// The accessible name per state; the same default wording on every platform.
public struct VoiceButtonLabels: Equatable, Sendable {
    public var ready = "Start voice"
    public var connecting = "Connecting"
    public var listening = "Microphone on"
    public var muted = "Microphone muted"
    public var error = "Voice unavailable"
    /// The ✕ / long-press action.
    public var end = "End voice session"
    public init() {}

    public func label(_ s: VoiceButtonState) -> String {
        switch s {
        case .ready: return ready
        case .connecting: return connecting
        case .listening: return listening
        case .muted: return muted
        case .error: return error
        }
    }
}

/// What a screen reader should hear as the action (the hint), per state and mode.
public func voiceButtonHint(_ s: VoiceButtonState, mode: VoiceButtonMode, canMute: Bool) -> String {
    switch s {
    case .ready: return "Connects the voice session"
    case .connecting: return ""
    case .error: return "Tries again"
    case .listening:
        if mode == .pushToTalk && canMute { return "Release to mute" }
        return canMute ? "Mutes the microphone" : "Ends the voice session"
    case .muted: return mode == .pushToTalk ? "Hold to talk" : "Unmutes the microphone"
    }
}

/// Runs the state machine against a source: presses in, `connect` / `disconnect` /
/// `setMuted` out, the source's drops and mutes folded back in. Main thread only.
public final class VoiceButtonController {
    public let source: SharedVoiceSource
    public private(set) var model = VoiceButtonModel()
    public var mode: VoiceButtonMode
    private var changeCbs: [Int: (VoiceButtonModel) -> Void] = [:]
    private var nextId = 0
    private var offs: [() -> Void] = []
    private var attempt = 0

    public init(source: VoiceSource, mode: VoiceButtonMode = .toggle) {
        self.source = SharedVoiceSource.of(source)
        self.mode = mode
        if self.source.reportsConnection {
            offs.append(self.source.listenConnection { [weak self] up in if !up { self?.dispatch(.dropped) } })
        } else {
            offs.append(self.source.listenState { [weak self] s in if s == .idle { self?.dispatch(.dropped) } })
        }
        offs.append(self.source.listenMute { [weak self] m in self?.dispatch(.muteChanged(m)) })
    }

    deinit { for off in offs { off() } }

    public var state: VoiceButtonState { model.state }
    public var reason: String? { model.reason }
    public var canMute: Bool { source.supportsMute }

    /// Called on every model change; returns its cancel.
    @discardableResult public func onChange(_ cb: @escaping (VoiceButtonModel) -> Void) -> () -> Void {
        nextId += 1
        let i = nextId
        changeCbs[i] = cb
        return { [weak self] in self?.changeCbs[i] = nil }
    }

    public func press() { dispatch(.press) }
    public func release() { dispatch(.release) }
    public func end() { dispatch(.end) }

    /// A screen reader's activation in push-to-talk: it can't hold, so it toggles instead
    /// (and connecting starts live).
    public func assistiveActivate() {
        if mode == .toggle || state == .ready || state == .error { return press() }
        let m = mode
        mode = .toggle
        press()
        mode = m
    }

    func dispatch(_ e: VoiceButtonEvent) {
        let (next, effects) = voiceButtonStep(model, e, mode: mode, canMute: source.supportsMute)
        let changed = next != model
        model = next
        if changed { for cb in changeCbs.values { cb(next) } }
        for fx in effects { run(fx) }
    }

    private func run(_ fx: VoiceButtonEffect) {
        switch fx {
        case .connect:
            attempt += 1
            let a = attempt
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.source.connect()
                    if a == self.attempt { self.dispatch(.connectOk) }
                } catch {
                    if a == self.attempt { self.dispatch(.connectFail(Self.message(error))) }
                }
            }
        case .disconnect:
            attempt += 1  // a connect still in flight no longer counts
            source.disconnect()
        case .mute: source.setMuted(true)
        case .unmute: source.setMuted(false)
        }
    }

    private static func message(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }
}
