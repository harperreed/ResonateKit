// ABOUTME: WebSocket transport layer for Resonate protocol communication
// ABOUTME: Provides AsyncStreams for text (JSON) and binary messages

import Foundation

/// WebSocket transport for Resonate protocol
public actor WebSocketTransport {
    private var webSocket: URLSessionWebSocketTask?
    private let url: URL

    private let textMessageContinuation: AsyncStream<String>.Continuation
    private let binaryMessageContinuation: AsyncStream<Data>.Continuation

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
    public func connect() async throws {
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()

        // Start receive loops in background tasks
        Task { await receiveTextMessages() }
        Task { await receiveBinaryMessages() }
    }

    /// Send a text message (JSON)
    public func send<T: ResonateMessage>(_ message: T) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.encodingFailed
        }
        try await webSocket?.send(.string(text))
    }

    /// Send a binary message
    public func sendBinary(_ data: Data) async throws {
        try await webSocket?.send(.data(data))
    }

    /// Disconnect from server
    public func disconnect() async {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        textMessageContinuation.finish()
        binaryMessageContinuation.finish()
    }

    private func receiveTextMessages() async {
        while let webSocket = webSocket {
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
        while let webSocket = webSocket {
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

public enum TransportError: Error {
    case encodingFailed
    case notConnected
}
