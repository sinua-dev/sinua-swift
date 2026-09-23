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
/// Credentials: a **public** agent's `agent_id` (no secret involved), or a
/// `wss://…` **signed URL** for a private agent, minted by your backend
/// (`GET /v1/convai/conversation/get-signed-url`, valid 15 minutes).
///
/// Not verified against the live service yet (docs/audio-pipeline.md).
public final class ElevenLabsVoiceSource: VoiceSource {
    public static let updateHz = 30.0
    static let metadataTimeout: TimeInterval = 15

    private let url: URL?
    private let overrides: [String: Any]?
    private let session = ElevenLabsSession()
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
    ///   - credential: a public agent id, or a `wss://` signed URL.
    ///   - overrides: `conversation_config_override` (if the agent allows overrides).
    ///   - endpoint: override the URL (a relay, or tests); the credential is ignored then.
    public init(
        credential: String,
        overrides: [String: Any]? = nil,
        endpoint: URL? = nil,
        device: PcmAudioDevice = AVPcmAudioDevice(),
        socketFactory: LiveSocketFactory = URLSessionLiveSocketFactory(),
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        url = endpoint ?? (c.isEmpty ? nil : ElevenLabsSession.endpoint(credential: c))
        self.overrides = overrides
        graph = PcmAudioGraph(device: device)
        self.socketFactory = socketFactory
        self.requestPermission = requestPermission
        self.clock = clock
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { session.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { session.onInterrupt = cb }

    public func connect() async throws {
        guard let url else { throw ElevenLabsError.missingCredential }
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
                    gate.send(ElevenLabsSession.micMessage(samples))
                }
                apply(session.graphStarted(output: output, now: clock()))
                micGate.socket = socket
                startTimer()
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
        if let m = graph.read() { metricsCb?(m) }
        session.tick(playback: graph.playbackState(), now: clock())
    }

    private func teardown() {
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
