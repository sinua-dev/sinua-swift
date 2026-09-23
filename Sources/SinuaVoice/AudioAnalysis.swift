import Foundation

/// Byte spectrum -> `VoiceMetrics`, a line-for-line port of Web's
/// packages/voice/src/analysis.ts (see its doc comment for why each step
/// exists): the voice-relevant bin range [5 %, 40 %), log-spaced band edges,
/// sqrt compression, asymmetric attack/release, level = the loudest band.
/// Same defaults, so a native app and the Web Studio read identical
/// metrics from identical audio.
public final class AudioAnalysis {
    public let bandCount: Int
    private let attack: Double
    private let release: Double
    private let loFrac: Double
    private let hiFrac: Double
    private var levelState = 0.0
    private var bandState: [Double]

    public init(
        bandCount: Int = 16, attack: Double = 0.7, release: Double = 0.12, loFrac: Double = 0.05, hiFrac: Double = 0.4
    ) {
        self.bandCount = bandCount
        self.attack = attack
        self.release = release
        self.loFrac = loFrac
        self.hiFrac = hiFrac
        bandState = [Double](repeating: 0, count: bandCount)
    }

    /// One update tick over a byte spectrum (`SpectrumAnalyser.byteFrequencyData()`).
    public func read(_ data: [UInt8]) -> VoiceMetrics {
        let count = data.count
        let lo = max(1, Int((Double(count) * loFrac).rounded(.down)))
        let hi = max(lo + bandCount, Int((Double(count) * hiFrac).rounded(.down)))

        let logLo = log(Double(lo))
        let logHi = log(Double(hi))
        var edges: [Int] = []
        edges.reserveCapacity(bandCount + 1)
        for b in 0...bandCount {
            // JS Math.round: half rounds up -- identical to `.toNearestOrAwayFromZero` for these positive values.
            edges.append(
                Int(exp(logLo + (logHi - logLo) * (Double(b) / Double(bandCount))).rounded(.toNearestOrAwayFromZero)))
        }

        var targets: [Double] = []
        targets.reserveCapacity(bandCount)
        for b in 0..<bandCount {
            let start = edges[b]
            let end = max(start + 1, edges[b + 1])
            var sum = 0.0
            var n = 0
            var i = start
            while i < end && i < count {
                sum += Double(data[i])
                n += 1
                i += 1
            }
            let raw = n > 0 ? sum / Double(n) / 255 : 0
            targets.append(max(0, min(1, raw)).squareRoot())
        }

        for b in 0..<bandCount {
            let target = targets[b]
            let current = bandState[b]
            let rate = target > current ? attack : release
            bandState[b] = current + (target - current) * rate
        }

        let levelTarget = targets.reduce(0, max)
        let levelRate = levelTarget > levelState ? attack : release
        levelState += (levelTarget - levelState) * levelRate

        return VoiceMetrics(level: levelState, bands: bandState)
    }

    public func reset() {
        levelState = 0
        bandState = [Double](repeating: 0, count: bandCount)
    }
}
