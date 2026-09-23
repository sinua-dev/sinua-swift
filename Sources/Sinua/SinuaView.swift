import CoreEngine
import QuartzCore
import SinuaVoiceTypes
import SwiftUI

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
    @ObservedObject private var power = LowPowerMonitor.shared
    @ObservedObject private var app = AppActivityMonitor.shared

    /// An FX Spec (JSON text). `state` picks the spec's lifecycle state; with a voice it
    /// defaults to the voice's `AgentState` ("listening", "speaking", ...), so a spec's
    /// `states` follow the conversation. State changes cross-fade over `crossFade` seconds.
    public init(
        spec: String,
        voice: VoiceSource? = nil,
        voiceOverrides: VoiceOverrides? = nil,
        state: String? = nil,
        inputs: [String: Double] = [:],
        voiceLevelInput: String? = nil,
        crossFade: Double = 0.25,
        theme: FxTheme = .auto,
        paused: Bool = false,
        reducedMotion: FxReducedMotion = .auto,
        accessibilityLabel: String? = nil,
        maxFps: Double? = nil,
        lowPower: FxLowPower = .auto,
        onFrame: ((FxFrameStats) -> Void)? = nil
    ) {
        config = FxConfig(
            input: .spec(spec), voice: voice, voiceOverrides: voiceOverrides, specState: state, inputs: inputs,
            voiceLevelInput: voiceLevelInput, crossFade: crossFade, theme: theme, paused: paused,
            reducedMotion: reducedMotion,
            label: accessibilityLabel, maxFps: maxFps, lowPower: lowPower, onFrame: onFrame
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
        onFrame: ((FxFrameStats) -> Void)? = nil
    ) {
        config = FxConfig(
            input: .state(pattern, size, overrides, speed), voice: voice, voiceOverrides: voiceOverrides,
            specState: state, inputs: inputs,
            voiceLevelInput: nil, crossFade: 0, theme: theme, paused: paused, reducedMotion: reducedMotion,
            label: accessibilityLabel,
            maxFps: maxFps, lowPower: lowPower, onFrame: onFrame
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
        crossFade: Double = 0.25,
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
        let animate = running && (!reduced || model.hasVoice)
        let perf = model.performance(config, lowPower: lowPowerOn)
        // Pacing: the timeline schedules at the cap (no per-vsync wakeups).
        let cap = reduced ? min(30, perf.maxFps ?? 30) : perf.maxFps
        TimelineView(.animation(minimumInterval: cap.map { 1 / $0 }, paused: !animate)) { timeline in
            Canvas { context, size in
                model.draw(
                    config, at: timeline.date, running: running, reduced: reduced, dark: dark, perf: perf,
                    into: &context, size: size)
            }
        }
        .onAppear {
            model.configureIfNeeded(config)
            onScreen = true
        }
        .onDisappear { onScreen = false }
        .modifier(FxAccessibility(label: config.label ?? model.defaultLabel))
    }
}

private struct FxAccessibility: ViewModifier {
    let label: String
    func body(content: Content) -> some View {
        if label.isEmpty {
            content.accessibilityHidden(true)
        } else {
            content.accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isImage)
        }
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
    let crossFade: Double
    let theme: FxTheme
    let paused: Bool
    let reducedMotion: FxReducedMotion
    let label: String?
    let maxFps: Double?
    let lowPower: FxLowPower
    let onFrame: ((FxFrameStats) -> Void)?

    /// What forces a re-resolve / rebind (the rest is read every frame).
    var key: String {
        let v = voice.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        let vo = voiceOverrides.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        switch input {
        case .spec(let json):
            return
                "spec|\(json.hashValue)|\(v)|\(vo)|\(crossFade)|\(specState ?? "")|\(inputs.sorted { $0.key < $1.key })|\(voiceLevelInput ?? "")"
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
    private var config: FxConfig?
    private var configKey: String?
    private var voice: VoiceOverrides?
    private var boundSource: ObjectIdentifier?
    private var clock = PhaseClock()
    /// The engine speed per lifecycle state of a spec, cached. `FxStatePlayer` resolves the
    /// spec *with* the state and multiplies by that state's speed, so the view must use the
    /// same number; the file's base speed would make a state with its own speed jump once.
    private var specSpeeds: [String: Double] = [:]
    /// The built-in voice-state behaviour for plain input (`pattern` + `state`, no spec):
    /// `voiceStateProfile` gives the overrides, a speed multiplier and which app input drives
    /// `audioLevel`. Cached per pattern+state; nil for a state outside the five voice names,
    /// which leaves an app's own state names alone.
    private var profiles: [String: VoiceStateProfile?] = [:]
    private var lastDate: Date?
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

    /// The engine speed of one lifecycle state of a spec (the product the player will use).
    private func specSpeed(spec: String, state: String?) -> Double {
        let key = state ?? ""
        if let cached = specSpeeds[key] { return cached }
        let r = resolveFxSpecWith(json: spec, state: state, inputs: [:], lowPower: player.lowPower)
        let speed = r.ok ? (resolvedOpts(state: r.state, size: r.size)?.speed ?? 1) * r.speed : 1
        specSpeeds[key] = speed
        return speed
    }

    /// Re-resolves only when something that needs it changed (FxConfig.key).
    /// Called from draw too, so the view works even where onAppear never fires (ImageRenderer).
    func configureIfNeeded(_ c: FxConfig) {
        let key = c.key
        if key == configKey {
            config = c
            return
        }
        configKey = key
        configure(c)
    }

    private func configure(_ c: FxConfig) {
        config = c
        specSpeeds.removeAll()  // a new input: its states' speeds are new too
        profiles.removeAll()
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
        if let vo = c.voiceOverrides {
            voice = vo
            boundSource = nil
        } else if let src = c.voice {
            if boundSource != ObjectIdentifier(src) {
                boundSource = ObjectIdentifier(src)
                voice = VoiceOverrides.bind(
                    src,
                    options: Self.voiceOptions(family: Self.specObject(spec), overrides: resolved?.overrides ?? [:]))
            }
        } else {
            voice = nil
            boundSource = nil
        }
        hasVoice = voice != nil
    }

    /// The effective cap + low-power overrides (see `fxPerformance`). FX Spec 1.2's
    /// resolver fields plug in here once UniFFI exposes them (`specMaxFps`).
    func performance(_ c: FxConfig, lowPower: Bool) -> FxPerformance {
        if player.lowPower != lowPower { specSpeeds.removeAll() }  // a state's resolved speed can change
        configureIfNeeded(c)
        player.lowPower = lowPower
        guard let spec else { return fxPerformance(lowPower: lowPower, optionMaxFps: c.maxFps) }
        // FX Spec 1.2: the resolver reports the cap for this power state and sheds
        // the spec's `lowPower.disable` itself (FxStatePlayer passes lowPower).
        let r = resolveFxSpecWith(json: spec, state: nil, inputs: [:], lowPower: lowPower)
        return fxPerformance(
            lowPower: lowPower, optionMaxFps: c.maxFps, specMaxFps: r.maxFps,
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
        configureIfNeeded(c)
        guard let config, let resolved else { return }
        let t0 = config.onFrame == nil ? 0 : CACurrentMediaTime()
        let rawDt = lastDate.map { max(0, date.timeIntervalSince($0)) } ?? 0
        lastDate = date
        // Stall clamp, widened so a low cap isn't mistaken for a stall.
        if running && !reduced { clock.advance(min(rawDt, max(Self.maxDt, perf.maxFps.map { 1.5 / $0 } ?? 0))) }
        let voiceMap = (voice?.overrides(dt: rawDt) ?? [:])
        // Low-power overrides sit between the spec's and the voice's.
        let extra = perf.overrides.merging(voiceMap) { $1 }

        var frame: OrbFrame?
        var previous: OrbFrame?
        var blend = 1.0
        if let spec {
            // FX Spec: v1.1 state (default = the voice's AgentState) + inputs, runtime voice keys spread last.
            var inputs = config.inputs
            if let name = config.voiceLevelInput, let voice { inputs[name] = voice.metrics.level }
            player.setState(config.specState ?? voice?.state.rawValue)
            // The player multiplies by the state's speed, so it takes an *elapsed*:
            // `max(1e-9, …)` only guards the division; the phase itself freezes at speed 0.
            // The player multiplies by *this state's* speed, so the view divides by the same one.
            let stateSpeed = specSpeed(spec: spec, state: config.specState ?? voice?.state.rawValue)
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
            let lifecycle = config.specState ?? voice?.state.rawValue
            let profile = profile(pattern: resolved.state, state: lifecycle)
            let t =
                reduced
                ? Self.reducedMotionT
                : clock.phase(preset: resolved.presetSpeed, speed: resolved.speed * (profile?.speed ?? 1))
            var merged = (profile?.overrides ?? [:]).merging(resolved.overrides) { $1 }.merging(extra) { $1 }
            // `audioInput` names which app input drives `audioLevel` (never an engine key).
            if let name = profile?.audioInput, let level = config.inputs[name] { merged["audioLevel"] = level }
            frame = frameWithOverrides(state: resolved.state, size: resolved.size, t: t, overrides: merged)
        }
        guard let frame else { return }
        let t1 = config.onFrame == nil ? 0 : CACurrentMediaTime()

        // Square engine space, centered in whatever box the view has.
        let side = min(size.width, size.height)
        context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
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

/// Native counterpart of @sinua/core's `FxSpecPlayer` (the Studio's state
/// cross-fade: `crossFade` seconds, cubic ease-out), over UniFFI's
/// `frameFromFxSpecWith`-equivalent resolution plus extra runtime keys.
struct FxStatePlayer {
    var crossFade = 0.25
    /// FX Spec 1.2 low power, passed to the resolver (sheds `performance.lowPower.disable`).
    var lowPower = false
    private var current: String?
    private var previous: String?
    private var fadeAge = Double.infinity

    mutating func setState(_ key: String?) {
        guard key != current else { return }
        previous = current
        current = key
        fadeAge = crossFade > 0 ? 0 : .infinity
    }

    mutating func frame(spec: String, elapsed: Double, dt: Double, inputs: [String: Double], extra: [String: Double])
        -> (frame: OrbFrame?, previous: OrbFrame?, blend: Double)
    {
        fadeAge += dt
        let now = Self.render(
            spec: spec, state: current, elapsed: elapsed, inputs: inputs, extra: extra, lowPower: lowPower)
        guard fadeAge < crossFade else { return (now, nil, 1) }
        let prev = Self.render(
            spec: spec, state: previous, elapsed: elapsed, inputs: inputs, extra: extra, lowPower: lowPower)
        let u = fadeAge / crossFade
        return (now, prev, 1 - pow(1 - u, 3))
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
