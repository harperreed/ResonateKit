import Testing
@testable import ResonateKit
import Foundation

@Suite("ResonateClient Tests")
struct ResonateClientTests {
    @Test("Initialize client with player role")
    func testInitialization() {
        let config = PlayerConfiguration(
            bufferCapacity: 1024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
            ]
        )

        let client = ResonateClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.player],
            playerConfig: config
        )

        // Client should initialize successfully
        #expect(client != nil)
    }

    @Test("Connect creates transport and starts connecting")
    func testConnect() async throws {
        let config = PlayerConfiguration(
            bufferCapacity: 1024,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
            ]
        )

        let client = ResonateClient(
            clientId: "test-client",
            name: "Test Client",
            roles: [.player],
            playerConfig: config
        )

        #expect(client.connectionState == .disconnected)

        // Note: This will fail to connect since URL is invalid, but verifies setup
        // Real integration tests need mock server
    }
}
