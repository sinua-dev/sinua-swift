import Foundation

/// `queued` (scheduled, not yet audible), `audible`, `drained` -- Web `PcmAudioGraph`'s `PlaybackState`.
public enum PlaybackState: String, Sendable {
    case queued, audible, drained
}

/// The playback timeline of `PcmAudioGraph` (packages/voice/src/PcmAudioGraph.ts)
/// in frames instead of `AudioContext.currentTime`: a new burst starts
/// `leadFrames` after "now" (Google's `initialBufferTime`, 0.1 s), later
/// chunks follow gap-free at the cursor. It also keeps the recent samples
/// with their frame positions, so the analyser can be fed exactly what has
/// *played* by a given frame -- the rule that `speaking` and the metrics
/// follow the playback timeline, not chunk receipt. Pure: the player only
/// supplies the played-frames clock.
public final class PlaybackTimeline {
    public let rate: Int
    public let leadFrames: Int64
    public private(set) var cursor: Int64 = 0
    public private(set) var burstStart: Int64 = 0
    private var chunks: [(start: Int64, samples: [Float])] = []
    /// How far back `played(from:to:)` can reach; older chunks are dropped.
    private let historyFrames: Int64

    public init(rate: Int, leadSeconds: Double = 0.1) {
        self.rate = rate
        leadFrames = Int64((leadSeconds * Double(rate)).rounded())
        historyFrames = Int64(rate)  // 1 s
    }

    /// Schedule `samples` given the current played frame; returns the frame it starts at.
    @discardableResult
    public func append(_ samples: [Float], now: Int64) -> Int64 {
        guard !samples.isEmpty else { return cursor }
        if cursor <= now {
            cursor = now + leadFrames
            burstStart = cursor
        }
        let start = cursor
        chunks.append((start, samples))
        cursor += Int64(samples.count)
        prune(before: now - historyFrames)
        return start
    }

    public func state(now: Int64) -> PlaybackState {
        if cursor == 0 || now >= cursor { return .drained }
        return now >= burstStart ? .audible : .queued
    }

    /// The samples covering frames `[from, to)`, silence where nothing was
    /// scheduled; only the newest `maxCount` are returned (the analyser needs 512).
    public func played(from: Int64, to: Int64, maxCount: Int = 4096) -> [Float] {
        guard to > from else { return [] }
        let lo = max(from, to - Int64(maxCount))
        var out = [Float](repeating: 0, count: Int(to - lo))
        for c in chunks {
            let cEnd = c.start + Int64(c.samples.count)
            let a = max(lo, c.start)
            let b = min(to, cEnd)
            if a >= b { continue }
            for f in a..<b { out[Int(f - lo)] = c.samples[Int(f - c.start)] }
        }
        prune(before: to - historyFrames)
        return out
    }

    /// Interrupt / reconnect: drop everything; the player's clock restarts at 0 too.
    public func clear() {
        chunks.removeAll()
        cursor = 0
        burstStart = 0
    }

    private func prune(before frame: Int64) {
        chunks.removeAll { $0.start + Int64($0.samples.count) <= frame }
    }
}

/// What a platform audio stack provides to `PcmAudioGraph`: capture at a
/// fixed input rate, and a player at a fixed output rate that can schedule a
/// buffer at a frame of its own clock. `AVPcmAudioDevice` is the real one;
/// tests use a fake whose clock they drive.
public protocol PcmAudioDevice: AnyObject {
    /// Starts capture + playback. `onCapture` runs on an audio thread with mono floats at `inputRate`.
    func start(inputRate: Int, outputRate: Int, onCapture: @escaping @Sendable ([Float]) -> Void) throws
    /// Frames played since the last start/`resetPlayback()`, on the player's clock.
    var playedFrames: Int64 { get }
    /// Play `samples` starting at `frame` on the player's clock (never earlier than now).
    func schedule(_ samples: [Float], atFrame frame: Int64)
    /// Stop and drop everything scheduled; the clock restarts at 0. `fade`: a short ramp, a hard cut clicks.
    func resetPlayback(fade: Bool)
    func stop()
    /// Set by `PcmAudioGraph`: the device's own clock restarted and its scheduled audio is gone
    /// (e.g. the engine was restarted after an audio route/configuration change). Main thread.
    var onClockReset: (() -> Void)? { get set }
}

/// The native `PcmAudioGraph`: mic capture at the vendor's input rate, gap-free
/// scheduled playback at its output rate, and `AudioAnalysis` fed from the
/// *played* samples. Shared by the PCM-over-socket vendors (Gemini Live;
/// ElevenLabs next), like on Web. Main thread, except `onCapture`.
public final class PcmAudioGraph {
    public let device: PcmAudioDevice
    public private(set) var timeline: PlaybackTimeline
    private let spectrum = SpectrumAnalyser()
    private let analysis = AudioAnalysis()
    private var analysedTo: Int64 = 0
    private var running = false

    public init(device: PcmAudioDevice) {
        self.device = device
        timeline = PlaybackTimeline(rate: 24000)
        device.onClockReset = { [weak self] in
            self?.timeline.clear()
            self?.analysedTo = 0
        }
    }

    public func start(inputRate: Int, outputRate: Int, onCapture: @escaping @Sendable ([Float]) -> Void) throws {
        timeline = PlaybackTimeline(rate: outputRate)
        spectrum.reset()
        analysis.reset()
        analysedTo = 0
        try device.start(inputRate: inputRate, outputRate: outputRate, onCapture: onCapture)
        running = true
    }

    /// Schedule decoded samples; `rate` other than the output rate is resampled.
    public func enqueue(_ samples: [Float], rate: Int) {
        guard running, !samples.isEmpty else { return }
        let s = Pcm.resample(samples, from: rate, to: timeline.rate)
        let at = timeline.append(s, now: device.playedFrames)
        device.schedule(s, atFrame: at)
    }

    public func playbackState() -> PlaybackState {
        running ? timeline.state(now: device.playedFrames) : .drained
    }

    /// Current metrics of what has played since the last read, or nil before `start`.
    public func read() -> VoiceMetrics? {
        guard running else { return nil }
        let now = device.playedFrames
        if now < analysedTo { analysedTo = now }  // clock restarted (reset)
        spectrum.push(timeline.played(from: analysedTo, to: now, maxCount: spectrum.fftSize))
        analysedTo = now
        return analysis.read(spectrum.byteFrequencyData())
    }

    public func clearPlayback(fade: Bool) {
        timeline.clear()
        guard running else { return }
        device.resetPlayback(fade: fade)
        analysedTo = 0
    }

    public func stop() {
        if running { device.stop() }
        running = false
        timeline.clear()
        analysedTo = 0
    }
}
