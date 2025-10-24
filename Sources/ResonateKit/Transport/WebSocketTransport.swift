// ABOUTME: WebSocket transport layer for Resonate protocol communication
// ABOUTME: Provides AsyncStreams for text (JSON) and binary messages

import Foundation
import Starscream

// Delegate to handle WebSocket events and receiving
private final class StarscreamDelegate: WebSocketDelegate, @unchecked Sendable {
    let textContinuation: AsyncStream<String>.Continuation
    let binaryContinuation: AsyncStream<Data>.Continuation
    var connectionContinuation: CheckedContinuation<Void, Error>?

    init(textContinuation: AsyncStream<String>.Continuation, binaryContinuation: AsyncStream<Data>.Continuation) {
        self.textContinuation = textContinuation
        self.binaryContinuation = binaryContinuation
        print("[STARSCREAM] Delegate initialized")
    }

    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        print("[STARSCREAM] didReceive called with event: \(event)")
        switch event {
        case .connected(let headers):
            print("[STARSCREAM] WebSocket connected with headers: \(headers)")
            connectionContinuation?.resume()
            connectionContinuation = nil

        case .disconnected(let reason, let code):
            print("[STARSCREAM] WebSocket disconnected: \(reason) (code: \(code))")
            textContinuation.finish()
            binaryContinuation.finish()

        case .text(let string):
            print("[STARSCREAM] Received text message: \(string.prefix(100))...")
            textContinuation.yield(string)

        case .binary(let data):
            print("[STARSCREAM] Received binary message: \(data.count) bytes")
            binaryContinuation.yield(data)

        case .ping(_):
            print("[STARSCREAM] Received ping")

        case .pong(_):
            print("[STARSCREAM] Received pong")

        case .viabilityChanged(let isViable):
            print("[STARSCREAM] Viability changed: \(isViable)")

        case .reconnectSuggested(let shouldReconnect):
            print("[STARSCREAM] Reconnect suggested: \(shouldReconnect)")

        case .cancelled:
            print("[STARSCREAM] WebSocket cancelled")
            textContinuation.finish()
            binaryContinuation.finish()

        case .error(let error):
            print("[STARSCREAM] WebSocket error: \(String(describing: error))")
            if let continuation = connectionContinuation {
                continuation.resume(throwing: TransportError.connectionFailed)
                connectionContinuation = nil
            }
            textContinuation.finish()
            binaryContinuation.finish()

        case .peerClosed:
            print("[STARSCREAM] Peer closed connection")
            textContinuation.finish()
            binaryContinuation.finish()
        }
    }
}

/// WebSocket transport for Resonate protocol
public actor WebSocketTransport {
    private nonisolated let delegate: StarscreamDelegate
    private var webSocket: WebSocket?
    private let url: URL

    /// Stream of incoming text messages (JSON)
    public nonisolated let textMessages: AsyncStream<String>

    /// Stream of incoming binary messages (audio, artwork, etc.)
    public nonisolated let binaryMessages: AsyncStream<Data>

    public init(url: URL) {
        // Ensure URL has proper WebSocket path if not specified
        if url.path.isEmpty || url.path == "/" {
            // Append recommended Resonate endpoint path
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            self.url = components.url ?? url
        } else {
            self.url = url
        }

        // Create streams and pass continuations to delegate
        let (textStream, textCont) = AsyncStream<String>.makeStream()
        let (binaryStream, binaryCont) = AsyncStream<Data>.makeStream()

        self.textMessages = textStream
        self.binaryMessages = binaryStream
        self.delegate = StarscreamDelegate(textContinuation: textCont, binaryContinuation: binaryCont)
    }

    /// Connect to the WebSocket server
    /// - Throws: TransportError if already connected or connection fails
    public func connect() async throws {
        // Prevent multiple connections
        guard webSocket == nil else {
            throw TransportError.alreadyConnected
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        // Create socket with delegate callbacks on background queue
        // Note: Cannot use DispatchQueue.main in CLI apps without RunLoop
        let socket = WebSocket(request: request)
        socket.callbackQueue = DispatchQueue(label: "com.resonate.websocket", qos: .userInitiated)
        socket.delegate = delegate

        print("[TRANSPORT] Delegate set: \(socket.delegate != nil)")

        self.webSocket = socket

        print("[TRANSPORT] Connecting to \(url)...")

        // Wait for connection to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.connectionContinuation = continuation
            socket.connect()
            print("[TRANSPORT] Connection initiated, waiting for connected event...")
        }

        print("[TRANSPORT] Connection established!")
    }

    /// Check if currently connected
    public var isConnected: Bool {
        return webSocket != nil
    }

    /// Send a text message (JSON)
    public func send<T: ResonateMessage>(_ message: T) async throws {
        guard let webSocket = webSocket else {
            throw TransportError.notConnected
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.encodingFailed
        }
        print("[TRANSPORT] Sending: \(text)")
        webSocket.write(string: text)
    }

    /// Send a binary message
    public func sendBinary(_ data: Data) async throws {
        guard let webSocket = webSocket else {
            throw TransportError.notConnected
        }
        webSocket.write(data: data)
    }

    /// Disconnect from server
    public func disconnect() async {
        webSocket?.disconnect()
        webSocket = nil
    }
}

/// Errors that can occur during WebSocket transport
public enum TransportError: Error {
    /// Failed to encode message to UTF-8 string
    case encodingFailed

    /// WebSocket is not connected - call connect() first
    case notConnected

    /// Already connected - call disconnect() before reconnecting
    case alreadyConnected

    /// Connection failed during handshake
    case connectionFailed
}
