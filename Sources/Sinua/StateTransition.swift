import CoreEngine

/// State transitions, caller side -- the Swift mirror of `@sinua/core`'s
/// `StateTransition` (packages/core/src/transition.ts; docs/fx-spec.md,
/// *Transitions*). The engine says what to draw at an instant (`transitionMix`);
/// this keeps the clock and what was on screen, so a change mid-transition starts
/// from there.
struct StateTransition {
    private var from: TransitionSide?
    private var shown: TransitionSide?
    private var age = Double.infinity
    private var duration = 0.0
    private var curve = "easeInOut"

    /// A state change happened: animate from what is on screen now. `duration` 0 = a cut.
    mutating func start(duration: Double, curve: String) {
        from = shown
        self.duration = max(0, duration)
        self.curve = curve
        age = from != nil && self.duration > 0 ? 0 : .infinity
    }

    /// Stop any transition now (reduced motion, a new design).
    mutating func cancel() {
        age = .infinity
        from = nil
    }

    /// No transition running: remember `to` as what is on screen.
    mutating func settle(_ to: TransitionSide) {
        if !active { shown = to }
    }

    mutating func advance(_ dt: Double) { age += max(0, dt) }

    var active: Bool { from != nil && age < duration }

    private func mix(_ to: TransitionSide, size: UInt32) -> TransitionMix? {
        guard let from, active else { return nil }
        return transitionMix(from: from, to: to, size: size, progress: age / duration, curve: curve)
    }

    /// The speed multiplier to run the phase at now, for `to`.
    func speed(_ to: TransitionSide, size: UInt32) -> Double { mix(to, size: size)?.speed ?? to.speed }

    /// The frames for `to` at engine time `t`: `previous` dissolved into `frame` at `blend`.
    /// `extra` is the live runtime keys (audio, pointer), spread over both sides.
    mutating func frames(_ to: TransitionSide, size: UInt32, t: Double, extra: [String: Double])
        -> (frame: OrbFrame?, previous: OrbFrame?, blend: Double)
    {
        func draw(_ s: TransitionSide) -> OrbFrame? {
            frameWithOverrides(state: s.state, size: size, t: t, overrides: s.overrides.merging(extra) { $1 })
        }
        guard let from, let m = mix(to, size: size) else {
            shown = to
            return (draw(to), nil, 1)
        }
        switch m.technique {
        case "params":
            let base = TransitionSide(state: to.state, speed: m.speed, overrides: m.overrides)
            let swapped = TransitionSide(
                state: to.state, speed: m.speed, overrides: m.overrides.merging(m.structuralTo) { $1 })
            let structural = !m.structuralTo.isEmpty
            shown = structural && m.swap >= 0.5 ? swapped : base
            if !structural || m.swap <= 0 { return (draw(base), nil, 1) }
            if m.swap >= 1 { return (draw(swapped), nil, 1) }
            return (draw(swapped), draw(base), m.swap)
        case "morph":
            shown = to
            func withExtra(_ s: TransitionSide) -> TransitionSide {
                TransitionSide(state: s.state, speed: s.speed, overrides: s.overrides.merging(extra) { $1 })
            }
            if let f = frameTransitionWithOverrides(
                from: withExtra(from), to: withExtra(to), size: size, t: t, blend: m.weight)
            {
                return (f, nil, 1)
            }
            return (draw(to), draw(from), m.weight)
        default:
            shown = to
            return (draw(to), draw(from), m.weight)
        }
    }
}
