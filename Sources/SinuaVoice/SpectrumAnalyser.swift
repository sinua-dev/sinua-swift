import Accelerate

/// Web Audio's `AnalyserNode.getByteFrequencyData`, reimplemented so native
/// analysis sees the same bytes the Web path's `AudioAnalysis` does. The
/// steps are the spec's own (WebAudio/web-audio-api `index.bs`, *FFT
/// Windowing and Smoothing over Time*): Blackman window (alpha 0.16),
/// `X[k] = (1/N) sum x[n] e^{-2 pi i k n / N}`, smoothing (the Web path sets
/// `smoothingTimeConstant` 0, so none here), `20 log10`, then
/// `floor(255 / (maxDb - minDb) * (Y - minDb))` clipped to 0...255. Checked
/// byte-for-byte against Chrome's own AnalyserNode (docs/audio-pipeline.md,
/// *Native*). The FFT is Accelerate's real in-place `vDSP_fft_zrip`, whose
/// packed output is 2x the plain DFT -- compensated below.
public final class SpectrumAnalyser {
    public let fftSize: Int
    public let minDecibels: Double
    public let maxDecibels: Double
    /// `fftSize / 2`, as on Web.
    public var frequencyBinCount: Int { fftSize / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var ring: [Float]
    private var writeIndex = 0
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]

    public init(fftSize: Int = 512, minDecibels: Double = -100, maxDecibels: Double = -30) {
        precondition(fftSize >= 32 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two >= 32")
        self.fftSize = fftSize
        self.minDecibels = minDecibels
        self.maxDecibels = maxDecibels
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let n = Double(fftSize)
        window = (0..<fftSize).map { i in
            let x = Double(i)
            return Float(0.42 - 0.5 * cos(2 * .pi * x / n) + 0.08 * cos(4 * .pi * x / n))
        }
        ring = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Append mono samples; only the most recent `fftSize` are analysed, as on Web.
    public func push<C: Collection>(_ samples: C) where C.Element == Float {
        for s in samples {
            ring[writeIndex] = s
            writeIndex = (writeIndex + 1) % fftSize
        }
    }

    /// Clears the sample window (silence).
    public func reset() {
        for i in ring.indices { ring[i] = 0 }
        writeIndex = 0
    }

    /// The byte spectrum of the latest `fftSize` samples, `frequencyBinCount` values.
    public func byteFrequencyData() -> [UInt8] {
        // Oldest sample first, windowed.
        for n in 0..<fftSize {
            windowed[n] = ring[(writeIndex + n) % fftSize] * window[n]
        }
        let half = fftSize / 2
        var out = [UInt8](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                let scale = 255 / (maxDecibels - minDecibels)
                let norm = 2 * Double(fftSize)  // zrip's 2x, then the spec's 1/N
                for k in 0..<half {
                    // Bin 0's imag slot holds Nyquist in the packed format; DC is real-only.
                    let re = Double(rp[k])
                    let im = k == 0 ? 0 : Double(ip[k])
                    let mag = (re * re + im * im).squareRoot() / norm
                    let db = 20 * log10(mag)
                    let b = (scale * (db - minDecibels)).rounded(.down)
                    out[k] = b.isFinite ? UInt8(max(0, min(255, b))) : 0
                }
            }
        }
        return out
    }
}
