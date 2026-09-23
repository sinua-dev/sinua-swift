import Foundation

/// Sample-accurate synthesis of Web's `TestToneVoiceSource` signal: three
/// sine partials (160 / 520 / 1400 Hz at gains 1 / 0.5 / 0.28 -- a speech-
/// like spread so the log-spaced bands actually differ) under a burst
/// envelope: 0 -> 0.6 over 30 ms, linearly back to 0 by the end of a
/// 0.3-0.8 s burst, then a 0.2-0.6 s gap. No audio output (Web routes its
/// tone at zero gain too), no microphone permission.
public struct TestToneGenerator {
    public let sampleRate: Double
    private static let partials: [(freq: Double, gain: Double)] = [(160, 1.0), (520, 0.5), (1400, 0.28)]
    private var random: () -> Double
    private var sampleIndex = 0
    private var burstStart = 0.0
    private var burstLen = 0.0
    private var cycleLen = 0.0

    /// `random` returns 0..<1 (injectable for tests; defaults to the system RNG, like Web's `Math.random`).
    public init(sampleRate: Double = 48_000, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.sampleRate = sampleRate
        self.random = random
        nextBurst(at: 0)
    }

    private mutating func nextBurst(at t: Double) {
        burstStart = t
        burstLen = 0.3 + random() * 0.5
        cycleLen = burstLen + 0.2 + random() * 0.4
    }

    /// The next `count` samples.
    public mutating func next(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let t = Double(sampleIndex) / sampleRate
            if t - burstStart >= cycleLen { nextBurst(at: burstStart + cycleLen) }
            let u = t - burstStart
            let env: Double
            if u < 0.03 {
                env = 0.6 * (u / 0.03)
            } else if u < burstLen {
                env = 0.6 * (1 - (u - 0.03) / (burstLen - 0.03))
            } else {
                env = 0
            }
            var s = 0.0
            for p in Self.partials { s += p.gain * sin(2 * .pi * p.freq * t) }
            out[j] = Float(s * env)
            sampleIndex += 1
        }
        return out
    }
}
