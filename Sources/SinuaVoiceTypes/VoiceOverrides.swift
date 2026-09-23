import Foundation

/// Port of packages/core/src/voice.ts's `VoiceOverrides` -- turns a live
/// voice reading into the exact `[String: Double]` `frameWithOverrides`
/// takes, with the Web Studio's tuned easing, the barge-in age and the
/// scrolling-style history. Clock-free (dt-driven), same defaults and
/// same key encodings as Web; see docs/audio-pipeline.md.
public struct InterruptOptions: Sendable {
    /// Seconds `interruptAge` keeps being emitted after the moment. Default 1.
    public var window: Double = 1
    public var duration: Double?
    public var strength: Double?
    public var tint: Double?
    public var hue: Double?
    public init(
        window: Double = 1, duration: Double? = nil, strength: Double? = nil, tint: Double? = nil, hue: Double? = nil
    ) {
        self.window = window
        self.duration = duration
        self.strength = strength
        self.tint = tint
        self.hue = hue
    }
}

public struct VoiceOverridesOptions: Sendable {
    /// `audioStrength` (orb breathing pulse). Default 0.18; 0 disables.
    public var audioStrength: Double = 0.18
    /// `audioLevel` easing per second. Default 7; `.infinity` = raw.
    public var levelEaseRate: Double = 7
    /// `audioBand*` easing per second. Default 24; `.infinity` = raw.
    public var bandEaseRate: Double = 24
    /// Scrolling-style history: `count` samples pushed `hz` times per second (default 12). Off when nil.
    public var historyCount: Int?
    public var historyHz: Double = 12
    /// The barge-in flash; nil disables `interruptAge`.
    public var interrupt: InterruptOptions? = InterruptOptions()
    public var muted = false
    public var mutedTint: Double?
    public var mutedHue: Double?
    public init() {}
}

/// Pure, stateless form: one reading + one state -> overrides (no easing, no history, no interrupt).
public func voiceOverrides(
    _ metrics: VoiceMetrics, state: AgentState, options: VoiceOverridesOptions = VoiceOverridesOptions()
) -> [String: Double] {
    buildOverrides(
        level: metrics.level, bands: metrics.bands, state: state, options: options, history: nil, interruptAge: nil)
}

public final class VoiceOverrides {
    private let options: VoiceOverridesOptions
    private var history: [Double]?
    private var historyAcc = 0.0
    private var historyPeak = 0.0
    private var historyPhase = 0.0
    private var interruptAgeValue: Double?
    private var interruptFresh = false

    public private(set) var metrics = VoiceMetrics.silent
    public private(set) var state: AgentState = .idle
    private var level = 0.0
    private var bands: [Double] = []

    /// The `muted` cue; flip it live.
    public var muted: Bool

    private static let maxDt = 0.1

    public init(options: VoiceOverridesOptions = VoiceOverridesOptions()) {
        self.options = options
        muted = options.muted
        if let n = options.historyCount { history = [Double](repeating: 0, count: max(1, n)) }
    }

    /// Subscribes to `source`'s metrics, state and interrupt callbacks. A source holds one
    /// callback of each kind -- read `metrics`/`state` here instead of subscribing again.
    public static func bind(_ source: VoiceSource, options: VoiceOverridesOptions = VoiceOverridesOptions())
        -> VoiceOverrides
    {
        let v = VoiceOverrides(options: options)
        source.onMetrics { [weak v] m in v?.push(m) }
        source.onInterrupt { [weak v] in v?.interrupt() }
        source.onStateChange { [weak v] s in
            v?.setState(s)
            if s == .idle { v?.reset() }
        }
        return v
    }

    public func push(_ metrics: VoiceMetrics) { self.metrics = metrics }
    public func setState(_ state: AgentState) { self.state = state }

    /// Marks the barge-in moment now (see voice.ts `interrupt()`).
    public func interrupt() {
        guard options.interrupt != nil else { return }
        interruptAgeValue = 0
        interruptFresh = true
    }

    public func setHistoryCount(_ count: Int) {
        let n = max(1, count)
        guard var h = history else {
            history = [Double](repeating: 0, count: n)
            return
        }
        while h.count > n { h.removeFirst() }
        while h.count < n { h.insert(0, at: 0) }
        history = h
    }

    public func reset() {
        metrics = .silent
        level = 0
        bands = []
        if let h = history { history = [Double](repeating: 0, count: h.count) }
        historyAcc = 0
        historyPeak = 0
        historyPhase = 0
        interruptAgeValue = nil
        interruptFresh = false
    }

    /// Call once per rendered frame with the seconds since the previous frame.
    public func overrides(dt dtSeconds: Double) -> [String: Double] {
        let dt = max(0, min(dtSeconds, Self.maxDt))

        var interrupt: Double?
        if let age = interruptAgeValue, let io = options.interrupt {
            var a = age
            if interruptFresh {
                interruptFresh = false
            } else {
                a += dtSeconds.isFinite ? max(0, dtSeconds) : 0
            }
            if a >= io.window {
                interruptAgeValue = nil
            } else {
                interruptAgeValue = a
                interrupt = a
            }
        }

        level += (metrics.level - level) * easeK(options.levelEaseRate, dt)
        let raw = metrics.bands
        if bands.count != raw.count {
            bands = raw
        } else {
            let k = easeK(options.bandEaseRate, dt)
            for i in raw.indices { bands[i] += (raw[i] - bands[i]) * k }
        }

        var hist: (buf: [Double], phase: Double)?
        if var h = history {
            let interval = 1 / options.historyHz
            historyAcc += dt
            historyPeak = max(historyPeak, metrics.level)
            while historyAcc >= interval {
                h.append(historyPeak)
                h.removeFirst()
                historyPeak = 0
                historyAcc -= interval
            }
            history = h
            historyPhase = historyAcc / interval
            hist = (h, historyPhase)
        }

        var opts = options
        opts.muted = muted
        return buildOverrides(
            level: level, bands: bands, state: state, options: opts, history: hist, interruptAge: interrupt)
    }
}

private func easeK(_ rate: Double, _ dt: Double) -> Double {
    dt > 0 ? min(1, rate * dt) : 0
}

private func clamp01(_ v: Double) -> Double {
    v.isNaN ? 0 : max(0, min(1, v))
}

private func buildOverrides(
    level: Double, bands: [Double], state: AgentState, options: VoiceOverridesOptions,
    history: (buf: [Double], phase: Double)?, interruptAge: Double?
) -> [String: Double] {
    var out: [String: Double] = [
        "audioLevel": clamp01(level),
        "audioStrength": options.audioStrength,
        "voiceStateCode": state.voiceStateCode,
    ]
    let n = min(bands.count, maxAudioBands)
    out["audioBandCount"] = Double(n)
    for i in 0..<n { out["audioBand\(i)"] = clamp01(bands[i]) }
    if let h = history {
        out["historyCount"] = Double(h.buf.count)
        for (i, v) in h.buf.enumerated() { out["history\(i)"] = clamp01(v) }
        out["historyPhase"] = h.phase
    }
    if let age = interruptAge, let io = options.interrupt {
        out["interruptAge"] = age
        if let v = io.duration { out["interruptDuration"] = v }
        if let v = io.strength { out["interruptStrength"] = v }
        if let v = io.tint { out["interruptTint"] = v }
        if let v = io.hue { out["interruptHue"] = v }
    }
    if options.muted {
        out["muted"] = 1
        if let v = options.mutedTint { out["mutedTint"] = v }
        if let v = options.mutedHue { out["mutedHue"] = v }
    }
    return out
}
