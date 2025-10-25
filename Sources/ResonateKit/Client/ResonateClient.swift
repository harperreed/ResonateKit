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
    private var playerSyncState: String = "synchronized"  // "synchronized" or "error"
    private var isAutoStarting = false  // Prevent multiple simultaneous auto-starts
    private var currentVolume: Float = 1.0
    private var currentMuted: Bool = false

    // Dependencies
    private var transport: WebSocketTransport?
    private var clockSync: ClockSynchronizer?
    private var audioScheduler: AudioScheduler<ClockSynchronizer>?
    private var bufferManager: BufferManager?
    private var audioPlayer: AudioPlayer?

    // Task management
    private var messageLoopTask: Task<Void, Never>?
    private var clockSyncTask: Task<Void, Never>?
    private var schedulerOutputTask: Task<Void, Never>?
    private var schedulerStatsTask: Task<Void, Never>?

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

    /// Discover Resonate servers on the local network
    /// - Parameter timeout: How long to search for servers (default: 3 seconds)
    /// - Returns: Array of discovered servers
    public nonisolated static func discoverServers(timeout: Duration = .seconds(3)) async -> [DiscoveredServer] {
        let discovery = ServerDiscovery()
        await discovery.startDiscovery()

        return await withTaskGroup(of: [DiscoveredServer].self) { group in
            var latestServers: [DiscoveredServer] = []

            // Collect servers for the timeout period
            group.addTask {
                var collected: [DiscoveredServer] = []
                for await discoveredServers in discovery.servers {
                    collected = discoveredServers
                }
                return collected
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(for: timeout)
                await discovery.stopDiscovery()
                return []
            }

            // Wait for all tasks and collect results
            for await result in group {
                if !result.isEmpty {
                    latestServers = result
                }
            }

            return latestServers
        }
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
        let audioScheduler = AudioScheduler(clockSync: clockSync)

        self.transport = transport
        self.clockSync = clockSync
        self.audioScheduler = audioScheduler

        // Create buffer manager and audio player if player role
        if roles.contains(.player), let playerConfig = playerConfig {
            let bufferManager = BufferManager(capacity: playerConfig.bufferCapacity)
            let audioPlayer = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

            self.bufferManager = bufferManager
            self.audioPlayer = audioPlayer

            // Initialize client state from audio player
            self.currentVolume = await audioPlayer.volume
            self.currentMuted = await audioPlayer.muted
        }

        // Connect WebSocket
        try await transport.connect()

        // Send client/hello
        try await sendClientHello()

        // Capture streams before detaching (they're nonisolated)
        let textStream = transport.textMessages
        let binaryStream = transport.binaryMessages

        // Start message loop (detached from MainActor)
        messageLoopTask = Task.detached { [weak self] in
            await self?.runMessageLoop(textStream: textStream, binaryStream: binaryStream)
        }

        // Don't start clock sync yet - wait for server/hello first
        // Initial sync will be triggered in handleServerHello()

        // Start scheduler output consumer (detached from MainActor)
        schedulerOutputTask = Task.detached { [weak self] in
            await self?.runSchedulerOutput()
        }

        // Start scheduler stats logging (detached from MainActor)
        schedulerStatsTask = Task.detached { [weak self] in
            await self?.logSchedulerStats()
        }

        // Update state (will be set to .connected when server/hello received)
    }

    /// Perform initial clock synchronization
    /// Does multiple sync rounds to establish offset and drift before audio starts
    @MainActor
    private func performInitialSync() async throws {
        print("[CLIENT] performInitialSync ENTERED")
        guard let transport = transport, let clockSync = clockSync else {
            print("[CLIENT] performInitialSync EXITING - missing transport or clockSync")
            throw ResonateClientError.notConnected
        }

        print("[CLIENT] Performing initial clock synchronization...")

        // Do 5 quick sync rounds to establish offset and drift
        for i in 0..<5 {
            let now = getCurrentMicroseconds()
            print("[CLIENT] performInitialSync round \(i+1): sending client/time with t1=\(now)")

            let payload = ClientTimePayload(clientTransmitted: now)
            let message = ClientTimeMessage(payload: payload)

            try await transport.send(message)

            // Wait briefly for response (up to 500ms)
            // Note: Response will be processed by message loop
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Wait a bit more to ensure last responses are processed
        try? await Task.sleep(for: .milliseconds(200))

        let offset = await clockSync.statsOffset
        let rtt = await clockSync.statsRtt
        let quality = await clockSync.statsQuality
        print("[CLIENT] Initial clock sync complete: offset=\(offset)μs, rtt=\(rtt)μs, quality=\(quality)")
        print("[CLIENT] performInitialSync EXITED")
    }

    /// Disconnect from server
    @MainActor
    public func disconnect() async {
        // Cancel all tasks
        messageLoopTask?.cancel()
        clockSyncTask?.cancel()
        schedulerOutputTask?.cancel()
        schedulerStatsTask?.cancel()
        messageLoopTask = nil
        clockSyncTask = nil
        schedulerOutputTask = nil
        schedulerStatsTask = nil

        // Stop audio
        if let audioPlayer = audioPlayer {
            await audioPlayer.stop()
        }

        // Finish scheduler permanently on disconnect
        if audioScheduler != nil {
            print("[CLIENT] Finishing AudioScheduler on disconnect")
            await audioScheduler?.finish()
            print("[CLIENT] Clearing AudioScheduler queue on disconnect")
            await audioScheduler?.clear()
        }

        // Disconnect transport
        await transport?.disconnect()

        // Clean up
        transport = nil
        clockSync = nil
        audioScheduler = nil
        bufferManager = nil
        audioPlayer = nil

        // Reset player state
        playerSyncState = "synchronized"
        currentVolume = 1.0
        currentMuted = false

        connectionState = .disconnected
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
                supportFormats: playerConfig.supportedFormats,
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

    private func sendClientState() async throws {
        guard let transport = transport else {
            throw ResonateClientError.notConnected
        }

        // Only send if we have player role
        guard roles.contains(.player) else {
            return
        }

        // Convert volume from 0.0-1.0 to 0-100 (with rounding)
        let volumeInt = Int((currentVolume * 100).rounded())

        let payload = PlayerUpdatePayload(
            state: playerSyncState,
            volume: volumeInt,
            muted: currentMuted
        )

        let message = PlayerUpdateMessage(payload: payload)

        try await transport.send(message)
    }

    nonisolated private func runMessageLoop(
        textStream: AsyncStream<String>,
        binaryStream: AsyncStream<Data>
    ) async {
        print("[CLIENT] Starting message loop")
        print("[CLIENT] Got streams, creating task group")

        await withTaskGroup(of: Void.self) { group in
            print("[CLIENT] Task group created")

            // Text message handler
            group.addTask { [weak self] in
                print("[CLIENT] Text message task starting...")
                guard let self = self else {
                    print("[CLIENT] Self is nil in text task")
                    return
                }
                print("[CLIENT] Text message handler started, beginning iteration")

                for await text in textStream {
                    print("[CLIENT] Got text message in loop")
                    await self.handleTextMessage(text)
                }
                print("[CLIENT] Text message handler ended")
            }

            // Binary message handler
            group.addTask { [weak self] in
                print("[CLIENT] Binary message task starting...")
                guard let self = self else {
                    print("[CLIENT] Self is nil in binary task")
                    return
                }
                print("[CLIENT] Binary message handler started, beginning iteration")

                for await data in binaryStream {
                    print("[CLIENT] Got binary message in loop")
                    await self.handleBinaryMessage(data)
                }
                print("[CLIENT] Binary message handler ended")
            }

            print("[CLIENT] Both tasks added to group")
        }
        print("[CLIENT] Message loop exited")
    }

    nonisolated private func runClockSync() async {
        print("[CLIENT] runClockSync ENTERED")
        guard let transport = await transport else {
            print("[CLIENT] runClockSync EXITING - no transport")
            return
        }

        while !Task.isCancelled {
            print("[CLIENT] runClockSync loop iteration")
            // Send client/time every 5 seconds
            do {
                let now = getCurrentMicroseconds()

                let payload = ClientTimePayload(clientTransmitted: now)
                let message = ClientTimeMessage(payload: payload)

                try await transport.send(message)
            } catch {
                // Connection lost
                print("[CLIENT] runClockSync connection lost: \(error)")
                break
            }

            // Wait 5 seconds
            try? await Task.sleep(for: .seconds(5))
        }
        print("[CLIENT] runClockSync EXITED")
    }

    nonisolated private func runSchedulerOutput() async {
        guard let audioScheduler = await audioScheduler,
              let audioPlayer = await audioPlayer else {
            return
        }

        for await chunk in audioScheduler.scheduledChunks {
            do {
                try await audioPlayer.playPCM(chunk.pcmData)
            } catch {
                print("[CLIENT] Failed to play scheduled chunk: \(error)")
            }
        }
    }

    nonisolated private func logSchedulerStats() async {
        var lastStats = DetailedSchedulerStats()

        while !Task.isCancelled {
            // Wait 1 second between stats logs (as per telemetry requirements)
            try? await Task.sleep(for: .seconds(1))

            guard let audioScheduler = await audioScheduler,
                  let clockSync = await clockSync else { continue }

            let currentStats = await audioScheduler.getDetailedStats()

            // Only log if we've received chunks
            if currentStats.received > 0 {
                // Calculate per-second deltas
                let framesScheduled = currentStats.received - lastStats.received
                let framesPlayed = currentStats.played - lastStats.played
                let framesDroppedLate = currentStats.droppedLate - lastStats.droppedLate
                let framesDroppedOther = currentStats.droppedOther - lastStats.droppedOther

                // Get clock sync stats
                let offset = await clockSync.statsOffset
                let rtt = await clockSync.statsRtt
                let clockOffsetMs = Double(offset) / 1000.0
                let rttMs = Double(rtt) / 1000.0

                // Telemetry format as per requirements
                print("[TELEMETRY] framesScheduled=\(framesScheduled), framesPlayed=\(framesPlayed), framesDroppedLate=\(framesDroppedLate), framesDroppedOther=\(framesDroppedOther), bufferFillMs=\(String(format: "%.1f", currentStats.bufferFillMs)), clockOffsetMs=\(String(format: "%.2f", clockOffsetMs)), rttMs=\(String(format: "%.2f", rttMs)), queueSize=\(currentStats.queueSize)")

                lastStats = currentStats
            }
        }
    }

    nonisolated private func handleTextMessage(_ text: String) async {
        // Debug logging
        print("[DEBUG] Received text message: \(text)")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let data = text.data(using: .utf8) else {
            return
        }

        // Try to decode message type
        // Note: In production, we'd use a discriminated union decoder
        // For now, try each message type

        if let message = try? decoder.decode(ServerHelloMessage.self, from: data) {
            print("[CLIENT] ✓ Decoded ServerHello")
            await handleServerHello(message)
        } else if let message = try? decoder.decode(ServerTimeMessage.self, from: data) {
            print("[CLIENT] ✓ Decoded ServerTime")
            await handleServerTime(message)
        } else if let message = try? decoder.decode(StreamStartMessage.self, from: data) {
            print("[CLIENT] ✓ Decoded StreamStart")
            await handleStreamStart(message)
        } else if let message = try? decoder.decode(StreamEndMessage.self, from: data) {
            print("[CLIENT] ✓ Decoded StreamEnd")
            await handleStreamEnd(message)
        } else if let message = try? decoder.decode(GroupUpdateMessage.self, from: data) {
            print("[CLIENT] ✓ Decoded GroupUpdate")
            await handleGroupUpdate(message)
        } else {
            print("[CLIENT] ❌ Failed to decode message: \(text)")
        }
    }

    nonisolated private func handleBinaryMessage(_ data: Data) async {
        guard let message = BinaryMessage(data: data) else {
            print("[CLIENT] ❌ Failed to parse binary message")
            return
        }

        switch message.type {
        case .audioChunk, .audioChunkAlt:
            // Call on MainActor - this will queue but maintain order
            await handleAudioChunkNonisolated(message)

        case .artworkChannel0, .artworkChannel1, .artworkChannel2, .artworkChannel3:
            let channel = Int(message.type.rawValue - 4)
            eventsContinuation.yield(.artworkReceived(channel: channel, data: message.data))

        case .visualizerData:
            eventsContinuation.yield(.visualizerData(message.data))
        }
    }

    private func handleServerHello(_ message: ServerHelloMessage) async {
        print("[CLIENT] handleServerHello ENTERED")
        connectionState = .connected

        let info = ServerInfo(
            serverId: message.payload.serverId,
            name: message.payload.name,
            version: message.payload.version
        )

        eventsContinuation.yield(.serverConnected(info))

        // Send initial client state after receiving server hello (required by spec)
        try? await sendClientState()

        // Now that handshake is complete, start clock synchronization
        print("[CLIENT] handleServerHello calling performInitialSync...")
        try? await performInitialSync()

        // Start continuous clock sync loop
        print("[CLIENT] handleServerHello starting runClockSync task...")
        clockSyncTask = Task.detached { [weak self] in
            await self?.runClockSync()
        }
        print("[CLIENT] handleServerHello EXITED")
    }

    private func handleServerTime(_ message: ServerTimeMessage) async {
        print("[CLIENT] handleServerTime ENTERED")
        guard let clockSync = clockSync else {
            print("[CLIENT] handleServerTime EXITING - no clockSync")
            return
        }

        let now = getCurrentMicroseconds()

        await clockSync.processServerTime(
            clientTransmitted: message.payload.clientTransmitted,
            serverReceived: message.payload.serverReceived,
            serverTransmitted: message.payload.serverTransmitted,
            clientReceived: now
        )
        print("[CLIENT] handleServerTime processed sync response")
    }

    private func handleStreamStart(_ message: StreamStartMessage) async {
        print("[CLIENT] 🎬 handleStreamStart called")

        guard let playerInfo = message.payload.player else {
            print("[CLIENT] ❌ No player info in stream/start payload")
            return
        }

        print("[CLIENT] Stream format: \(playerInfo.codec) \(playerInfo.sampleRate)Hz \(playerInfo.channels)ch \(playerInfo.bitDepth)bit")

        guard let audioPlayer = audioPlayer else {
            print("[CLIENT] ❌ No audio player available")
            return
        }

        // Parse codec
        guard let codec = AudioCodec(rawValue: playerInfo.codec) else {
            print("[CLIENT] ❌ Unsupported codec: \(playerInfo.codec)")
            connectionState = .error("Unsupported codec: \(playerInfo.codec)")
            playerSyncState = "error"
            try? await sendClientState()  // Notify server of error state
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
            print("[CLIENT] 🎵 Starting audio player...")
            try await audioPlayer.start(format: format, codecHeader: codecHeader)
            playerSyncState = "synchronized"  // Successfully started
            print("[CLIENT] ✅ Audio player started successfully")

            // Start scheduler
            print("[CLIENT] 📅 Starting AudioScheduler...")
            await audioScheduler?.startScheduling()
            print("[CLIENT] ✅ AudioScheduler started")

            eventsContinuation.yield(.streamStarted(format))
            try? await sendClientState()  // Notify server of synchronized state
        } catch {
            print("[CLIENT] ❌ Failed to start audio: \(error)")
            connectionState = .error("Failed to start audio: \(error.localizedDescription)")
            playerSyncState = "error"
            try? await sendClientState()  // Notify server of error state
        }
    }

    private func handleStreamEnd(_ message: StreamEndMessage) async {
        guard let audioPlayer = audioPlayer else { return }

        print("[CLIENT] Stopping AudioScheduler")
        await audioScheduler?.stop()
        print("[CLIENT] Clearing AudioScheduler queue")
        await audioScheduler?.clear()
        await audioPlayer.stop()
        playerSyncState = "synchronized"  // Reset to clean state
        eventsContinuation.yield(.streamEnded)
    }

    private func handleGroupUpdate(_ message: GroupUpdateMessage) async {
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

    nonisolated private func handleAudioChunkNonisolated(_ message: BinaryMessage) async {
        // This wrapper allows calling from nonisolated context
        // It properly awaits the MainActor call to maintain ordering
        await handleAudioChunk(message)
    }

    private func handleAudioChunk(_ message: BinaryMessage) async {
        guard let audioPlayer = audioPlayer,
              let audioScheduler = audioScheduler else {
            print("[CLIENT] ⚠️ Received audio chunk but player not started (missing stream/start?)")
            return
        }

        // Auto-start player if not already started (some servers don't send stream/start)
        // Use flag to prevent multiple simultaneous auto-starts
        let isPlaying = await audioPlayer.isPlaying
        if !isPlaying && !isAutoStarting {
            isAutoStarting = true
            print("[CLIENT] 🎵 Auto-starting player with default format (PCM 48kHz 2ch 16bit)")
            do {
                let defaultFormat = AudioFormatSpec(
                    codec: .pcm,
                    channels: 2,
                    sampleRate: 48000,
                    bitDepth: 16
                )
                try await audioPlayer.start(format: defaultFormat, codecHeader: nil)
                playerSyncState = "synchronized"

                print("[CLIENT] 📅 Starting AudioScheduler...")
                await audioScheduler.startScheduling()
                print("[CLIENT] ✅ Player auto-started successfully")

                eventsContinuation.yield(.streamStarted(defaultFormat))
                try? await sendClientState()
            } catch {
                print("[CLIENT] ❌ Failed to auto-start player: \(error)")
                isAutoStarting = false  // Reset flag on failure
                return
            }
        } else if !isPlaying && isAutoStarting {
            // Another chunk is already auto-starting, drop this chunk
            return
        }

        do {
            // Decode chunk within AudioPlayer actor
            let pcmData = try await audioPlayer.decode(message.data)

            // Schedule for playback instead of immediate enqueue
            await audioScheduler.schedule(pcm: pcmData, serverTimestamp: message.timestamp)
        } catch {
            print("[CLIENT] ❌ Failed to decode/schedule chunk: \(error)")
        }
    }

    // Process start time for relative clock (nonisolated for use in getCurrentMicroseconds)
    nonisolated private static let processStartTime = Date()

    nonisolated private func getCurrentMicroseconds() -> Int64 {
        // Use monotonic time relative to process start (like Go client)
        // This matches the server's clock domain (time.Since(serverStart))
        let elapsed = Date().timeIntervalSince(ResonateClient.processStartTime)
        return Int64(elapsed * 1_000_000)
    }

    /// Set playback volume (0.0 to 1.0)
    @MainActor
    public func setVolume(_ volume: Float) async {
        guard let audioPlayer = audioPlayer else { return }

        // Clamp volume to valid range
        let clampedVolume = max(0.0, min(1.0, volume))

        // Update AudioPlayer and get actual value back
        await audioPlayer.setVolume(clampedVolume)
        currentVolume = await audioPlayer.volume

        // Send state update to server (required by spec)
        try? await sendClientState()
    }

    /// Set mute state
    @MainActor
    public func setMute(_ muted: Bool) async {
        guard let audioPlayer = audioPlayer else { return }

        // Update AudioPlayer and get actual value back
        await audioPlayer.setMute(muted)
        currentMuted = await audioPlayer.muted

        // Send state update to server (required by spec)
        try? await sendClientState()
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
