import Foundation

// The WebSocket seam shared by the native vendor sources (Gemini Live,
// ElevenLabs). Foundation only, so it lives in SinuaVoice and pulls in no
// network dependency.

/// The one thing the vendor sources need from a WebSocket. `send` is safe from
/// any thread (the mic chunks come from the audio thread).
public protocol LiveSocket: AnyObject, Sendable {
    func send(_ text: String)
    func close()
}

/// Opens sockets; callbacks arrive on the main thread. Tests inject their own.
/// `protocols` are WebSocket subprotocols (ElevenLabs' `convai`).
public protocol LiveSocketFactory {
    func open(
        url: URL, headers: [String: String], protocols: [String],
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> LiveSocket
}

extension LiveSocketFactory {
    public func open(
        url: URL, headers: [String: String],
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> LiveSocket {
        open(url: url, headers: headers, protocols: [], onText: onText, onClose: onClose)
    }
}

/// `URLSessionWebSocketTask` -- no dependency, and unlike a browser WebSocket
/// it can set request headers, so credentials never go in the URL.
public struct URLSessionLiveSocketFactory: LiveSocketFactory {
    public init() {}

    public func open(
        url: URL, headers: [String: String], protocols: [String],
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> LiveSocket {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // A URLRequest-based task can't take `protocols:`; the header is the same thing on the wire.
        if !protocols.isEmpty {
            req.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let socket = URLSessionLiveSocket(request: req, onText: onText, onClose: onClose)
        socket.start()
        return socket
    }
}

final class URLSessionLiveSocket: LiveSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onText: (String) -> Void
    private let onClose: (Error?) -> Void
    private let lock = NSLock()
    private var closed = false

    init(request: URLRequest, onText: @escaping (String) -> Void, onClose: @escaping (Error?) -> Void) {
        task = URLSession.shared.webSocketTask(with: request)
        // Gemini's audio frames are large; the default 1 MB cap is fine, but be explicit.
        task.maximumMessageSize = 16 * 1024 * 1024
        self.onText = onText
        self.onClose = onClose
    }

    func start() {
        task.resume()
        receive()
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }  // a failed send surfaces as a receive error -> onClose
    }

    func close() {
        guard markClosed() else { return }
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                let text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)  // Gemini sends JSON in binary frames too
                @unknown default: text = nil
                }
                if let text { DispatchQueue.main.async { if !self.isClosed { self.onText(text) } } }
                self.receive()
            case .failure(let err):
                guard self.markClosed() else { return }
                DispatchQueue.main.async { self.onClose(err) }
            }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// True the first time only.
    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}
