// ABOUTME: Main orchestrator for Resonate protocol client
// ABOUTME: Manages WebSocket connection, message handling, clock sync, and audio playback

import Foundation
import Observation

/// Main Resonate client
@Observable
@MainActor
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

    private func runMessageLoop() async {
        guard let transport = transport else { return }

        await withTaskGroup(of: Void.self) { group in
            // Text message handler
            group.addTask { [weak self] in
                guard let self = self else { return }

                for await text in transport.textMessages {
                    await self.handleTextMessage(text)
                }
            }

            // Binary message handler
            group.addTask { [weak self] in
                guard let self = self else { return }

                for await data in transport.binaryMessages {
                    await self.handleBinaryMessage(data)
                }
            }
        }
    }

    private func runClockSync() async {
        guard let transport = transport else { return }

        while !Task.isCancelled {
            // Send client/time every 5 seconds
            do {
                let now = getCurrentMicroseconds()

                let payload = ClientTimePayload(clientTransmitted: now)
                let message = ClientTimeMessage(payload: payload)

                try await transport.send(message)
            } catch {
                // Connection lost
                break
            }

            // Wait 5 seconds
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func handleTextMessage(_ text: String) async {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let data = text.data(using: .utf8) else {
            return
        }

        // Try to decode message type
        // Note: In production, we'd use a discriminated union decoder
        // For now, try each message type

        if let message = try? decoder.decode(ServerHelloMessage.self, from: data) {
            await handleServerHello(message)
        } else if let message = try? decoder.decode(ServerTimeMessage.self, from: data) {
            await handleServerTime(message)
        } else if let message = try? decoder.decode(StreamStartMessage.self, from: data) {
            await handleStreamStart(message)
        } else if let message = try? decoder.decode(StreamEndMessage.self, from: data) {
            await handleStreamEnd(message)
        } else if let message = try? decoder.decode(GroupUpdateMessage.self, from: data) {
            await handleGroupUpdate(message)
        }
    }

    private func handleBinaryMessage(_ data: Data) async {
        guard let message = BinaryMessage(data: data) else {
            return
        }

        switch message.type {
        case .audioChunk:
            await handleAudioChunk(message)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            let channel = Int(message.type.rawValue - 4)
            eventsContinuation.yield(.artworkReceived(channel: channel, data: message.data))

        case .visualizerData:
            eventsContinuation.yield(.visualizerData(message.data))
        }
    }

    private func handleServerHello(_ message: ServerHelloMessage) {
        connectionState = .connected

        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version
        )

        eventsContinuation.yield(.serverConnected(info))
    }

    private func handleServerTime(_ message: ServerTimeMessage) async {
        guard let clockSync = clockSync else { return }

        let now = getCurrentMicroseconds()

        await clockSync.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: now
        )
    }

    private func handleStreamStart(_ message: StreamStartMessage) async {
        guard let playerInfo = message.payload.player else { return }
        guard let audioPlayer = audioPlayer else { return }

        // Parse codec
        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            connectionState = .error("Unsupported codec: \(playerInfo.codec)")
            return
        }

        let format = AudioFormatSpec(
            codec: codec,
            channels: playerInfo.channels,
            sampleRate: playerInfo.sampleRate,
            bitDepth: playerInfo.bitDepth
        )

        // Decode codec header if present
        var codecHeader: Data?
        if let headerBase64 = playerInfo.codecHeader {
            codecHeader = Data(base64Encoded: headerBase64)
        }

        do {
            try await audioPlayer.start(format: format, codecHeader: codecHeader)
            eventsContinuation.yield(.streamStarted(format))
        } catch {
            connectionState = .error("Failed to start audio: \(error.localizedDescription)")
        }
    }

    private func handleStreamEnd(_ message: StreamEndMessage) async {
        guard let audioPlayer = audioPlayer else { return }

        await audioPlayer.stop()
        eventsContinuation.yield(.streamEnded)
    }

    private func handleGroupUpdate(_ message: GroupUpdateMessage) {
        if let groupId = message.payload.groupId,
           let groupName = message.payload.groupName {
            let info = GroupInfo(
                groupId: groupId,
                groupName: groupName,
                playbackState: message.payload.playbackState
            )

            eventsContinuation.yield(.groupUpdated(info))
        }
    }

    private func handleAudioChunk(_ message: BinaryMessage) async {
        guard let audioPlayer = audioPlayer else { return }

        do {
            try await audioPlayer.enqueue(chunk: message)
        } catch {
            // Log but continue - dropping chunks is acceptable for sync
        }
    }

    private func getCurrentMicroseconds() -> Int64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)

        let nanos = mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
        return Int64(nanos / 1000)
    }

    /// Set playback volume (0.0 to 1.0)
    @MainActor
    public func setVolume(_ volume: Float) async {
        guard let audioPlayer = audioPlayer else { return }
        await audioPlayer.setVolume(volume)
    }

    /// Set mute state
    @MainActor
    public func setMute(_ muted: Bool) async {
        guard let audioPlayer = audioPlayer else { return }
        await audioPlayer.setMute(muted)
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
