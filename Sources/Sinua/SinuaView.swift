import CoreEngine
import QuartzCore
import SinuaVoiceTypes
import SwiftUI
import UIKit

/// Light/dark handling. `auto` follows the environment's `colorScheme`;
/// frames with `colorMode: fixed` look the same either way (the paint contract).
public enum FxTheme: Sendable {
    case auto, light, dark
}

/// Reduced motion: a static frame at t = 0.6 (spec/orbs-spec.json `paint`).
/// `auto` follows `accessibilityReduceMotion`.
public enum FxReducedMotion: Sendable {
    case auto, always, never
}

/// A drop-in view for any sinua visual: give it an FX Spec (or a
/// pattern) and, optionally, a `VoiceSource` -- it runs the clock
/// (`t = elapsed * presetSpeed * speed`, pinned at each speed change so the pose
/// doesn't jump), themes, pauses off-screen and in
/// the background, honours reduced motion, and reacts to the voice.
///
/// ```swift
/// SinuaView(spec: specJSON, state: "listening", voice: micSource)
/// SinuaView(pattern: "speaking")
/// ```
///
/// A `VoiceSource` holds one metrics/state callback, so the view binds it
/// (read `voiceOverrides` if you need a meter). If your app already listens
/// to the source, pass a `VoiceOverrides` you feed yourself instead. The
/// view never connects or disconnects the source. See docs/fx-view.md.
public struct SinuaView: View {
    private let config: FxConfig
    @StateObject private var model = FxModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    /// The view's short side, for the small-view frame cap (0 until laid out).
    @State private var shortSide: CGFloat = 0
    @ObservedObject private var power = LowPowerMonitor.shared
    @ObservedObject private var app = AppActivityMonitor.shared

    /// An FX Spec (JSON text). `state` picks the spec's lifecycle state; with a voice it
    /// defaults to the voice's `AgentState` ("listening", "speaking", ...), so a spec's
    /// `states` follow the conversation. State changes animate: the same pattern interpolates
    /// its parameters, a pattern change morphs (the orb lattice trio) or cross-fades, over the
    /// spec's `transitions` (default 0.6 s). `crossFade` overrides every change's duration
    /// (0 = a cut).
    ///
    /// Accessibility (docs/fx-view.md): the name follows the state ("Coach, listening");
    /// `labels` words it per state (over the spec's `accessibility.states`); changes are
    /// spoken to VoiceOver, politely and rate-limited, unless `announce` is false; `haptics`
    /// taps lightly when the agent starts listening. `rules`: a spec's 1.9 `rules` derive the
    /// state from `inputs` (off while a voice is bound, or with `rules: false`).
    public init(
        spec: String,
        voice: VoiceSource? = nil,
        voiceOverrides: VoiceOverrides? = nil,
        state: String? = nil,
        inputs: [String: Double] = [:],
        voiceLevelInput: String? = nil,
        crossFade: Double? = nil,
        theme: FxTheme = .auto,
        paused: Bool = false,
        reducedMotion: FxReducedMotion = .auto,
        accessibilityLabel: String? = nil,
        maxFps: Double? = nil,
        lowPower: FxLowPower = .auto,
        onFrame: ((FxFrameStats) -> Void)? = nil,
        labels: [String: String] = [:],
        announce: Bool? = nil,
        haptics: Bool = false,
        rules: Bool = true,
        effect: SinuaEffectTrigger? = nil
    ) {
        config = FxConfig(
            input: .spec(spec), voice: voice, voiceOverrides: voiceOverrides, specState: state, inputs: inputs,
            voiceLevelInput: voiceLevelInput, crossFade: crossFade, theme: theme, paused: paused,
            reducedMotion: reducedMotion,
            label: accessibilityLabel, maxFps: maxFps, lowPower: lowPower, onFrame: onFrame,
            labels: labels, announce: announce, haptics: haptics, rules: rules, effect: effect
        )
    }

    /// A pattern (e.g. "speaking", "tracking") with optional engine overrides and a speed multiplier.
    /// `state` is the agent's lifecycle state ("listening", "speaking", ...): the built-in
    /// voice-state behaviour then moves this pattern, under your own `overrides`. With a
    /// `voice` attached it defaults to that source's state.
    public init(
        pattern: String,
        size: UInt32 = 64,
        overrides: [String: Double] = [:],
        speed: Double = 1,
        state: String? = nil,
        inputs: [String: Double] = [:],
        voice: VoiceSource? = nil,
        voiceOverrides: VoiceOverrides? = nil,
        theme: FxTheme = .auto,
        paused: Bool = false,
        reducedMotion: FxReducedMotion = .auto,
        accessibilityLabel: String? = nil,
        maxFps: Double? = nil,
        lowPower: FxLowPower = .auto,
        onFrame: ((FxFrameStats) -> Void)? = nil,
        labels: [String: String] = [:],
        announce: Bool? = nil,
        haptics: Bool = false,
        effect: SinuaEffectTrigger? = nil
    ) {
        config = FxConfig(
            input: .state(pattern, size, overrides, speed), voice: voice, voiceOverrides: voiceOverrides,
            specState: state, inputs: inputs,
            voiceLevelInput: nil, crossFade: nil, theme: theme, paused: paused, reducedMotion: reducedMotion,
            label: accessibilityLabel,
            maxFps: maxFps, lowPower: lowPower, onFrame: onFrame,
            labels: labels, announce: announce, haptics: haptics, effect: effect
        )
    }

    /// Deprecated label: `specState` is now `state` (FX Spec 1.7 naming).
    @available(
        *, deprecated,
        renamed:
            "init(spec:voice:voiceOverrides:state:inputs:voiceLevelInput:crossFade:theme:paused:reducedMotion:accessibilityLabel:maxFps:lowPower:onFrame:)"
    )
    public init(
        spec: String,
        voice: VoiceSource? = nil,
        voiceOverrides: VoiceOverrides? = nil,
        specState: String?,
        inputs: [String: Double] = [:],
        voiceLevelInput: String? = nil,
        crossFade: Double? = nil,
        theme: FxTheme = .auto,
        paused: Bool = false,
        reducedMotion: FxReducedMotion = .auto,
        accessibilityLabel: String? = nil,
        maxFps: Double? = nil,
        lowPower: FxLowPower = .auto,
        onFrame: ((FxFrameStats) -> Void)? = nil
    ) {
        self.init(
            spec: spec, voice: voice, voiceOverrides: voiceOverrides, state: specState, inputs: inputs,
            voiceLevelInput: voiceLevelInput, crossFade: crossFade, theme: theme, paused: paused,
            reducedMotion: reducedMotion,
            accessibilityLabel: accessibilityLabel, maxFps: maxFps, lowPower: lowPower, onFrame: onFrame)
    }

    /// Deprecated label: the plain input's `state` is now `pattern` (FX Spec 1.7 naming).
    @available(
        *, deprecated,
        renamed:
            "init(pattern:size:overrides:speed:voice:voiceOverrides:theme:paused:reducedMotion:accessibilityLabel:maxFps:lowPower:onFrame:)"
    )
    public init(
        state: String,
        size: UInt32 = 64,
        overrides: [String: Double] = [:],
        speed: Double = 1,
        voice: VoiceSource? = nil,
        voiceOverrides: VoiceOverrides? = nil,
        theme: FxTheme = .auto,
        paused: Bool = false,
        reducedMotion: FxReducedMotion = .auto,
        accessibilityLabel: String? = nil,
        maxFps: Double? = nil,
        lowPower: FxLowPower = .auto,
        onFrame: ((FxFrameStats) -> Void)? = nil
    ) {
        self.init(
            pattern: state, size: size, overrides: overrides, speed: speed, state: nil, voice: voice,
            voiceOverrides: voiceOverrides,
            theme: theme, paused: paused, reducedMotion: reducedMotion, accessibilityLabel: accessibilityLabel,
            maxFps: maxFps, lowPower: lowPower, onFrame: onFrame)
    }

    private var reduced: Bool {
        switch config.reducedMotion {
        case .always: return true
        case .never: return false
        case .auto: return systemReduceMotion
        }
    }

    private var dark: Bool {
        switch config.theme {
        case .dark: return true
        case .light: return false
        case .auto: return colorScheme == .dark
        }
    }

    private var lowPowerOn: Bool {
        switch config.lowPower {
        case .on: return true
        case .off: return false
        case .auto: return power.isLowPowerModeEnabled
        }
    }

    private var running: Bool {
        FxActivity.running(
            onScreen: onScreen, paused: config.paused, scenePhase: scenePhase,
            appUsesScenes: app.usesScenes, appActive: app.isActive)
    }

    public var body: some View {
        // Reduced motion: no animation, except a throttled redraw while a
        // voice is attached (the voice cue is information, not decoration).
        let animate = running && (!reduced || model.hasVoice || model.effectRunning)
        let perf = model.performance(
            config, lowPower: lowPowerOn, small: shortSide > 0 && shortSide < fxSmallViewPoints)
        // Pacing: the timeline schedules at the cap (no per-vsync wakeups).
        let cap = reduced ? min(30, perf.maxFps ?? 30) : perf.maxFps
        TimelineView(.animation(minimumInterval: cap.map { 1 / $0 }, paused: !animate)) { timeline in
            Canvas { context, size in
                model.draw(
                    config, at: timeline.date, running: running, reduced: reduced, dark: dark, perf: perf,
                    into: &context, size: size)
            }
        }
        // The box size, read without branching the body (an `if` would restart the timeline).
        .background(GeometryReader { g in Color.clear.preference(key: FxBoxSizeKey.self, value: g.size) })
        .onPreferenceChange(FxBoxSizeKey.self) { shortSide = min($0.width, $0.height) }
        .onAppear {
            model.configureIfNeeded(config)
            onScreen = true
        }
        .onDisappear { onScreen = false }
        .modifier(FxAccessibilityModifier(label: model.a11yLabel))
    }
}

/// Below this short side (points) a view defaults to 30 fps: a list of avatars,
/// a badge (roadmap 10). The app's `maxFps` or the spec's `performance.maxFps` wins.
let fxSmallViewPoints: CGFloat = 48
let fxSmallViewMaxFps: Double = 30

private struct FxBoxSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct FxAccessibilityModifier: ViewModifier {
    let label: String
    // One structure for every label: an `if` here would give the content a new identity
    // whenever the name went empty <-> named, restarting the TimelineView inside it.
    func body(content: Content) -> some View {
        content
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(label.isEmpty ? [] : .isImage)
            .accessibilityHidden(label.isEmpty)
    }
}

enum FxInput {
    case spec(String)
    case state(String, UInt32, [String: Double], Double)
}

struct FxConfig {
    let input: FxInput
    let voice: VoiceSource?
    let voiceOverrides: VoiceOverrides?
    let specState: String?
    let inputs: [String: Double]
    let voiceLevelInput: String?
    let crossFade: Double?
    let theme: FxTheme
    let paused: Bool
    let reducedMotion: FxReducedMotion
    let label: String?
    let maxFps: Double?
    let lowPower: FxLowPower
    let onFrame: ((FxFrameStats) -> Void)?
    var labels: [String: String] = [:]
    var announce: Bool?
    var haptics = false
    var rules = true
    var effect: SinuaEffectTrigger?

    /// What forces a re-resolve / rebind (the rest is read every frame).
    var key: String {
        let v = voice.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        let vo = voiceOverrides.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        switch input {
        case .spec(let json):
            return
                "spec|\(json.hashValue)|\(v)|\(vo)|\(crossFade.map { "\($0)" } ?? "-")|\(specState ?? "")|\(inputs.sorted { $0.key < $1.key })|\(voiceLevelInput ?? "")"
        case .state(let s, let size, let o, let speed):
            return "state|\(s)|\(size)|\(o.sorted { $0.key < $1.key })|\(speed)|\(v)|\(vo)"
        }
    }
}

/// The per-view state: clock, resolved input, voice binding, spec cross-fade.

/// The view clock. `elapsed * speed` alone jumps the pose whenever the speed changes
/// (a lifecycle state with its own speed, or an app changing `speed`), because all the
/// time already elapsed is rescaled at once. So the phase is pinned at each speed change
/// and runs from there. With a constant speed the result is exactly
/// `elapsed * presetSpeed * speed`, bit for bit; `speed` 0 holds the phase.
struct PhaseClock {
    private(set) var elapsed = 0.0
    private var phaseBase = 0.0
    private var elapsedBase = 0.0
    private var lastSpeed: Double?
    /// `elapsed` at the previous `phase`: a speed change counts from there.
    private var lastRead = 0.0

    mutating func advance(_ dt: Double) { elapsed += dt }

    /// The engine time to draw at, for the preset's tuned speed and the app's multiplier.
    mutating func phase(preset: Double, speed: Double) -> Double {
        let product = preset * speed
        if lastSpeed != product {
            // Pin the phase as of the previous read, then run from there at the new speed:
            // the time since that read belongs to the new speed, so `speed` 0 freezes exactly.
            if let previous = lastSpeed {
                phaseBase += (lastRead - elapsedBase) * previous
                elapsedBase = lastRead
            }
            lastSpeed = product
        }
        lastRead = elapsed
        // The engine's own factor order, so a constant speed matches `elapsed * preset * speed`.
        return phaseBase + (elapsed - elapsedBase) * preset * speed
    }
}

@MainActor
final class FxModel: ObservableObject {
    static let maxDt = 0.1
    static let reducedMotionT = 0.6

    @Published private(set) var hasVoice = false
    @Published private(set) var defaultLabel = ""
    /// The accessible name now: it follows the state ("Coach, listening"; docs/fx-view.md).
    @Published private(set) var a11yLabel = ""
    /// The spec's 1.9 `accessibility` block (empty without a spec).
    private var a11yInfo = FxAccessibility(name: nil, states: [:], announce: nil)
    /// The state the name last followed (`.none` = not yet).
    private var a11yState: String??
    private var announcer = AnnouncerState(started: false, current: nil, since: 0, last: nil, lastAt: 0)
    private var announceGen = 0
    private var offVoiceState: (() -> Void)?
    /// FX Spec 1.9 `rules`: the state they picked last (hysteresis), and the inputs it was for.
    private var derived: String?
    private var rulesKey: String?
    private var reducedNow = false

    /// Test hooks. VoiceOver announcements are queued, not interrupting, and only while it runs.
    static var postAnnouncement: (String) -> Void = { text in
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }
    static var playHaptic: () -> Void = { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var config: FxConfig?
    private var configKey: String?
    private var voice: VoiceOverrides?
    private var boundSource: ObjectIdentifier?
    /// A raw source is bound through its `SharedVoiceSource`: this view keeps its own tracker
    /// (its family's easing) and other views / a voice button keep theirs.
    private var tracked: SharedVoiceSource.Tracked?
    private var clock = PhaseClock()
    /// The plain path's state transition (the spec path's lives in `FxStatePlayer`).
    private var transition = StateTransition()
    private var lastLifecycle: String??
    /// The built-in voice-state behaviour for plain input (`pattern` + `state`, no spec):
    /// `voiceStateProfile` gives the overrides, a speed multiplier and which app input drives
    /// `audioLevel`. Cached per pattern+state; nil for a state outside the five voice names,
    /// which leaves an app's own state names alone.
    private var profiles: [String: VoiceStateProfile?] = [:]
    private var lastDate: Date?
    /// The pattern fills the box (`patternLayout` == "box"): see `draw`.
    private var boxLayout = false
    private var resolved:
        (state: String, size: UInt32, speed: Double, presetSpeed: Double, overrides: [String: Double])?
    private var spec: String?
    private var player = FxStatePlayer()

    /// The engine time to draw at, continuous across speed changes (see `phaseBase`).
    /// The voice-state profile for this pattern and state, or nil.
    private func profile(pattern: String, state: String?) -> VoiceStateProfile? {
        guard let state, !state.isEmpty else { return nil }
        let key = "\(pattern)\u{0}\(state)"
        if let cached = profiles[key] { return cached }
        let value = voiceStateProfile(pattern: pattern, state: state)
        profiles[key] = value
        return value
    }

    /// The plain path's design for a lifecycle state, as a transition side: the voice-state
    /// profile under the app's overrides, at the effective speed. Live keys are not part of it.
    private func plainSide(
        _ r: (state: String, size: UInt32, speed: Double, presetSpeed: Double, overrides: [String: Double]),
        state: String?
    ) -> TransitionSide {
        let profile = profile(pattern: r.state, state: state)
        return TransitionSide(
            state: r.state, speed: r.presetSpeed * r.speed * (profile?.speed ?? 1),
            overrides: (profile?.overrides ?? [:]).merging(r.overrides) { $1 })
    }

    /// Re-resolves only when something that needs it changed (FxConfig.key).
    /// Called from draw too, so the view works even where onAppear never fires (ImageRenderer).
    func configureIfNeeded(_ c: FxConfig) {
        let key = c.key
        if key == configKey {
            let wordsChanged = config.map { $0.labels != c.labels || $0.announce != c.announce } ?? false
            config = c
            if wordsChanged { a11yState = .none }
            refreshA11y()
            play(c.effect, config: c)
            return
        }
        configKey = key
        configure(c)
        play(c.effect, config: c)
    }

    private func configure(_ c: FxConfig) {
        config = c
        profiles.removeAll()
        transition.cancel()
        lastLifecycle = nil
        switch c.input {
        case .spec(let json):
            spec = json
            let r = resolveFxSpec(json: json)
            if r.ok {
                resolved = (
                    r.state, r.size, r.speed, resolvedOpts(state: r.state, size: r.size)?.speed ?? 1, r.overrides
                )
                defaultLabel = Self.specName(json) ?? r.state
            } else {
                resolved = nil
                defaultLabel = ""
                print("SinuaView: spec has errors:", r.diagnostics.map { "\($0.path): \($0.message)" })
            }
            player.crossFade = c.crossFade
        case .state(let state, let size, let overrides, let speed):
            spec = nil
            if let preset = resolvedOpts(state: state, size: size) {
                resolved = (state, size, speed, preset.speed, overrides)
                defaultLabel = state
            } else {
                resolved = nil
                print("SinuaView: unknown state \"\(state)\"")
            }
        }
        boxLayout = resolved.map { patternLayout(pattern: $0.state) == "box" } ?? false
        if let vo = c.voiceOverrides {
            voice = vo
            boundSource = nil
            tracked = nil
        } else if let src = c.voice {
            if boundSource != ObjectIdentifier(src) {
                boundSource = ObjectIdentifier(src)
                tracked?.release()
                let t = SharedVoiceSource.of(src).track(
                    options: Self.voiceOptions(family: Self.specObject(spec), overrides: resolved?.overrides ?? [:]))
                tracked = t
                voice = t.overrides
            }
        } else {
            voice = nil
            boundSource = nil
            tracked = nil
        }
        hasVoice = voice != nil
        a11yInfo = spec.map { fxSpecAccessibility(json: $0) } ?? FxAccessibility(name: nil, states: [:], announce: nil)
        rulesKey = nil
        a11yState = .none
        // The name and announcements follow the conversation even while the view is paused.
        offVoiceState?()
        offVoiceState = tracked?.source.listenState { [weak self] _ in
            DispatchQueue.main.async { self?.refreshA11y() }
        }
        refreshA11y()
    }

    deinit { offVoiceState?() }

    /// The state the view shows: with a voice bound, the app's `state` ?? the voice's; without,
    /// the state the spec's `rules` derive from `inputs` ?? the app's `state`.
    func lifecycle(_ c: FxConfig) -> String? {
        if let voice { return c.specState ?? voice.state.rawValue }
        applyRules(c)
        return derived ?? c.specState
    }

    private func applyRules(_ c: FxConfig) {
        guard let spec, resolved != nil, c.rules, voice == nil else {
            derived = nil
            rulesKey = nil
            return
        }
        let key = "\(c.inputs.sorted { $0.key < $1.key })"
        if key == rulesKey { return }
        rulesKey = key
        derived = fxSpecDeriveState(json: spec, inputs: c.inputs, previous: derived)
    }

    // One-shot effect (docs/fx-view.md, *One-shot effects*).
    @Published private(set) var effectRunning = false
    private var effectPlayed: UUID?
    private var effect: (code: UInt32, duration: Double, start: Double)?

    /// Plays `trigger` if it's a new one (each `SinuaEffectTrigger` value plays once).
    func play(_ trigger: SinuaEffectTrigger?, config c: FxConfig) {
        guard let trigger, trigger.id != effectPlayed else { return }
        effectPlayed = trigger.id
        guard let info = effectInfo(name: trigger.kind.rawValue) else { return }
        effect = (info.code, info.duration, Self.now())
        // Published after this view update, so the timeline wakes for the effect.
        DispatchQueue.main.async { [weak self] in self?.effectRunning = true }
        // An event: spoken now, outside the state rate limit.
        let base = c.label ?? a11yInfo.name ?? defaultLabel
        if !base.isEmpty, c.announce ?? a11yInfo.announce ?? true {
            Self.postAnnouncement(c.labels["effect:\(trigger.kind.rawValue)"] ?? info.words)
        }
    }

    /// The running effect's runtime keys (empty once it has ended).
    func effectKeys(reduced: Bool) -> [String: Double] {
        guard let e = effect else { return [:] }
        let age = Self.now() - e.start
        if age >= e.duration {
            effect = nil
            DispatchQueue.main.async { [weak self] in self?.effectRunning = false }
            return [:]
        }
        return ["effectCode": Double(e.code), "effectAge": max(0, age), "effectReduced": reduced ? 1 : 0]
    }

    /// The state may have changed: rename the view, and let the announcer decide.
    func refreshA11y() {
        guard let c = config else { return }
        let st = lifecycle(c)
        if case .some(let seen) = a11yState, seen == st { return }
        let first = a11yState == nil
        a11yState = .some(st)
        let base = c.label ?? a11yInfo.name ?? defaultLabel
        let label =
            base.isEmpty
            ? "" : a11yAccessibleName(name: base, state: st, specWords: a11yInfo.states, appWords: c.labels)
        if first {
            // The first name goes in with the configuration (as `defaultLabel` does), so the
            // first body already carries it.
            a11yLabel = label
        } else {
            // Later changes are published after this view update (SwiftUI forbids publishing
            // during one).
            DispatchQueue.main.async { [weak self] in
                if let self, self.a11yLabel != label { self.a11yLabel = label }
            }
        }
        let speak = !base.isEmpty && (c.announce ?? a11yInfo.announce ?? true)
        stepAnnouncer(
            speak ? a11yStateWords(name: base, state: st, specWords: a11yInfo.states, appWords: c.labels) : nil)
        // "Your turn": a light tap when the agent starts listening (opt-in, never under reduced motion).
        if !first, st == AgentState.listening.rawValue, c.haptics, !reducedNow { Self.playHaptic() }
    }

    private func stepAnnouncer(_ words: String?) {
        announceGen += 1
        let gen = announceGen
        let now = Self.now()
        let out = a11yAnnounceStep(prev: announcer, words: words, now: now)
        announcer = out.state
        if let w = out.announce { Self.postAnnouncement(w) }
        if let at = out.recheckAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - now)) { [weak self] in
                guard let self, self.announceGen == gen else { return }
                self.stepAnnouncer(self.announcer.current)
            }
        }
    }

    /// The effective cap + low-power overrides (see `fxPerformance`). FX Spec 1.2's
    /// resolver fields plug in here once UniFFI exposes them (`specMaxFps`).
    /// A small view (`small`) defaults to 30 fps unless the app's `maxFps` (0 = display
    /// rate) or the spec's `performance.maxFps` says otherwise (roadmap 10).
    func performance(_ c: FxConfig, lowPower: Bool, small: Bool = false) -> FxPerformance {
        configureIfNeeded(c)
        player.lowPower = lowPower
        let smallCap = small && c.maxFps == nil ? fxSmallViewMaxFps : nil
        guard let spec else { return fxPerformance(lowPower: lowPower, optionMaxFps: c.maxFps ?? smallCap) }
        // FX Spec 1.2: the resolver reports the cap for this power state and sheds
        // the spec's `lowPower.disable` itself (FxStatePlayer passes lowPower).
        let r = resolveFxSpecWith(json: spec, state: nil, inputs: [:], lowPower: lowPower)
        return fxPerformance(
            lowPower: lowPower, optionMaxFps: c.maxFps ?? (r.maxFps == nil ? smallCap : nil), specMaxFps: r.maxFps,
            specHandlesLowPower: Self.specHandlesLowPower(spec))
    }

    static func specHandlesLowPower(_ json: String) -> Bool {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let p = d["performance"] as? [String: Any]
        else { return false }
        return p["lowPower"] != nil
    }

    func draw(
        _ c: FxConfig, at date: Date, running: Bool, reduced: Bool, dark: Bool, perf: FxPerformance,
        into context: inout GraphicsContext, size: CGSize
    ) {
        reducedNow = reduced
        configureIfNeeded(c)
        guard let config, let resolved else { return }
        let t0 = config.onFrame == nil ? 0 : CACurrentMediaTime()
        let rawDt = lastDate.map { max(0, date.timeIntervalSince($0)) } ?? 0
        lastDate = date
        // Stall clamp, widened so a low cap isn't mistaken for a stall.
        if running && !reduced { clock.advance(min(rawDt, max(Self.maxDt, perf.maxFps.map { 1.5 / $0 } ?? 0))) }
        let voiceMap = (voice?.overrides(dt: rawDt) ?? [:])
        // Low-power overrides sit between the spec's and the voice's.
        var extra = perf.overrides.merging(voiceMap) { $1 }
        // A one-shot effect the view is playing (docs/fx-view.md): its runtime keys.
        extra.merge(effectKeys(reduced: reduced)) { $1 }
        // A box-layout pattern (edge `framing`, signal `playing`) fills the box: it
        // gets the box ratio as `aspect` and lays out in `size * aspect` by `size`.
        if boxLayout, size.height > 0 { extra["aspect"] = min(8, max(0.125, size.width / size.height)) }

        var frame: OrbFrame?
        var previous: OrbFrame?
        var blend = 1.0
        if let spec {
            // FX Spec: v1.1 state (default = the voice's AgentState) + inputs, runtime voice keys spread last.
            var inputs = config.inputs
            if let name = config.voiceLevelInput, let voice { inputs[name] = voice.metrics.level }
            player.setState(self.lifecycle(config), spec: spec)
            if reduced { player.skipTransition() }
            // The player multiplies by its effective speed (mixed mid-transition), so it takes an
            // *elapsed*: `max(1e-9, …)` only guards the division; the phase freezes at speed 0.
            let stateSpeed = player.speed(spec: spec, inputs: inputs)
            let at =
                reduced
                ? Self.reducedMotionT / max(1e-9, stateSpeed)
                : clock.phase(preset: stateSpeed, speed: 1) / max(1e-9, stateSpeed)
            let out = player.frame(spec: spec, elapsed: at, dt: min(rawDt, Self.maxDt), inputs: inputs, extra: extra)
            frame = out.frame
            previous = out.previous
            blend = out.blend
        } else {
            // With a lifecycle state (given, or the bound voice's), the built-in voice-state
            // profile goes *under* the app's own overrides; the voice's live keys stay last.
            let lifecycle = self.lifecycle(config)
            if lastLifecycle.map({ $0 != lifecycle }) ?? false {
                // A state change animates (0.6 s easeInOut, or `crossFade` seconds); reduced motion cuts.
                transition.start(duration: reduced ? 0 : (config.crossFade ?? 0.6), curve: "easeInOut")
            }
            lastLifecycle = .some(lifecycle)
            transition.advance(min(rawDt, Self.maxDt))
            if reduced { transition.cancel() }
            let profile = profile(pattern: resolved.state, state: lifecycle)
            let side = plainSide(resolved, state: lifecycle)
            let t: Double
            if reduced {
                t = Self.reducedMotionT
            } else if transition.active {
                t = clock.phase(preset: 1, speed: transition.speed(side, size: resolved.size))
            } else {
                t = clock.phase(preset: resolved.presetSpeed, speed: resolved.speed * (profile?.speed ?? 1))
            }
            var live = extra
            // `audioInput` names which app input drives `audioLevel` (never an engine key).
            if let name = profile?.audioInput, let level = config.inputs[name] { live["audioLevel"] = level }
            if transition.active {
                let out = transition.frames(side, size: resolved.size, t: t, extra: live)
                frame = out.frame
                previous = out.previous
                blend = out.blend
            } else {
                transition.settle(side)
                frame = frameWithOverrides(
                    state: resolved.state, size: resolved.size, t: t, overrides: side.overrides.merging(live) { $1 })
            }
        }
        guard let frame else { return }
        let t1 = config.onFrame == nil ? 0 : CACurrentMediaTime()

        // Square engine space, centered in whatever box the view has -- or, for a
        // box-layout pattern, the whole box at the height's scale (FxPaint scales by
        // the square it's given; the frame itself runs `size * aspect` wide).
        let side = boxLayout ? size.height : min(size.width, size.height)
        if !boxLayout { context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2) }
        let box = CGSize(width: side, height: side)
        let engineSize = Double(resolved.size)
        if let previous {
            var a = context
            a.opacity = 1 - blend
            FxPaint.draw(previous, into: &a, size: box, engineSize: engineSize, dark: dark)
            var b = context
            b.opacity = blend
            FxPaint.draw(frame, into: &b, size: box, engineSize: engineSize, dark: dark)
        } else {
            FxPaint.draw(frame, into: &context, size: box, engineSize: engineSize, dark: dark)
        }
        if let onFrame = config.onFrame {
            // Canvas records the drawing; paintMs is the record time, not GPU raster.
            let t2 = CACurrentMediaTime()
            onFrame(FxFrameStats(dtMs: rawDt * 1000, computeMs: (t1 - t0) * 1000, paintMs: (t2 - t1) * 1000))
        }
    }

    /// The Studio's per-family `VoiceOverrides` settings (orb: raw bands; signal: scrolling history).
    static func voiceOptions(family: String?, overrides: [String: Double]) -> VoiceOverridesOptions {
        var o = VoiceOverridesOptions()
        if family == "orb" { o.bandEaseRate = .infinity }
        if family == "signal" {
            o.audioStrength = 0
            o.historyCount = Int((overrides["historyCount"] ?? 40).rounded())
        }
        return o
    }

    static func specObject(_ json: String?) -> String? {
        guard let json, let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        return d["object"] as? String
    }

    static func specName(_ json: String) -> String? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return d["name"] as? String
    }
}

/// Native counterpart of @sinua/core's `FxSpecPlayer`: the spec's lifecycle state and its
/// transitions (`StateTransition`; the spec's 1.9 `transitions`, or `crossFade` seconds when
/// set), over UniFFI's resolution plus extra runtime keys.
struct FxStatePlayer {
    /// Overrides every state change's duration (0 = a cut); nil = the spec's `transitions`.
    var crossFade: Double?
    /// FX Spec 1.2 low power, passed to the resolver (sheds `performance.lowPower.disable`).
    var lowPower = false
    private var current: String?
    private var started = false
    private var transition = StateTransition()

    mutating func setState(_ key: String?, spec: String) {
        guard !started || key != current else { return }
        if started {
            let t = fxSpecTransition(json: spec, from: current, to: key)
            transition.start(duration: crossFade ?? t.duration, curve: t.curve)
        }
        started = true
        current = key
    }

    /// End a running transition now (reduced motion).
    mutating func skipTransition() { transition.cancel() }

    /// The current state as a transition side (effective speed), or nil if the spec has errors.
    private func side(spec: String, inputs: [String: Double]) -> (TransitionSide, UInt32)? {
        let r = resolveFxSpecWith(json: spec, state: current, inputs: inputs, lowPower: lowPower)
        guard r.ok else { return nil }
        let preset = resolvedOpts(state: r.state, size: r.size)?.speed ?? 1
        return (TransitionSide(state: r.state, speed: preset * r.speed, overrides: r.overrides), r.size)
    }

    /// The effective speed multiplier the next frame renders at (mixed mid-transition).
    func speed(spec: String, inputs: [String: Double]) -> Double {
        guard let (s, size) = side(spec: spec, inputs: inputs) else { return 1 }
        return transition.speed(s, size: size)
    }

    mutating func frame(spec: String, elapsed: Double, dt: Double, inputs: [String: Double], extra: [String: Double])
        -> (frame: OrbFrame?, previous: OrbFrame?, blend: Double)
    {
        transition.advance(dt)
        guard let (s, size) = side(spec: spec, inputs: inputs) else {
            transition.cancel()
            return (nil, nil, 1)
        }
        let t = elapsed * transition.speed(s, size: size)
        return transition.frames(s, size: size, t: t, extra: extra)
    }

    static func render(
        spec: String, state: String?, elapsed: Double, inputs: [String: Double], extra: [String: Double],
        lowPower: Bool = false
    ) -> OrbFrame? {
        let r = resolveFxSpecWith(json: spec, state: state, inputs: inputs, lowPower: lowPower)
        guard r.ok else { return nil }
        let t = elapsed * (resolvedOpts(state: r.state, size: r.size)?.speed ?? 1) * r.speed
        return frameWithOverrides(state: r.state, size: r.size, t: t, overrides: r.overrides.merging(extra) { $1 })
    }
}
