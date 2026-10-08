import Foundation
import SinuaVoice

/// `VoiceSource` for ElevenLabs Conversational AI (the Agents platform) over its
/// raw WebSocket -- the native mirror of the Web `ElevenLabsVoiceSource`
/// (packages/voice/src/ElevenLabsVoiceSource.ts). Protocol and state rules
/// live in `ElevenLabsSession`, the playback gate in `PcmAudioGraph` (both
/// SinuaVoice, unit-tested); this class wires them to a socket and an audio
/// device. Callbacks arrive on the main thread.
///
/// Why not ElevenLabs' own Swift SDK: from v3 it carries voice over LiveKit
/// (a WebRTC dependency for every user) and diverges from the Web adapter; the
/// WebSocket protocol is still documented for audio (docs/audio-pipeline.md).
///
/// Formats are negotiated per agent: the audio graph starts after
/// `conversation_initiation_metadata`, at its rates (PCM, or μ-law output).
/// The agent's input format must be PCM. No reconnect: a conversation isn't
/// resumable; a close (1000 = the agent ended it) goes to `idle`.
///
/// Credentials: the shared contract (`CredentialSource`). A **public** agent's
/// `agent_id` (no secret involved), or a `wss://…` **signed URL** for a private
/// agent, minted by your backend (`signElevenLabsUrl` in `@sinua/voice/server`,
/// or `npx @sinua/voice dev-proxy`; valid 15 minutes). With `credentialUrl` or a
/// provider, every `connect()` signs a new one.
///
/// Not verified against the live service yet (docs/audio-pipeline.md).
public final class ElevenLabsVoiceSource: VoiceSource {
    public static let updateHz = 30.0
    static let metadataTimeout: TimeInterval = 15

    private let credentials: CredentialSource
    private let endpoint: URL?
    private let overrides: [String: Any]?
    private let session: ElevenLabsSession
    private let graph: PcmAudioGraph
    private let socketFactory: LiveSocketFactory
    private let requestPermission: () async -> Bool
    private let clock: () -> TimeInterval

    // Main-thread state.
    private var socket: LiveSocket?
    private let micGate = MicGate()
    private var metadataWaiter: CheckedContinuation<(Pcm.AudioFormat, Pcm.AudioFormat), Error>?
    private var wantConnected = false
    private var timer: DispatchSourceTimer?
    private var metricsCb: ((VoiceMetrics) -> Void)?

    /// - Parameters:
    ///   - credential: `.url(…)` / `.provider { … }` for a signed URL per connect, or
    ///     `.value(…)` for a public agent id or one signed URL.
    ///   - overrides: `conversation_config_override` (if the agent allows overrides).
    ///   - endpoint: override the URL (a relay, or tests); the credential is ignored then.
    ///   - syncToAudio: transcripts reveal the agent's text with the played audio, character by
    ///     character (default); `false` shows it as it arrives.
    public init(
        credential: CredentialSource,
        overrides: [String: Any]? = nil,
        endpoint: URL? = nil,
        syncToAudio: Bool = true,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        credentials = credential
        session = ElevenLabsSession(syncToAudio: syncToAudio)
        self.endpoint = endpoint
        self.overrides = overrides
        graph = PcmAudioGraph(device: device)
        self.socketFactory = socketFactory
        self.requestPermission = requestPermission
        self.clock = clock
    }

    /// A public agent id, or one signed `wss://` URL.
    public convenience init(
        credential: String,
        overrides: [String: Any]? = nil,
        endpoint: URL? = nil,
        syncToAudio: Bool = true,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.init(
            credential: .value(credential), overrides: overrides, endpoint: endpoint, syncToAudio: syncToAudio,
            device: device,
            socketFactory: socketFactory, requestPermission: requestPermission, clock: clock)
    }

    /// Your backend's endpoint, answering `{ credential: "wss://…", expiresAt? }`; asked on every connect.
    public convenience init(credentialUrl: URL, overrides: [String: Any]? = nil, syncToAudio: Bool = true) {
        self.init(credential: .url(credentialUrl), overrides: overrides, syncToAudio: syncToAudio)
    }

    private var connectionCb: ((Bool) -> Void)?
    private var sessionUp = false

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { session.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { session.onInterrupt = cb }
    /// Both speakers' live transcript (design note 39); display only, nothing is kept or sent.
    public func onTranscript(_ cb: @escaping (TranscriptUpdate) -> Void) { session.onTranscript = cb }
    public var supportsTranscript: Bool { true }
    public var transcriptTiming: TranscriptTiming { .chars }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) { connectionCb = cb }
    public var reportsConnection: Bool { true }
    public var supportsMute: Bool { true }

    /// Muted, silence goes out: the mic chunks are sent zeroed (the server's turn detection
    /// keeps its timing) and the session stays up.
    public func setMuted(_ muted: Bool) { micGate.muted = muted }

    private func setSessionUp(_ up: Bool) {
        guard up != sessionUp else { return }
        sessionUp = up
        connectionCb?(up)
    }

    public func connect() async throws {
        // Before the socket and the prompt: a failed signing must not open a
        // device. A signed URL is valid for 15 minutes, so each connect gets one.
        let url: URL
        if let endpoint {
            url = endpoint
        } else {
            let credential: String
            do {
                credential = try await credentials.resolve(vendor: "ElevenLabsVoiceSource").credential
            } catch CredentialError.fatal(let m) where m.hasSuffix("a credential is required") {
                throw ElevenLabsError.missingCredential
            }
            guard let u = ElevenLabsSession.endpoint(credential: credential) else {
                throw ElevenLabsError.missingCredential
            }
            url = u
        }
        await MainActor.run {
            wantConnected = true
            session.connecting(now: clock())
        }
        do {
            // Socket + metadata first, then the permission prompt, then the audio: a bad
            // agent id / expired signed URL fails without a prompt or an open mic. An
            // early greeting is held by the session until the graph starts.
            let (input, output) = try await openSocket(url)
            guard input.codec == .pcm else {
                throw ElevenLabsError.unsupportedInputFormat("\(input.codec.rawValue)_\(input.rate)")
            }
            guard await requestPermission() else { throw VoiceSourceError.permissionDenied }
            try await MainActor.run {
                let gate = micGate
                try graph.start(inputRate: input.rate, outputRate: output.rate) { samples in
                    let out = gate.muted ? [Float](repeating: 0, count: samples.count) : samples
                    gate.send(ElevenLabsSession.micMessage(out))
                }
                apply(session.graphStarted(output: output, now: clock()))
                micGate.socket = socket
                startTimer()
                setSessionUp(true)
            }
        } catch {
            await MainActor.run { disconnect() }
            throw error
        }
    }

    public func disconnect() {
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.sync { teardown() } }
    }

    // MARK: - Socket (main thread)

    private func openSocket(_ url: URL) async throws -> (Pcm.AudioFormat, Pcm.AudioFormat) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async { [self] in
                guard wantConnected else { return cont.resume(throwing: CancellationError()) }
                metadataWaiter = cont
                var opened: LiveSocket?
                opened = socketFactory.open(
                    url: url, headers: [:], protocols: [ElevenLabsSession.subprotocol],
                    onText: { [weak self] text in self?.onText(text) },
                    onClose: { [weak self] err in
                        guard let self, let s = opened, s === self.socket else { return }
                        self.onSocketClosed(err)
                    })
                socket = opened
                opened?.send(ElevenLabsSession.initMessage(overrides: overrides))
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.metadataTimeout) { [weak self] in
                    guard let self, let s = opened, s === self.socket, self.metadataWaiter != nil else { return }
                    self.failSetup(ElevenLabsError.metadataTimeout)
                }
            }
        }
    }

    private func onText(_ text: String) {
        apply(session.handle(text, playback: graph.playbackState(), now: clock()))
    }

    private func apply(_ actions: [ElevenLabsSession.Action]) {
        for action in actions {
            switch action {
            case .metadata(let input, let output):
                metadataWaiter?.resume(returning: (input, output))
                metadataWaiter = nil
            case .send(let text):
                socket?.send(text)
            case .enqueue(let samples, let rate):
                graph.enqueue(samples, rate: rate)
            case .clearPlayback(let fade):
                graph.clearPlayback(fade: fade)
            }
        }
    }

    private func onSocketClosed(_ err: Error?) {
        if metadataWaiter != nil {
            failSetup(ElevenLabsError.closedDuringSetup(err.map { String(describing: $0) } ?? "closed"))
            return
        }
        guard wantConnected else { return }
        // Not resumable: 1000 means the agent ended the conversation; anything else is logged.
        NSLog("ElevenLabs socket closed: %@", err.map { String(describing: $0) } ?? "normal closure")
        teardown()
    }

    private func failSetup(_ err: Error) {
        closeSocket()
        metadataWaiter?.resume(throwing: err)
        metadataWaiter = nil
    }

    private func closeSocket() {
        micGate.socket = nil
        let s = socket
        socket = nil
        s?.close()
    }

    // MARK: - Tick / teardown

    private func startTimer() {
        guard timer == nil, wantConnected else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.updateHz)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let m = graph.read()
        if let m { metricsCb?(m) }
        session.tick(playback: graph.playbackState(), level: m?.level ?? 0, now: clock())
    }

    private func teardown() {
        defer { setSessionUp(false) }
        wantConnected = false
        timer?.cancel()
        timer = nil
        closeSocket()
        metadataWaiter?.resume(throwing: CancellationError())
        metadataWaiter = nil
        graph.stop()
        session.stopped(now: clock())
    }

    /// Mic chunks arrive on the audio thread; only forwarded once the graph is up.
    private final class MicGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _socket: LiveSocket?
        var socket: LiveSocket? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _socket
            }
            set {
                lock.lock()
                _socket = newValue
                lock.unlock()
            }
        }

        private var _muted = false
        var muted: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _muted
            }
            set {
                lock.lock()
                _muted = newValue
                lock.unlock()
            }
        }

        func send(_ text: String) { socket?.send(text) }
    }
}

public enum ElevenLabsError: Error, Equatable {
    case missingCredential
    case metadataTimeout
    case closedDuringSetup(String)
    /// The agent is configured for a non-PCM *input* format; this source sends PCM only.
    case unsupportedInputFormat(String)
}
