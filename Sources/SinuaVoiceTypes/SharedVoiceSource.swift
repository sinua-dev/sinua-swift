import Foundation

// One source, many listeners -- the Swift mirror of `@sinua/core`'s SharedVoiceSource
// (docs/audio-pipeline.md, *Sharing a source*). A `VoiceSource` holds ONE callback of
// each kind, so a second subscriber (a view next to a voice button, two views) silently
// replaces the first. This subscribes once and fans out; it is itself a `VoiceSource`.
// Call on the main thread; callbacks arrive there.

/// A fan-out over one `VoiceSource`, which also owns the session's mute.
public final class SharedVoiceSource: VoiceSource {
    /// The wrapped source. Don't subscribe to it directly: that takes its one callback away from this fan-out.
    public let source: VoiceSource

    private var nextId = 0
    private var metricsCbs: [Int: (VoiceMetrics) -> Void] = [:]
    private var stateCbs: [Int: (AgentState) -> Void] = [:]
    private var interruptCbs: [Int: () -> Void] = [:]
    private var muteCbs: [Int: (Bool) -> Void] = [:]
    private var connectionCbs: [Int: (Bool) -> Void] = [:]

    /// The source's last reported state (`.idle` before any).
    public private(set) var state: AgentState = .idle
    public private(set) var muted = false
    /// The last `onConnectionChange` value (false before any).
    public private(set) var connected = false

    // Keys and values weak: a fan-out lives as long as someone (a view, a button) holds it.
    private static let table = NSMapTable<AnyObject, SharedVoiceSource>.weakToWeakObjects()

    /// The fan-out for `source`: the same instance every time for the same source (while
    /// something holds it), so a view and a voice button given one raw source share one
    /// subscription. A `SharedVoiceSource` is returned as is.
    public static func of(_ source: VoiceSource) -> SharedVoiceSource {
        if let s = source as? SharedVoiceSource { return s }
        if let s = table.object(forKey: source) { return s }
        let s = SharedVoiceSource(source)
        table.setObject(s, forKey: source)
        return s
    }

    private init(_ source: VoiceSource) {
        self.source = source
        source.onMetrics { [weak self] m in
            guard let self else { return }
            for cb in self.metricsCbs.values { cb(m) }
        }
        source.onStateChange { [weak self] s in
            guard let self else { return }
            self.state = s
            for cb in self.stateCbs.values { cb(s) }
        }
        source.onInterrupt { [weak self] in
            guard let self else { return }
            for cb in self.interruptCbs.values { cb() }
        }
        source.onConnectionChange { [weak self] c in
            guard let self else { return }
            self.connected = c
            for cb in self.connectionCbs.values { cb(c) }
        }
    }

    private func id() -> Int {
        nextId += 1
        return nextId
    }

    // MARK: - Listeners (each returns its cancel)

    @discardableResult public func listenMetrics(_ cb: @escaping (VoiceMetrics) -> Void) -> () -> Void {
        let i = id()
        metricsCbs[i] = cb
        return { [weak self] in self?.metricsCbs[i] = nil }
    }

    @discardableResult public func listenState(_ cb: @escaping (AgentState) -> Void) -> () -> Void {
        let i = id()
        stateCbs[i] = cb
        return { [weak self] in self?.stateCbs[i] = nil }
    }

    @discardableResult public func listenInterrupt(_ cb: @escaping () -> Void) -> () -> Void {
        let i = id()
        interruptCbs[i] = cb
        return { [weak self] in self?.interruptCbs[i] = nil }
    }

    /// Called with the new value whenever `setMuted` changes it.
    @discardableResult public func listenMute(_ cb: @escaping (Bool) -> Void) -> () -> Void {
        let i = id()
        muteCbs[i] = cb
        return { [weak self] in self?.muteCbs[i] = nil }
    }

    /// Only fires for a source that reports it (`reportsConnection`).
    @discardableResult public func listenConnection(_ cb: @escaping (Bool) -> Void) -> () -> Void {
        let i = id()
        connectionCbs[i] = cb
        return { [weak self] in self?.connectionCbs[i] = nil }
    }

    // MARK: - VoiceSource (the `on…` forms add a listener you can't remove)

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { listenMetrics(cb) }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { listenState(cb) }
    public func onInterrupt(_ cb: @escaping () -> Void) { listenInterrupt(cb) }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) { listenConnection(cb) }
    public var supportsMute: Bool { source.supportsMute }
    public var reportsConnection: Bool { source.reportsConnection }

    /// Connects unmuted: a new session never starts silent from an old mute.
    public func connect() async throws {
        await MainActor.run { setMuted(false) }
        try await source.connect()
    }

    public func disconnect() { source.disconnect() }

    /// Mutes or unmutes the microphone: silence goes out, the session stays up, and views
    /// bound through this fan-out show the muted cue. Always unmuted when the source can't mute.
    public func setMuted(_ muted: Bool) {
        let m = muted && source.supportsMute
        source.setMuted(m)
        guard m != self.muted else { return }
        self.muted = m
        for cb in muteCbs.values { cb(m) }
    }

    /// A view's own tracker fed from this fan-out: its family's easing and history, the
    /// muted cue following `muted`. Released with `Tracked.release()` or when it deinits.
    public func track(options: VoiceOverridesOptions = VoiceOverridesOptions()) -> Tracked {
        let v = VoiceOverrides(options: options)
        v.setState(state)
        v.muted = muted
        let offs = [
            listenMetrics { [weak v] m in v?.push(m) },
            listenInterrupt { [weak v] in v?.interrupt() },
            listenState { [weak v] s in
                v?.setState(s)
                if s == .idle { v?.reset() }
            },
            listenMute { [weak v] m in v?.muted = m },
        ]
        return Tracked(overrides: v, source: self, offs: offs)
    }

    /// One view's subscription: its `VoiceOverrides`, held until `release()` or deinit.
    public final class Tracked {
        public let overrides: VoiceOverrides
        /// Kept so the fan-out lives while a view uses it.
        public let source: SharedVoiceSource
        private var offs: [() -> Void]

        init(overrides: VoiceOverrides, source: SharedVoiceSource, offs: [() -> Void]) {
            self.overrides = overrides
            self.source = source
            self.offs = offs
        }

        public func release() {
            for off in offs { off() }
            offs = []
        }

        deinit { release() }
    }
}
