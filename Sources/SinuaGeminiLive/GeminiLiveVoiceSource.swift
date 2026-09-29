import Foundation
import SinuaVoice

/// `VoiceSource` for Gemini Live over its raw WebSocket -- the native mirror of
/// the Web `GeminiLiveVoiceSource` (packages/voice/src/GeminiLiveVoiceSource.ts).
/// Protocol and state rules live in `GeminiLiveSession`, the playback-timeline
/// gate in `PcmAudioGraph` (both SinuaVoice, unit-tested); this class wires
/// them to a socket and an audio device. Callbacks arrive on the main thread.
///
/// Order: socket + `setupComplete` first, then the mic permission, then the
/// audio -- a bad credential fails without a prompt and without opening the mic.
/// Mic PCM16 @ 16 kHz goes up; the model's PCM16 @ 24 kHz is scheduled on the
/// player; `speaking` and the metrics follow what has actually played.
/// Session resumption + reconnect on `goAway` or an unexpected close
/// (3 attempts, 500 ms apart), as on Web.
///
/// Credentials: the shared contract (`CredentialSource`, docs/audio-pipeline.md).
/// Only an `auth_tokens/…` ephemeral token is accepted, minted by your backend
/// (`mintGeminiLiveCredential` in `@sinua/voice/server`, or `npx @sinua/voice
/// dev-proxy`), which locks the model, voice and instructions. It travels as
/// `Authorization: Token …`, never in the URL. With `credentialUrl` or a provider,
/// every reconnect resumes the session with a **new** token (single-use by
/// default). A raw API key is refused.
///
/// Not verified against the live API yet (docs/audio-pipeline.md).
public final class GeminiLiveVoiceSource: VoiceSource {
    public static let updateHz = 30.0
    static let setupTimeout: TimeInterval = 15
    static let reconnectAttempts = 3
    static let reconnectDelay: TimeInterval = 0.5

    private let credentials: CredentialSource
    /// A relay's URL (or tests'); the `Authorization` header still comes from the token.
    private let endpointOverride: GeminiLiveSession.Endpoint?
    private var endpoint: GeminiLiveSession.Endpoint?
    private let session: GeminiLiveSession
    private let graph: PcmAudioGraph
    private let socketFactory: LiveSocketFactory
    private let requestPermission: () async -> Bool

    // Main-thread state.
    private var socket: LiveSocket?
    private let micGate = MicGate()
    private var setupWaiter: CheckedContinuation<Void, Error>?
    private var wantConnected = false
    private var reconnecting = false
    private var audioStarted = false
    private var pendingAudio: [([Float], Int)] = []
    private var timer: DispatchSourceTimer?
    private var metricsCb: ((VoiceMetrics) -> Void)?

    /// - Parameters:
    ///   - credential: where tokens come from -- `.url(…)`, `.provider { … }`, or `.value(…)` for one session.
    ///   - instructions: deprecated -- set them when your backend mints the token, which locks them.
    ///   - endpoint: override the Google URL (a relay your backend runs, or tests); the
    ///     token's `Authorization` header is still added.
    ///   - device: the audio stack; `AVPcmAudioDevice()` (echo-cancelled mic + player) by default.
    public init(
        credential: CredentialSource,
        model: String = GeminiLiveSession.defaultModel,
        instructions: String? = nil,
        endpoint: GeminiLiveSession.Endpoint? = nil,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission
    ) {
        credentials = credential
        endpointOverride = endpoint
        if instructions != nil {
            NSLog(
                "GeminiLiveVoiceSource: `instructions` is deprecated -- set them when your backend mints the token "
                    + "(mintGeminiLiveCredential from @sinua/voice/server), which locks them.")
        }
        session = GeminiLiveSession(model: model, instructions: instructions)
        graph = PcmAudioGraph(device: device)
        self.socketFactory = socketFactory
        self.requestPermission = requestPermission
    }

    /// One fixed token (a pasted `auth_tokens/…`, single session).
    public convenience init(
        credential: String,
        model: String = GeminiLiveSession.defaultModel,
        instructions: String? = nil,
        endpoint: GeminiLiveSession.Endpoint? = nil,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission
    ) {
        self.init(
            credential: .value(credential), model: model, instructions: instructions, endpoint: endpoint,
            device: device, socketFactory: socketFactory, requestPermission: requestPermission)
    }

    /// Your backend's endpoint, answering `{ credential, expiresAt? }`; asked on every (re)connect.
    public convenience init(
        credentialUrl: URL,
        model: String = GeminiLiveSession.defaultModel,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission
    ) {
        self.init(
            credential: .url(credentialUrl), model: model, device: device, socketFactory: socketFactory,
            requestPermission: requestPermission)
    }

    private var connectionCb: ((Bool) -> Void)?
    private var sessionUp = false

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { session.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { session.onInterrupt = cb }
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
        // Before the socket, before the permission prompt, before the mic: a
        // missing or refused credential must not open a device or a connection.
        try await refreshEndpoint()
        await MainActor.run {
            wantConnected = true
            session.reset()
            session.connecting()
        }
        do {
            // Authenticate first: a bad or expired credential must fail before the
            // permission prompt and before the mic opens (LiveKit's order; Web
            // starts audio first because its rates are fixed -- not worth the mic).
            try await openSocket()
            guard await requestPermission() else { throw VoiceSourceError.permissionDenied }
            try await MainActor.run {
                let gate = micGate
                try graph.start(inputRate: GeminiLiveSession.inputRate, outputRate: GeminiLiveSession.outputRate) {
                    samples in
                    let out = gate.muted ? [Float](repeating: 0, count: samples.count) : samples
                    gate.send(GeminiLiveSession.micMessage(out))
                }
                audioStarted = true
                for (samples, rate) in pendingAudio { graph.enqueue(samples, rate: rate) }
                pendingAudio = []
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

    // MARK: - Socket

    /// A token for the next socket; an `auth_tokens/…` name is the only accepted shape.
    private func refreshEndpoint() async throws {
        let token: String
        do {
            token = try await credentials.resolve(vendor: "GeminiLiveVoiceSource").credential
        } catch CredentialError.fatal(let m) where m.hasSuffix("a credential is required") {
            throw GeminiLiveError.missingCredential
        }
        try InsecureCredential.check(
            vendor: "GeminiLiveVoiceSource", isEphemeral: InsecureCredential.isGeminiEphemeral(token),
            ephemeralShape: InsecureCredential.geminiShape)
        let auth = GeminiLiveSession.endpoint(credential: token)
        let e =
            endpointOverride.map {
                GeminiLiveSession.Endpoint(url: $0.url, headers: $0.headers.merging(auth.headers) { _, token in token })
            } ?? auth
        await MainActor.run { endpoint = e }
    }

    /// Opens the socket, sends `setup`, returns on `setupComplete`.
    private func openSocket() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [self] in
                guard wantConnected else { return cont.resume(throwing: CancellationError()) }
                setupWaiter = cont
                var opened: LiveSocket?
                guard let endpoint else { return cont.resume(throwing: GeminiLiveError.missingCredential) }
                opened = socketFactory.open(
                    url: endpoint.url, headers: endpoint.headers,
                    onText: { [weak self] text in self?.onText(text) },
                    onClose: { [weak self] err in
                        guard let self, let s = opened, s === self.socket else { return }
                        self.onSocketClosed(err)
                    })
                socket = opened
                opened?.send(session.setupMessage())
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self] in
                    guard let self, let s = opened, s === self.socket, self.setupWaiter != nil else { return }
                    self.failSetup(GeminiLiveError.setupTimeout)
                }
            }
        }
    }

    private func onText(_ text: String) {
        for action in session.handle(text, playback: graph.playbackState()) {
            switch action {
            case .setupComplete:
                // A reconnect; the first connect sets this after audio starts.
                if audioStarted { micGate.socket = socket }
                setupWaiter?.resume()
                setupWaiter = nil
            case .enqueue(let samples, let rate):
                // Model audio between setupComplete and the audio graph starting is held, not dropped.
                if audioStarted { graph.enqueue(samples, rate: rate) } else { pendingAudio.append((samples, rate)) }
            case .clearPlayback(let fade):
                pendingAudio = []
                graph.clearPlayback(fade: fade)
            case .reconnect(let reason):
                Task { await reconnect(reason) }
            case .serverError(let msg):
                NSLog("Gemini Live error message: %@", msg)
            }
        }
    }

    private func onSocketClosed(_ err: Error?) {
        if setupWaiter != nil {
            failSetup(GeminiLiveError.closedDuringSetup(err.map { String(describing: $0) } ?? "closed"))
            return
        }
        guard wantConnected else { return }
        Task { await reconnect("close") }
    }

    private func failSetup(_ err: Error) {
        closeSocket()
        setupWaiter?.resume(throwing: err)
        setupWaiter = nil
    }

    private func closeSocket() {
        micGate.socket = nil
        let s = socket
        socket = nil
        s?.close()
    }

    private func reconnect(_ reason: String) async {
        let proceed = await MainActor.run { () -> Bool in
            guard !reconnecting, wantConnected else { return false }
            reconnecting = true
            closeSocket()
            graph.clearPlayback(fade: false)
            session.connecting()
            return true
        }
        guard proceed else { return }
        for attempt in 1...Self.reconnectAttempts {
            guard await MainActor.run(body: { wantConnected }) else { break }
            do {
                // A token is single-use by default: resume with a new one when the
                // caller can mint it (a pasted token is tried as is).
                if credentials.canRefresh { try await refreshEndpoint() }
                try await openSocket()
                await MainActor.run { reconnecting = false }
                return
            } catch {
                NSLog(
                    "Gemini Live reconnect %d/%d after %@ failed: %@", attempt, Self.reconnectAttempts, reason,
                    String(describing: error))
                if (error as? CredentialError)?.isFatal == true || error is GeminiLiveError { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1e9))
            }
        }
        await MainActor.run {
            reconnecting = false
            if wantConnected {
                NSLog("Gemini Live: gave up reconnecting")
                disconnect()
            }
        }
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
        if let m = graph.read() { metricsCb?(m) }
        if !reconnecting { session.tick(playback: graph.playbackState()) }
    }

    private func teardown() {
        defer { setSessionUp(false) }
        wantConnected = false
        timer?.cancel()
        timer = nil
        closeSocket()
        setupWaiter?.resume(throwing: CancellationError())
        setupWaiter = nil
        audioStarted = false
        pendingAudio = []
        graph.stop()
        session.reset()  // idle; a fresh connect() starts a fresh session
    }

    /// Mic chunks arrive on the audio thread; only forwarded after `setupComplete`.
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

public enum GeminiLiveError: Error, Equatable {
    case missingCredential
    case setupTimeout
    case closedDuringSetup(String)
}
