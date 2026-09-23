import Combine
import Foundation

/// Frame-rate cap by skipping display frames -- the same rule as
/// @sinua/web's `createFramePacer` (docs/fx-view.md, *Performance and
/// power*), for loops that tick every vsync (e.g. a `CADisplayLink`).
/// `SinuaView` itself uses `TimelineView(.animation(minimumInterval:))`, which
/// schedules at the interval instead of waking every vsync.
public struct FramePacer {
    private let interval: Double?
    private var last: Double?

    /// `maxFps` nil, <= 0 or non-finite: every frame draws.
    public init(maxFps: Double?) {
        if let f = maxFps, f > 0, f.isFinite { interval = 1000 / f } else { interval = nil }
    }

    /// Whether the frame at `nowMs` should be drawn. Draw when `now - last >= interval - 1 ms`,
    /// then advance `last` by the whole intervals the gap covers (a fixed grid: exact average
    /// rate, no drift, no burst after a stall).
    public mutating func shouldDraw(atMs now: Double) -> Bool {
        guard let interval else { return true }
        guard let l = last else {
            last = now
            return true
        }
        let since = now - l
        if since < interval - 1 { return false }
        last = l + interval * max(1, ((since + 1) / interval).rounded(.down))
        return true
    }
}

/// Low-power handling: `.auto` follows iOS Low Power Mode.
public enum FxLowPower: Sendable {
    case auto, on, off
}

/// Low Power Mode, observed: `ProcessInfo.isLowPowerModeEnabled` plus
/// `NSProcessInfoPowerStateDidChange` (posted on a background queue -- hopped
/// to main here).
@MainActor
public final class LowPowerMonitor: ObservableObject {
    public static let shared = LowPowerMonitor()
    @Published public private(set) var isLowPowerModeEnabled: Bool
    private var token: NSObjectProtocol?

    init(
        center: NotificationCenter = .default,
        read: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        isLowPowerModeEnabled = read()
        token = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) {
            [weak self] _ in
            let value = read()
            Task { @MainActor in self?.isLowPowerModeEnabled = value }
        }
    }
}

/// The effective cap and extra engine opts for this frame's power situation.
public struct FxPerformance: Equatable, Sendable {
    public var maxFps: Double?
    public var overrides: [String: Double]
}

/// The default when low power is on and the spec has no `performance.lowPower` (FX Spec 1.2):
/// 30 fps, glow and particles off (docs/fx-spec.md's recommended host default).
public let fxDefaultLowPower = FxPerformance(maxFps: 30, overrides: ["glowStrength": 0, "particleStrength": 0])

/// The single place FX Spec 1.2's `performance` block is honoured -- same rule as
/// @sinua/web's `performanceFor`: `specMaxFps` is the resolver's cap for this power
/// state (`FxSpecResolved.maxFps`); `specHandlesLowPower` means the spec has a
/// `performance.lowPower` block (the resolver already shed/capped); otherwise low power adds
/// `fxDefaultLowPower`; the view's own `maxFps` caps further (the lowest wins).
public func fxPerformance(
    lowPower: Bool, optionMaxFps: Double?, specMaxFps: Double? = nil, specHandlesLowPower: Bool = false
) -> FxPerformance {
    var caps: [Double] = []
    var overrides: [String: Double] = [:]
    if let s = specMaxFps, s > 0 { caps.append(s) }
    if lowPower && !specHandlesLowPower {
        caps.append(fxDefaultLowPower.maxFps!)
        overrides = fxDefaultLowPower.overrides
    }
    if let o = optionMaxFps, o > 0 { caps.append(o) }
    return FxPerformance(maxFps: caps.min(), overrides: overrides)
}

/// Per drawn frame: time since the previous drawn frame, engine time and paint time (ms).
public struct FxFrameStats: Sendable {
    public var dtMs: Double
    public var computeMs: Double
    public var paintMs: Double
}
