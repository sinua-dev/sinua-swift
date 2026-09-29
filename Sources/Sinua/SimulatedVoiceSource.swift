import CoreEngine
import Foundation
import SinuaVoiceTypes

/// A simulated conversation as a `VoiceSource` -- the Swift mirror of `@sinua/core`'s
/// `SimulatedVoiceSource` (docs/audio-pipeline.md, *Simulated conversations*). A script of
/// turns plays like a real agent: state changes on a timeline, a speech-like level and bands
/// while someone talks, the barge-in flash. No microphone, no audio session, no network. The
/// curves come from the engine (`conversationAt`), so Web and Android play the same conversation.
///
/// ```swift
/// let voice = try SimulatedVoiceSource(sample: "barge-in")
/// SinuaView(pattern: "glowing", voice: voice)
/// try await voice.connect()   // plays and loops
/// ```
/// Callbacks arrive on the main thread.
public final class SimulatedVoiceSource: VoiceSource {
    public enum Failure: LocalizedError {
        case invalidScript(String)
        public var errorDescription: String? {
            switch self {
            case .invalidScript(let m): return "SimulatedVoiceSource: \(m)"
            }
        }
    }

    /// One turn on the timeline, for a timeline UI.
    public struct Turn: Equatable {
        public let state: String
        public let start: Double
        public let seconds: Double
        public let line: String
        public let bargeIn: Bool
        /// `"user"`, `"agent"`, or nil for a silent turn.
        public let voice: String?
    }

    /// The built-in samples: `calendar`, `quick-answer`, `long-answer`, `barge-in`.
    public static var sampleNames: [String] { conversationSampleNames() }

    private let script: String
    private let bands: UInt32
    private let rate: Double
    /// Whether time wraps at the end.
    public var loop: Bool
    public let turns: [Turn]
    /// The script's length in seconds.
    public let duration: Double
    /// The script time now, seconds.
    public private(set) var time = 0.0
    public private(set) var isPlaying = false

    private var connected = false
    private var timer: DispatchSourceTimer?
    private var lastTick: TimeInterval = 0
    private var lastState: String?
    private var lastTurn: Int = -1
    private var metricsCb: ((VoiceMetrics) -> Void)?
    private var stateCb: ((AgentState) -> Void)?
    private var interruptCb: (() -> Void)?
    private var frameCb: ((ConversationFrame) -> Void)?
    private var connectionCb: ((Bool) -> Void)?
    private var muted = false

    /// A built-in sample by name.
    public convenience init(sample: String, bands: Int = 16, loop: Bool? = nil) throws {
        guard let json = conversationSample(name: sample) else {
            throw Failure.invalidScript("no sample named \"\(sample)\"")
        }
        try self.init(script: json, bands: bands, loop: loop)
    }

    /// A script as JSON text (`{ turns: [{ state, seconds, voice?, bargeIn?, line? }] }`).
    public init(script: String, bands: Int = 16, rate: Double = 30, loop: Bool? = nil) throws {
        let probe = conversationAt(json: script, t: 0, bandCount: 1)
        guard probe.ok else {
            let d = probe.diagnostics.first { $0.severity == "error" }
            throw Failure.invalidScript(d.map { "\($0.path.isEmpty ? "/" : $0.path): \($0.message)" } ?? "not a script")
        }
        self.script = script
        self.bands = UInt32(max(1, bands))
        self.rate = max(1, rate)
        let doc = (try? JSONSerialization.jsonObject(with: Data(script.utf8))) as? [String: Any] ?? [:]
        self.loop = loop ?? (doc["loop"] as? Bool ?? false)
        var start = 0.0
        turns = (doc["turns"] as? [[String: Any]] ?? []).map { t in
            let seconds = t["seconds"] as? Double ?? 0
            defer { start += seconds }
            return Turn(
                state: t["state"] as? String ?? "idle", start: start, seconds: seconds,
                line: t["line"] as? String ?? "", bargeIn: t["bargeIn"] as? Bool ?? false,
                voice: t["voice"] as? String)
        }
        duration = probe.total
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { stateCb = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { interruptCb = cb }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) { connectionCb = cb }
    public var reportsConnection: Bool { true }
    public var supportsMute: Bool { true }

    /// Muted, the user's turns go silent (as a muted mic would); the agent's keep playing.
    public func setMuted(_ muted: Bool) {
        self.muted = muted
        emit()
    }
    /// Every tick's full reading (turn, progress, the line said so far), for captions and a timeline.
    public func onFrame(_ cb: @escaping (ConversationFrame) -> Void) { frameCb = cb }

    /// Starts playing from the current time. Never asks for a microphone.
    public func connect() async throws {
        await MainActor.run {
            let was = connected
            connected = true
            if !was { connectionCb?(true) }
            lastState = nil
            lastTurn = -1
            play()
            emit()
        }
    }

    public func disconnect() {
        let stop = { [self] in
            let was = connected
            connected = false
            if was { connectionCb?(false) }
            pause()
            metricsCb?(VoiceMetrics(level: 0, bands: Array(repeating: 0, count: Int(bands))))
            if lastState != "idle" { stateCb?(.idle) }
            lastState = "idle"
        }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.sync(execute: stop) }
    }

    public func play() {
        guard connected, !isPlaying else { return }
        isPlaying = true
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / rate)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.advance(now - self.lastTick)
            self.lastTick = now
        }
        timer = t
        t.resume()
    }

    public func pause() {
        isPlaying = false
        timer?.cancel()
        timer = nil
    }

    /// Jump to `t` seconds (no barge-in flash for a turn you jump into).
    public func seek(_ t: Double) {
        time = min(max(0, t), duration)
        lastTurn = Int(conversationAt(json: script, t: min(time, duration), bandCount: 1).turn)
        emit()
    }

    /// Move time on by `dt` seconds (the timer calls this; so can tests).
    public func advance(_ dt: Double) {
        guard isPlaying else { return }
        time += max(0, dt)
        if time >= duration { time = loop ? time.truncatingRemainder(dividingBy: duration) : duration }
        emit()
    }

    private func emit() {
        guard connected else { return }
        // `loop` is ours, not the script's: past the end without it, hold the last instant.
        let at = loop ? time : min(time, duration - 1e-9)
        let f = conversationAt(json: script, t: at, bandCount: bands)
        if Int(f.turn) != lastTurn {
            let entering = lastTurn != -1 && f.bargeIn
            lastTurn = Int(f.turn)
            if entering { interruptCb?() }
        }
        if f.state != lastState {
            lastState = f.state
            stateCb?(AgentState(rawValue: f.state) ?? .idle)
        }
        if muted, turns.indices.contains(Int(f.turn)), turns[Int(f.turn)].voice == "user" {
            metricsCb?(VoiceMetrics(level: 0, bands: f.bands.map { _ in 0 }))
        } else {
            metricsCb?(VoiceMetrics(level: f.level, bands: f.bands))
        }
        frameCb?(f)
    }
}
