// ABOUTME: WebSocket transport layer for Resonate protocol communication
// ABOUTME: Provides AsyncStreams for text (JSON) and binary messages

import Foundation

/// WebSocket transport for Resonate protocol
public actor WebSocketTransport {
    private var webSocket: URLSessionWebSocketTask?
    private let url: URL

    private let textMessageContinuation: AsyncStream<String>.Continuation
    private let binaryMessageContinuation: AsyncStream<Data>.Continuation

    private var receiveTask: Task<Void, Never>?

    /// Stream of incoming text messages (JSON)
    public nonisolated let textMessages: AsyncStream<String>

    /// Stream of incoming binary messages (audio, artwork, etc.)
    public nonisolated let binaryMessages: AsyncStream<Data>

    public init(url: URL) {
        self.url = url
        (textMessages, textMessageContinuation) = AsyncStream.makeStream()
        (binaryMessages, binaryMessageContinuation) = AsyncStream.makeStream()
    }

    /// Connect to the WebSocket server
    /// - Throws: TransportError if already connected
    public func connect() async throws {
        // Prevent multiple connections
        guard webSocket == nil else {
            throw TransportError.alreadyConnected
        }

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()

        // Start receive loops in a single structured task
        receiveTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.receiveTextMessages() }
                group.addTask { await self.receiveBinaryMessages() }
            }
        }
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
        try await webSocket.send(.string(text))
    }

    /// Send a binary message
    public func sendBinary(_ data: Data) async throws {
        guard let webSocket = webSocket else {
            throw TransportError.notConnected
        }
        try await webSocket.send(.data(data))
    }

    /// Disconnect from server
    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        textMessageContinuation.finish()
        binaryMessageContinuation.finish()
    }

    deinit {
        // Clean up continuations if actor is deinitialized
        textMessageContinuation.finish()
        binaryMessageContinuation.finish()
    }

    private func receiveTextMessages() async {
        // Check connection status on each iteration
        while !Task.isCancelled {
            guard let webSocket = webSocket else { break }

            do {
                let message = try await webSocket.receive()
                if case .string(let text) = message {
                    textMessageContinuation.yield(text)
                }
            } catch {
                textMessageContinuation.finish()
                break
            }
        }
    }

    private func receiveBinaryMessages() async {
        // Check connection status on each iteration
        while !Task.isCancelled {
            guard let webSocket = webSocket else { break }

            do {
                let message = try await webSocket.receive()
                if case .data(let data) = message {
                    binaryMessageContinuation.yield(data)
                }
            } catch {
                binaryMessageContinuation.finish()
                break
            }
        }
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
}
