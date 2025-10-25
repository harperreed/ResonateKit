// ABOUTME: Simple non-interactive test client for ResonateKit
// ABOUTME: Connects and runs for a specified duration without requiring user input

import Foundation
import ResonateKit

@main
struct SimpleTest {
    static func main() async {
        print("🎵 Simple ResonateKit Test")
        print("━━━━━━━━━━━━━━━━━━━━━━━━")

        let args = CommandLine.arguments
        let serverURL = args.count > 1 ? args[1] : "ws://localhost:8927/resonate"
        let duration = args.count > 2 ? Int(args[2]) ?? 30 : 30

        guard let url = URL(string: serverURL) else {
            print("❌ Invalid URL: \(serverURL)")
            exit(1)
        }

        print("Connecting to: \(serverURL)")
        print("Duration: \(duration) seconds")
        print("")

        // Create player configuration (PCM only)
        let config = PlayerConfiguration(
            bufferCapacity: 2_097_152,
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16),
            ]
        )

        // Create client
        let client = ResonateClient(
            clientId: UUID().uuidString,
            name: "Simple Test Client",
            roles: [.player],
            playerConfig: config
        )

        // Monitor events in background
        Task {
            for await event in client.events {
                switch event {
                case .serverConnected(let info):
                    print("🔗 Connected to: \(info.name) (v\(info.version))")
                case .streamStarted(let format):
                    print("▶️  Stream: \(format.codec.rawValue) \(format.sampleRate)Hz \(format.channels)ch \(format.bitDepth)bit")
                case .streamEnded:
                    print("⏹  Stream ended")
                case .groupUpdated(let info):
                    if let state = info.playbackState {
                        print("📻 Group \(info.groupName): \(state)")
                    }
                case .error(let message):
                    print("⚠️  Error: \(message)")
                default:
                    break
                }
            }
        }

        // Connect
        do {
            try await client.connect(to: url)
            print("✅ Connected!")
            print("")

            // Run for specified duration
            try await Task.sleep(for: .seconds(duration))

            print("")
            print("⏱️  Test duration complete")
            await client.disconnect()
            print("👋 Disconnected")

        } catch {
            print("❌ Error: \(error)")
            exit(1)
        }
    }
}
