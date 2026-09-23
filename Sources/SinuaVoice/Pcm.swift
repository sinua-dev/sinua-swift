import Foundation

/// PCM16 little-endian <-> float, a port of packages/voice/src/pcm.ts so
/// the native vendor transports encode and decode exactly as Web does.
public enum Pcm {
    /// PCM16 LE bytes -> floats in -1...1 (`/32768`). A trailing odd byte is ignored.
    public static func pcm16ToFloat(_ data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let v = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    /// Floats -> PCM16 LE bytes: clamp to -1...1, `round(s * 32768)`, clamp to Int16 -- pcm.ts's `float32ToPcm16`.
    public static func floatToPcm16<C: Collection>(_ samples: C) -> Data where C.Element == Float {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            for s in samples {
                let c = Double(max(-1, min(1, s)))
                // JS `Math.round` is floor(x + 0.5); match it exactly or the
                // platforms disagree on negative halves.
                let v = Int16(max(-32768, min(32767, (c * 32768 + 0.5).rounded(.down))))
                let u = UInt16(bitPattern: v)
                bytes[2 * i] = UInt8(u & 0xFF)
                bytes[2 * i + 1] = UInt8(u >> 8)
                i += 1
            }
        }
        return out
    }

    /// `audio/pcm;rate=24000` -> 24000; `fallback` when absent.
    public static func parseRate(_ mimeType: String?, fallback: Int = 24000) -> Int {
        guard let mime = mimeType, let r = mime.range(of: "rate=", options: .caseInsensitive) else { return fallback }
        let digits = mime[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits) ?? fallback
    }

    /// Linear resample. Only for a chunk whose rate differs from the player's
    /// fixed output rate (Gemini always sends 24 kHz; Web Audio resamples
    /// such a buffer itself, a native player node has one format).
    public static func resample(_ samples: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, from > 0, to > 0, !samples.isEmpty else { return samples }
        let n = max(1, Int((Double(samples.count) * Double(to) / Double(from)).rounded()))
        let step = Double(from) / Double(to)
        return (0..<n).map { i in
            let x = Double(i) * step
            let i0 = min(samples.count - 1, Int(x))
            let i1 = min(samples.count - 1, i0 + 1)
            let t = Float(x - Double(i0))
            return samples[i0] * (1 - t) + samples[i1] * t
        }
    }

    /// `pcm_16000` / `ulaw_8000` (ElevenLabs' format strings) -- pcm.ts's `parseAudioFormat`.
    public struct AudioFormat: Equatable, Sendable {
        public enum Codec: String, Sendable { case pcm, ulaw }
        public let codec: Codec
        public let rate: Int
        public init(codec: Codec, rate: Int) {
            self.codec = codec
            self.rate = rate
        }
    }

    public static func parseAudioFormat(
        _ format: String?, fallback: AudioFormat = AudioFormat(codec: .pcm, rate: 16000)
    ) -> AudioFormat {
        let parts = (format ?? "").trimmingCharacters(in: .whitespaces).lowercased().split(separator: "_")
        guard parts.count == 2, let codec = AudioFormat.Codec(rawValue: String(parts[0])),
            let rate = Int(parts[1]), parts[1].allSatisfy(\.isNumber)
        else { return fallback }
        return AudioFormat(codec: codec, rate: rate)
    }

    private static let ulawTable: [Int] = [0, 132, 396, 924, 1980, 4092, 8316, 16764]

    /// G.711 μ-law bytes -> floats (`/32768`), pcm.ts's `ulawToFloat32` table decode.
    public static func ulawToFloat(_ data: Data) -> [Float] {
        data.map { byte in
            let u = Int(~byte & 0xFF)
            let exponent = (u >> 4) & 0x07
            var sample = ulawTable[exponent] + ((u & 0x0F) << (exponent + 3))
            if u & 0x80 != 0 { sample = -sample }
            return Float(sample) / 32768
        }
    }
}
