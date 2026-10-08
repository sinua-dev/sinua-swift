import CoreEngine
import Foundation

/// The transition clock reaches ~95 % of the way when `ωt ≈ 6.3`: `ω = 6.3 / duration`.
let lag95 = 6.3
/// A frame's step is capped here, as the views cap the phase and the inputs.
let transitionMaxDt = 0.1
/// A gap longer than this (back from the background): the weights land on the target.
let settleGapSeconds = 1.0
/// Below this a state that is no longer the target is dropped.
private let gone = 1e-4
/// The lattice-sharing orb patterns (the engine morphs them point by point).
private let lattice: Set<String> = ["glowing", "calibrating", "progressing"]

/// State transitions, caller side -- the Swift mirror of `@sinua/core`'s
/// `StateTransition` (packages/core/src/transition.ts; docs/fx-spec.md, *The transition
/// contract*; design note 31). A weight per state moves on a clock of three first-order
/// lags, so a change mid-transition heads somewhere else from where it is, with no kink;
/// the engine blends a pattern's weighted sides (`voiceBlend`). Held to
/// spec/transition-timeline.json with Web and Android.
struct StateTransition {
    private struct Entry {
        /// Its side: the latest `to` for the target, a snapshot for the others.
        var side: TransitionSide?
        var x: Double
        var l1: Double
        var l2: Double
        var v = 0.0
        var x0: Double
        var v0 = 0.0

        init(_ side: TransitionSide?, _ x: Double) {
            self.side = side
            self.x = x
            l1 = x
            l2 = x
            x0 = x
        }
    }

    /// The rate keys of one pattern: the last rate seen, and the sums once one changed.
    private struct Rates {
        var last: [String: Double] = [:]
        var acc: [String: Double] = [:]
    }

    private var entries: [Entry] = []
    private var omega = lag95 / 0.6
    /// An authored curve (the file wrote it): eased with velocity carried, over `duration`.
    private var authored: (curve: String, duration: Double, age: Double)?
    private var size: UInt32 = 64
    private var rates: [String: Rates] = [:]
    private var lastT: Double?
    /// Seconds since the last state change (cut or not); infinite before the first.
    private var since = Double.infinity

    /// A state change happened: the weights head for the new state from where they are.
    /// `duration` 0 = a cut. `authored`: the file wrote `curve` for this change, so it is
    /// kept (velocity carried); otherwise the lag clock, ~95 % of the way in `duration`.
    mutating func start(duration: Double, curve: String, authored: Bool = false) {
        if !entries.isEmpty { since = 0 }
        guard duration > 0, !entries.isEmpty else {
            entries = [Entry(nil, 1)]
            self.authored = nil
            return
        }
        entries.append(Entry(nil, 0))
        omega = lag95 / duration
        self.authored = authored ? (curve, duration, 0) : nil
        for i in entries.indices {
            entries[i].x0 = entries[i].x
            entries[i].v0 = entries[i].v
        }
    }

    /// Stop any transition now (reduced motion, a new design).
    mutating func cancel() {
        entries = entries.last.map { [Entry($0.side, 1)] } ?? []
        authored = nil
    }

    /// No transition running: remember `to` as what is on screen.
    mutating func settle(_ to: TransitionSide) {
        if !active { entries = [Entry(to, 1)] }
    }

    mutating func advance(_ dt: Double) {
        let raw = max(0, dt)
        since += raw
        if raw > settleGapSeconds {
            if let t = entries.last { entries = [Entry(t.side, 1)] }
            authored = nil
            rates = [:]
            return
        }
        let step = min(raw, transitionMaxDt)
        guard entries.count > 1, step > 0 else { return }
        let target = entries.count - 1
        if var a = authored {
            a.age += step
            let s = min(1, a.age / a.duration)
            let eased = ease(a.curve, s)
            let carry = s * s * s - 2 * s * s + s
            for i in entries.indices {
                let goal = i == target ? 1.0 : 0.0
                let e = entries[i]
                let x = s >= 1 ? goal : e.x0 + (goal - e.x0) * eased + e.v0 * a.duration * carry
                entries[i].v = (x - e.x) / step
                entries[i].x = x
                entries[i].l1 = x
                entries[i].l2 = x
            }
            authored = s >= 1 ? nil : a
        } else {
            let k = 1 - exp(-omega * step)
            for i in entries.indices {
                let goal = i == target ? 1.0 : 0.0
                let before = entries[i].x
                entries[i].l1 += (goal - entries[i].l1) * k
                entries[i].l2 += (entries[i].l1 - entries[i].l2) * k
                entries[i].x += (entries[i].l2 - entries[i].x) * k
                entries[i].v = (entries[i].x - before) / step
            }
        }
        var kept: [Entry] = []
        for (i, e) in entries.enumerated() where i == target || e.x >= gone || e.l1 >= gone { kept.append(e) }
        entries = kept
        if entries.count == 1 {
            entries[0].x = 1
            entries[0].l1 = 1
            entries[0].l2 = 1
            entries[0].v = 0
        }
    }

    /// Seconds since the lifecycle state last changed, or nil before the first change.
    /// The frames carry it as the `stateAge` runtime key (a character blinks at the end
    /// of the user's turn); other patterns ignore it.
    var stateAge: Double? { since.isFinite ? since : nil }

    /// More than one state is on screen.
    var active: Bool { entries.count > 1 }

    /// The state weights, oldest first (the newest is the target); for tests and tools.
    var weights: [Double] { entries.map(\.x) }

    /// The rate sums kept for `pattern` (empty until one of its rates changed).
    func rateSums(_ pattern: String) -> [String: Double] { rates[pattern]?.acc ?? [:] }

    /// The speed multiplier to run the phase at now, for `to` (the weighted speed mid-transition).
    func speed(_ to: TransitionSide, size: UInt32) -> Double {
        guard active else { return to.speed }
        var sum = 0.0
        var total = 0.0
        for (i, e) in entries.enumerated() {
            guard let side = i == entries.count - 1 ? to : e.side else { continue }
            sum += e.x * side.speed
            total += e.x
        }
        return total > 0 ? sum / total : to.speed
    }

    /// No transition running and the caller paints `to` itself: `to`'s overrides plus the
    /// rate sums once a rate has changed (until then exactly `to.overrides`). Once a frame.
    mutating func steadyOverrides(_ to: TransitionSide, size: UInt32, t: Double) -> [String: Double] {
        settle(to)
        let dp = tick(t)
        let (_, overrides) = blend(to.state, [entries.count - 1], size: size, t: t, dp: dp)
        return (rates[to.state]?.acc.isEmpty ?? true) ? to.overrides : overrides
    }

    /// The frames for `to` at engine time `t`: `previous` dissolved into `frame` at `blend`.
    /// `extra` is the live runtime keys (audio, pointer), spread over every side.
    mutating func frames(_ to: TransitionSide, size: UInt32, t: Double, extra live: [String: Double])
        -> (frame: OrbFrame?, previous: OrbFrame?, blend: Double)
    {
        self.size = size
        if entries.isEmpty { entries = [Entry(to, 1)] }
        let target = entries.count - 1
        entries[target].side = to
        var extra = live
        if since.isFinite { extra["stateAge"] = since }
        let dp = tick(t)

        // One group per pattern; within it the engine blends the sides by weight.
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            guard let s = e.side else { continue }
            if groups[s.state] == nil { order.append(s.state) }
            groups[s.state, default: []].append(i)
        }
        let drawn = order.map { p in (pattern: p, idx: groups[p]!, w: groups[p]!.reduce(0.0) { $0 + entries[$1].x }) }
            .enumerated()
            .sorted { a, b in a.element.w > b.element.w || (a.element.w == b.element.w && a.offset < b.offset) }
            .prefix(2).map(\.element)
        let blended = drawn.map { blend($0.pattern, $0.idx, size: size, t: t, dp: dp) }
        func with(_ o: [String: Double]) -> [String: Double] { o.merging(extra) { $1 } }
        func draw(_ pattern: String, _ o: [String: Double]) -> OrbFrame? {
            frameWithOverrides(state: pattern, size: size, t: t, overrides: with(o))
        }
        if drawn.count == 1 {
            let (m, o) = blended[0]
            let pattern = drawn[0].pattern
            if m.structuralTo.isEmpty || m.swap <= 0 { return (draw(pattern, o), nil, 1) }
            let swapped = o.merging(m.structuralTo) { $1 }
            if m.swap >= 1 { return (draw(pattern, swapped), nil, 1) }
            return (draw(pattern, swapped), draw(pattern, o), m.swap)
        }
        // Two patterns: the one holding the target fades in over the other.
        let (i, j) = drawn[0].idx.contains(target) ? (1, 0) : (0, 1)
        let blend = drawn[j].w / (drawn[i].w + drawn[j].w)
        if lattice.contains(drawn[i].pattern), lattice.contains(drawn[j].pattern),
            let f = frameTransitionWithOverrides(
                from: TransitionSide(state: drawn[i].pattern, speed: 1, overrides: with(blended[i].1)),
                to: TransitionSide(state: drawn[j].pattern, speed: 1, overrides: with(blended[j].1)),
                size: size, t: t, blend: blend)
        {
            return (f, nil, 1)
        }
        return (draw(drawn[j].pattern, blended[j].1), draw(drawn[i].pattern, blended[i].1), blend)
    }

    /// Engine time moved to `t`: the step since the last frame (a jump back or a long
    /// gap restarts the sums).
    private mutating func tick(_ t: Double) -> Double {
        let dp = lastT.map { t - $0 } ?? 0
        if dp < 0 || dp > 1 { rates = [:] }
        lastT = t
        return dp < 0 || dp > 1 ? 0 : dp
    }

    /// A pattern's sides blended by weight, with its rate keys accumulated.
    private mutating func blend(_ pattern: String, _ idx: [Int], size: UInt32, t: Double, dp: Double)
        -> (TransitionMix, [String: Double])
    {
        let sides = idx.compactMap { entries[$0].side }
        let target = entries.count - 1
        var heaviest = 0
        for k in idx.indices where entries[idx[k]].x > entries[idx[heaviest]].x { heaviest = k }
        let ti = idx.firstIndex(of: target) ?? heaviest
        let m =
            voiceBlend(sides: sides, weights: idx.map { entries[$0].x }, target: UInt32(ti), size: size)
            ?? TransitionMix(
                technique: "params", weight: 1, speed: sides[0].speed, overrides: sides[0].overrides,
                structuralTo: [:], swap: 0, rates: [:])
        var r = rates[pattern] ?? Rates()
        for (k, rate) in m.rates {
            if let a = r.acc[k] {
                r.acc[k] = a + dp * rate
            } else if let before = r.last[k], before != rate {
                // The first change of a rate: from here the view keeps the sum (until then
                // the engine's own `t × rate` is exact, so a steady view draws what it drew).
                r.acc[k] = (t - dp) * before + dp * rate
            }
            r.last[k] = rate
        }
        rates[pattern] = r
        return (m, m.overrides.merging(r.acc) { $1 })
    }

    /// A CSS keyword curve at `s`, as the engine eases it.
    private func ease(_ curve: String, _ s: Double) -> Double {
        guard let side = entries.last?.side else { return s }
        return transitionMix(from: side, to: side, size: size, progress: s, curve: curve)?.weight ?? s
    }
}
