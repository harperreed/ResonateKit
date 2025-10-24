// ABOUTME: Example CLI player demonstrating ResonateKit usage
// ABOUTME: Connects to a Resonate server and plays synchronized audio

import Foundation
import ResonateKit

/// Simple CLI player for Resonate Protocol
@MainActor
final class CLIPlayer {
    private var client: ResonateClient?
    private var eventTask: Task<Void, Never>?

    func run(serverURL: String, clientName: String) async throws {
        print("🎵 Resonate CLI Player")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Parse URL
        guard let url = URL(string: serverURL) else {
            print("❌ Invalid server URL: \(serverURL)")
            throw CLIPlayerError.invalidURL
        }

        // Create player configuration
        let config = PlayerConfiguration(
            bufferCapacity: 2_097_152,  // 2MB buffer
            supportedFormats: [
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16),
                AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 44100, bitDepth: 16),
                AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48000, bitDepth: 16),
                AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48000, bitDepth: 24)
            ]
        )

        // Create client
        let client = ResonateClient(
            clientId: UUID().uuidString,
            name: clientName,
            roles: [.player],
            playerConfig: config
        )
        self.client = client

        // Start event monitoring
        eventTask = Task {
            await monitorEvents(client: client)
        }

        // Connect to server
        print("📡 Connecting to \(url)...")
        try await client.connect(to: url)

        print("✅ Connected! Listening for audio streams...")
        print("")
        print("Commands:")
        print("  v <0-100>  - Set volume")
        print("  m          - Toggle mute")
        print("  q          - Quit")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Run command loop
        await runCommandLoop(client: client)
    }

    private func monitorEvents(client: ResonateClient) async {
        for await event in client.events {
            switch event {
            case .serverConnected(let info):
                print("🔗 Connected to server: \(info.name) (v\(info.version))")

            case .streamStarted(let format):
                print("▶️  Stream started:")
                print("   Codec: \(format.codec.rawValue)")
                print("   Sample rate: \(format.sampleRate) Hz")
                print("   Channels: \(format.channels)")
                print("   Bit depth: \(format.bitDepth) bits")

            case .streamEnded:
                print("⏹  Stream ended")

            case .groupUpdated(let info):
                if let state = info.playbackState {
                    print("📻 Group: \(info.groupName) [\(state)]")
                }

            case .artworkReceived(let channel, let data):
                print("🖼  Artwork received on channel \(channel): \(data.count) bytes")

            case .visualizerData(let data):
                print("📊 Visualizer data: \(data.count) bytes")

            case .error(let message):
                print("⚠️  Error: \(message)")
            }
        }
    }

    private func runCommandLoop(client: ResonateClient) async {
        print("> ", terminator: "")
        fflush(stdout)

        while let line = readLine() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                print("> ", terminator: "")
                fflush(stdout)
                continue
            }

            let parts = line.split(separator: " ")
            guard let command = parts.first else { continue }

            switch command.lowercased() {
            case "q", "quit", "exit":
                print("👋 Disconnecting...")
                await client.disconnect()
                return

            case "v", "volume":
                guard parts.count > 1, let volume = Float(parts[1]) else {
                    print("Usage: v <0-100>")
                    continue
                }
                await client.setVolume(volume / 100.0)
                print("🔊 Volume set to \(Int(volume))%")

            case "m", "mute":
                // Toggle mute (we'd need to track state for this)
                await client.setMute(true)
                print("🔇 Muted")

            case "u", "unmute":
                await client.setMute(false)
                print("🔊 Unmuted")

            default:
                print("Unknown command: \(command)")
            }

            print("> ", terminator: "")
            fflush(stdout)
        }
    }

    deinit {
        eventTask?.cancel()
        // Disconnect client on cleanup
        Task { @MainActor [weak client] in
            await client?.disconnect()
        }
    }
}

enum CLIPlayerError: Error {
    case invalidURL
}

// Main entry point
@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments

        // Determine server URL
        let serverURL: String
        let clientName = args.count > 2 ? args[2] : args.count > 1 ? args[1] : "CLI Player"

        if args.count > 1 && args[1].starts(with: "ws://") {
            // Direct URL provided
            serverURL = args[1]
        } else {
            // Discover servers
            print("🔍 Discovering Resonate servers...")
            let servers = await ResonateClient.discoverServers()

            if servers.isEmpty {
                print("❌ No Resonate servers found on network")
                print("💡 Usage: CLIPlayer [ws://server:8927] [client-name]")
                exit(1)
            }

            print("📡 Found \(servers.count) server(s):")
            for (index, server) in servers.enumerated() {
                print("  [\(index + 1)] \(server.name) - \(server.url)")
            }

            // Auto-select first server
            let selected = servers[0]
            print("✅ Connecting to: \(selected.name)")
            serverURL = selected.url.absoluteString
        }

        let player = CLIPlayer()

        do {
            try await player.run(serverURL: serverURL, clientName: clientName)
        } catch {
            print("❌ Fatal error: \(error)")
            exit(1)
        }
    }
}
