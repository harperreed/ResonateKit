import Testing
@testable import ResonateKit
import Foundation

@Suite("WebSocket Transport Tests")
struct WebSocketTransportTests {
    @Test("Creates AsyncStreams for messages")
    func testStreamCreation() async {
        let url = URL(string: "ws://localhost:8927/resonate")!
        let transport = WebSocketTransport(url: url)

        // Verify streams exist
        var textIterator = transport.textMessages.makeAsyncIterator()
        var binaryIterator = transport.binaryMessages.makeAsyncIterator()

        // Streams should be ready but have no data yet
        // (This is a basic structure test - full WebSocket testing requires mock server)
    }
}
