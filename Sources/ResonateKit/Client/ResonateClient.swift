// ABOUTME: Main orchestrator for Resonate protocol client
// ABOUTME: Manages WebSocket connection, message handling, clock sync, and audio playback

import Foundation
import Observation

/// Main Resonate client
@Observable
public final class ResonateClient {
    // Configuration
    private let clientId: String
    private let name: String
    private let roles: Set<ClientRole>
    private let playerConfig: PlayerConfiguration?

    // State
    public private(set) var connectionState: ConnectionState = .disconnected

    // Dependencies
    private var transport: WebSocketTransport?
    private var clockSync: ClockSynchronizer?
    private var bufferManager: BufferManager?
    private var audioPlayer: AudioPlayer?

    // Task management
    private var messageLoopTask: Task<Void, Never>?
    private var clockSyncTask: Task<Void, Never>?

    // Event stream
    private let eventsContinuation: AsyncStream<ClientEvent>.Continuation
    public let events: AsyncStream<ClientEvent>

    public init(
        clientId: String,
        name: String,
        roles: Set<ClientRole>,
        playerConfig: PlayerConfiguration? = nil
    ) {
        self.clientId = clientId
        self.name = name
        self.roles = roles
        self.playerConfig = playerConfig

        (events, eventsContinuation) = AsyncStream.makeStream()

        // Validate configuration
        if roles.contains(.player) {
            precondition(playerConfig != nil, "Player role requires playerConfig")
        }
    }

    deinit {
        eventsContinuation.finish()
    }

    /// Connect to Resonate server
    @MainActor
    public func connect(to url: URL) async throws {
        // Prevent multiple connections
        guard connectionState == .disconnected else {
            return
        }

        connectionState = .connecting

        // Create dependencies
        let transport = WebSocketTransport(url: url)
        let clockSync = ClockSynchronizer()

        self.transport = transport
        self.clockSync = clockSync

        // Create buffer manager and audio player if player role
        if roles.contains(.player), let playerConfig = playerConfig {
            let bufferManager = BufferManager(capacity: playerConfig.bufferCapacity)
            let audioPlayer = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

            self.bufferManager = bufferManager
            self.audioPlayer = audioPlayer
        }

        // Connect WebSocket
        try await transport.connect()

        // Send client/hello
        try await sendClientHello()

        // Start message loop
        messageLoopTask = Task {
            await runMessageLoop()
        }

        // Start clock sync
        clockSyncTask = Task {
            await runClockSync()
        }

        // Update state (will be set to .connected when server/hello received)
    }

    /// Disconnect from server
    @MainActor
    public func disconnect() async {
        // Cancel tasks
        messageLoopTask?.cancel()
        clockSyncTask?.cancel()
        messageLoopTask = nil
        clockSyncTask = nil

        // Stop audio
        if let audioPlayer = audioPlayer {
            await audioPlayer.stop()
        }

        // Disconnect transport
        await transport?.disconnect()

        // Clean up
        transport = nil
        clockSync = nil
        bufferManager = nil
        audioPlayer = nil

        connectionState = .disconnected
        eventsContinuation.finish()
    }

    @MainActor
    private func sendClientHello() async throws {
        guard let transport = transport else {
            throw ResonateClientError.notConnected
        }

        // Build player support if player role
        var playerSupport: PlayerSupport?
        if roles.contains(.player), let playerConfig = playerConfig {
            playerSupport = PlayerSupport(
                supportedFormats: playerConfig.supportedFormats,
                bufferCapacity: playerConfig.bufferCapacity,
                supportedCommands: [.volume, .mute]
            )
        }

        let payload = ClientHelloPayload(
            clientId: clientId,
            name: name,
            deviceInfo: DeviceInfo.current,
            version: 1,
            supportedRoles: Array(roles),
            playerSupport: playerSupport,
            artworkSupport: roles.contains(.artwork) ? ArtworkSupport() : nil,
            visualizerSupport: roles.contains(.visualizer) ? VisualizerSupport() : nil
        )

        let message = ClientHelloMessage(payload: payload)
        try await transport.send(message)
    }

    @MainActor
    private func runMessageLoop() async {
        // TODO: Implement in next task
    }

    @MainActor
    private func runClockSync() async {
        // TODO: Implement in next task
    }
}

public enum ClientEvent: Sendable {
    case serverConnected(ServerInfo)
    case streamStarted(AudioFormatSpec)
    case streamEnded
    case groupUpdated(GroupInfo)
    case artworkReceived(channel: Int, data: Data)
    case visualizerData(Data)
    case error(String)
}

public struct ServerInfo: Sendable {
    public let serverId: String
    public let name: String
    public let version: Int
}

public struct GroupInfo: Sendable {
    public let groupId: String
    public let groupName: String
    public let playbackState: String?
}

public enum ResonateClientError: Error {
    case notConnected
    case unsupportedCodec(String)
    case audioSetupFailed
}
