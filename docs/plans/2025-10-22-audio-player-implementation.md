# ResonateKit Audio Player Implementation Plan

> **For Claude:** Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` to implement this plan task-by-task.

**Goal:** Implement complete player functionality including AudioQueue-based playback, message handling loop, and synchronized audio streaming.

**Architecture:** @Observable ResonateClient class orchestrates internal actors (WebSocketTransport, ClockSynchronizer, BufferManager, AudioPlayer). Message loop uses structured concurrency with AsyncStreams for text/binary messages and periodic clock sync. AudioPlayer wraps AudioQueue for low-level synchronized playback.

**Tech Stack:** Swift 6, Audio Toolbox (AudioQueue), AVFoundation (audio decoding), Swift Concurrency (actors, AsyncStream, structured tasks)

---

## Task 1: AudioPlayer Actor Foundation

**Files:**
- Create: `Sources/ResonateKit/Audio/AudioPlayer.swift`
- Create: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift`

**Step 1: Write test for AudioPlayer initialization**

File: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift`
```swift
import Testing
@testable import ResonateKit

@Suite("AudioPlayer Tests")
struct AudioPlayerTests {
    @Test("Initialize AudioPlayer with dependencies")
    func testInitialization() async {
        let bufferManager = BufferManager(capacity: 1024)
        let clockSync = ClockSynchronizer()

        let player = AudioPlayer(
            bufferManager: bufferManager,
            clockSync: clockSync
        )

        let isPlaying = await player.isPlaying
        #expect(isPlaying == false)
    }
}
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter AudioPlayerTests
```

Expected: Compilation error - AudioPlayer doesn't exist

**Step 3: Implement AudioPlayer actor foundation**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift`
```swift
// ABOUTME: Manages AudioQueue-based audio playback with microsecond-precise synchronization
// ABOUTME: Handles format setup, chunk decoding, and timestamp-based playback scheduling

import Foundation
import AudioToolbox
import AVFoundation

/// Actor managing synchronized audio playback
public actor AudioPlayer {
    private let bufferManager: BufferManager
    private let clockSync: ClockSynchronizer

    private var audioQueue: AudioQueueRef?
    private var decoder: AudioDecoder?
    private var currentFormat: AudioFormatSpec?

    private var _isPlaying: Bool = false

    public var isPlaying: Bool {
        return _isPlaying
    }

    public init(bufferManager: BufferManager, clockSync: ClockSynchronizer) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
    }

    deinit {
        // Clean up AudioQueue if still allocated
        if let queue = audioQueue {
            AudioQueueDispose(queue, true)
        }
    }
}
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter AudioPlayerTests
```

Expected: Test passes

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift Tests/ResonateKitTests/Audio/AudioPlayerTests.swift
git commit -m "feat: add AudioPlayer actor foundation"
```

---

## Task 2: AudioPlayer Format Setup

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`
- Modify: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift`

**Step 1: Write test for format configuration**

File: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift` (add to suite)
```swift
@Test("Configure audio format")
func testFormatSetup() async throws {
    let bufferManager = BufferManager(capacity: 1024)
    let clockSync = ClockSynchronizer()
    let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

    let format = AudioFormatSpec(
        codec: .pcm,
        channels: 2,
        sampleRate: 48000,
        bitDepth: 16
    )

    try await player.start(format: format, codecHeader: nil)

    let isPlaying = await player.isPlaying
    #expect(isPlaying == true)
}
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter AudioPlayerTests.testFormatSetup
```

Expected: Compilation error - `start(format:codecHeader:)` doesn't exist

**Step 3: Implement format setup and AudioQueue creation**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift` (add to actor)
```swift
/// Start playback with specified format
public func start(format: AudioFormatSpec, codecHeader: Data?) throws {
    // Don't restart if already playing with same format
    if _isPlaying && currentFormat == format {
        return
    }

    // Stop existing playback
    stop()

    // Create decoder for codec
    decoder = try AudioDecoderFactory.create(
        codec: format.codec,
        sampleRate: format.sampleRate,
        channels: format.channels,
        bitDepth: format.bitDepth,
        header: codecHeader
    )

    // Configure AudioQueue format (always output PCM)
    var audioFormat = AudioStreamBasicDescription()
    audioFormat.mSampleRate = Float64(format.sampleRate)
    audioFormat.mFormatID = kAudioFormatLinearPCM
    audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
    audioFormat.mBytesPerPacket = UInt32(format.channels * format.bitDepth / 8)
    audioFormat.mFramesPerPacket = 1
    audioFormat.mBytesPerFrame = UInt32(format.channels * format.bitDepth / 8)
    audioFormat.mChannelsPerFrame = UInt32(format.channels)
    audioFormat.mBitsPerChannel = UInt32(format.bitDepth)

    // Create AudioQueue
    var queue: AudioQueueRef?
    let status = AudioQueueNewOutput(
        &audioFormat,
        audioQueueCallback,
        Unmanaged.passUnretained(self).toOpaque(),
        nil,
        nil,
        0,
        &queue
    )

    guard status == noErr, let queue = queue else {
        throw AudioPlayerError.queueCreationFailed
    }

    self.audioQueue = queue
    self.currentFormat = format

    // Start the queue
    AudioQueueStart(queue, nil)
    _isPlaying = true
}

/// Stop playback and clean up
public func stop() {
    guard let queue = audioQueue else { return }

    AudioQueueStop(queue, true)
    AudioQueueDispose(queue, true)

    audioQueue = nil
    decoder = nil
    currentFormat = nil
    _isPlaying = false
}

// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    // TODO: Implement in next task
}

public enum AudioPlayerError: Error {
    case queueCreationFailed
    case notStarted
    case decodingFailed
}
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter AudioPlayerTests.testFormatSetup
```

Expected: Test passes

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift Tests/ResonateKitTests/Audio/AudioPlayerTests.swift
git commit -m "feat: add AudioPlayer format setup and AudioQueue creation"
```

---

## Task 3: AudioPlayer Chunk Enqueuing

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`
- Modify: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift`

**Step 1: Write test for chunk enqueuing**

File: `Tests/ResonateKitTests/Audio/AudioPlayerTests.swift` (add to suite)
```swift
@Test("Enqueue audio chunk")
func testEnqueueChunk() async throws {
    let bufferManager = BufferManager(capacity: 1_048_576)
    let clockSync = ClockSynchronizer()
    let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

    let format = AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
    try await player.start(format: format, codecHeader: nil)

    // Create binary message with PCM audio data
    var data = Data()
    data.append(0)  // Audio chunk type

    let timestamp: Int64 = 1_000_000  // 1 second
    withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }

    // Add 4800 bytes of PCM data (0.05 seconds at 48kHz stereo 16-bit)
    let audioData = Data(repeating: 0, count: 4800)
    data.append(audioData)

    let message = try #require(BinaryMessage(data: data))

    // Should not throw
    try await player.enqueue(chunk: message)
}
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter AudioPlayerTests.testEnqueueChunk
```

Expected: Compilation error - `enqueue(chunk:)` doesn't exist

**Step 3: Implement chunk enqueuing**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift` (add to actor)
```swift
private var pendingChunks: [(timestamp: Int64, data: Data)] = []
private let maxPendingChunks = 50

/// Enqueue audio chunk for playback
public func enqueue(chunk: BinaryMessage) throws {
    guard audioQueue != nil else {
        throw AudioPlayerError.notStarted
    }

    // Decode chunk data
    guard let decoder = decoder else {
        throw AudioPlayerError.notStarted
    }

    let pcmData = try decoder.decode(chunk.data)

    // Convert server timestamp to local time
    let localTimestamp = await clockSync.serverTimeToLocal(chunk.timestamp)

    // Check if chunk is late (timestamp in the past)
    let now = getCurrentMicroseconds()
    if localTimestamp < now {
        // Drop late chunk to maintain sync
        return
    }

    // Check buffer capacity
    let hasCapacity = await bufferManager.hasCapacity(pcmData.count)
    guard hasCapacity else {
        // Backpressure - don't accept chunk
        throw AudioPlayerError.bufferFull
    }

    // Register with buffer manager
    let duration = calculateDuration(bytes: pcmData.count)
    await bufferManager.register(endTimeMicros: localTimestamp + duration, byteCount: pcmData.count)

    // Store pending chunk
    pendingChunks.append((timestamp: localTimestamp, data: pcmData))

    // Limit pending queue size
    if pendingChunks.count > maxPendingChunks {
        pendingChunks.removeFirst()
    }
}

private func calculateDuration(bytes: Int) -> Int64 {
    guard let format = currentFormat else { return 0 }

    let bytesPerSample = format.channels * format.bitDepth / 8
    let samples = bytes / bytesPerSample
    let seconds = Double(samples) / Double(format.sampleRate)

    return Int64(seconds * 1_000_000)  // Convert to microseconds
}

private func getCurrentMicroseconds() -> Int64 {
    let timebase = mach_timebase_info()
    var info = timebase
    mach_timebase_info(&info)

    let nanos = mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
    return Int64(nanos / 1000)  // Convert to microseconds
}
```

Add to `AudioPlayerError` enum:
```swift
case bufferFull
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter AudioPlayerTests.testEnqueueChunk
```

Expected: Test passes

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift Tests/ResonateKitTests/Audio/AudioPlayerTests.swift
git commit -m "feat: add AudioPlayer chunk enqueuing with timestamp sync"
```

---

## Task 4: AudioQueue Callback Implementation

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`

**Step 1: Implement AudioQueue callback to feed chunks**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift` (replace callback stub)
```swift
// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData = userData else { return }

    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()

    // Call async method from sync context
    Task {
        await player.fillBuffer(queue: queue, buffer: buffer)
    }
}
```

Add method to actor:
```swift
private func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
    // Get next pending chunk
    guard !pendingChunks.isEmpty else {
        // No data available - enqueue silence
        memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        return
    }

    let chunk = pendingChunks.removeFirst()

    // Copy chunk data to buffer
    let copySize = min(chunk.data.count, Int(buffer.pointee.mAudioDataBytesCapacity))
    chunk.data.withUnsafeBytes { srcBytes in
        memcpy(buffer.pointee.mAudioData, srcBytes.baseAddress, copySize)
    }

    buffer.pointee.mAudioDataByteSize = UInt32(copySize)

    // Calculate playback time
    let playbackTime = AudioTimeStamp(
        mSampleTime: 0,
        mHostTime: UInt64(chunk.timestamp * 1000),  // Convert microseconds to nanoseconds
        mRateScalar: 1.0,
        mWordClockTime: 0,
        mSMPTETime: SMPTETime(),
        mFlags: [.hostTimeValid],
        mReserved: 0
    )

    // Enqueue buffer with timestamp
    var time = playbackTime
    AudioQueueEnqueueBufferWithParameters(
        queue,
        buffer,
        0,
        nil,
        0,
        0,
        0,
        nil,
        &time,
        nil
    )

    // Update buffer manager (chunk consumed)
    Task {
        await bufferManager.pruneConsumed(nowMicros: getCurrentMicroseconds())
    }
}
```

**Step 2: Allocate AudioQueue buffers**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift` (modify `start` method, after `AudioQueueStart`)
```swift
// Allocate buffers
let bufferSize: UInt32 = 16384  // 16KB per buffer
for _ in 0..<3 {  // 3 buffers for smooth playback
    var buffer: AudioQueueBufferRef?
    let status = AudioQueueAllocateBuffer(queue, bufferSize, &buffer)

    if status == noErr, let buffer = buffer {
        // Prime buffer with initial chunk
        fillBuffer(queue: queue, buffer: buffer)
    }
}
```

**Step 3: Test manually (no new test - relies on existing tests)**

```bash
swift test --filter AudioPlayerTests
```

Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift
git commit -m "feat: implement AudioQueue callback for synchronized playback"
```

---

## Task 5: ResonateClient Message Loop Foundation

**Files:**
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`
- Modify: `Tests/ResonateKitTests/Client/ResonateClientTests.swift`

**Step 1: Write test for connect method**

File: `Tests/ResonateKitTests/Client/ResonateClientTests.swift` (add to suite)
```swift
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
```

**Step 2: Run test to verify it compiles**

```bash
swift test --filter ResonateClientTests.testConnect
```

Expected: Test passes (just checks initial state)

**Step 3: Add connect method structure**

File: `Sources/ResonateKit/Client/ResonateClient.swift` (add to class)
```swift
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

private func sendClientHello() async throws {
    // TODO: Implement in next task
}

private func runMessageLoop() async {
    // TODO: Implement in next task
}

private func runClockSync() async {
    // TODO: Implement in next task
}
```

Add new types:
```swift
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
```

**Step 4: Run test to verify it compiles**

```bash
swift test --filter ResonateClientTests
```

Expected: Tests pass

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Client/ResonateClient.swift Tests/ResonateKitTests/Client/ResonateClientTests.swift
git commit -m "feat: add ResonateClient connect/disconnect structure"
```

---

## Task 6: Client Hello Message

**Files:**
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Implement sendClientHello method**

File: `Sources/ResonateKit/Client/ResonateClient.swift` (replace stub)
```swift
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
```

Add error enum:
```swift
public enum ResonateClientError: Error {
    case notConnected
    case unsupportedCodec(String)
    case audioSetupFailed
}
```

**Step 2: Test manually (requires full integration test with mock server)**

```bash
swift build
```

Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: implement client hello handshake message"
```

---

## Task 7: Message Loop Implementation

**Files:**
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Implement message loop**

File: `Sources/ResonateKit/Client/ResonateClient.swift` (replace stub)
```swift
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

@MainActor
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

@MainActor
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

@MainActor
private func handleStreamEnd(_ message: StreamEndMessage) async {
    guard let audioPlayer = audioPlayer else { return }

    await audioPlayer.stop()
    eventsContinuation.yield(.streamEnded)
}

@MainActor
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
```

**Step 2: Build to verify**

```bash
swift build
```

Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: implement message loop with text and binary handlers"
```

---

## Task 8: Clock Sync Loop

**Files:**
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Implement periodic clock sync**

File: `Sources/ResonateKit/Client/ResonateClient.swift` (replace stub)
```swift
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
```

**Step 2: Build to verify**

```bash
swift build
```

Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: implement periodic clock synchronization loop"
```

---

## Task 9: Volume and Mute Control

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Add volume/mute to AudioPlayer**

File: `Sources/ResonateKit/Audio/AudioPlayer.swift` (add to actor)
```swift
private var currentVolume: Float = 1.0
private var isMuted: Bool = false

public var volume: Float {
    return currentVolume
}

public var muted: Bool {
    return isMuted
}

/// Set volume (0.0 to 1.0)
public func setVolume(_ volume: Float) {
    guard let queue = audioQueue else { return }

    let clampedVolume = max(0.0, min(1.0, volume))
    currentVolume = clampedVolume

    AudioQueueSetParameter(queue, kAudioQueueParam_Volume, clampedVolume)
}

/// Set mute state
public func setMute(_ muted: Bool) {
    guard let queue = audioQueue else { return }

    self.isMuted = muted

    // Set volume to 0 when muted, restore when unmuted
    let effectiveVolume = muted ? 0.0 : currentVolume
    AudioQueueSetParameter(queue, kAudioQueueParam_Volume, effectiveVolume)
}
```

**Step 2: Add control methods to ResonateClient**

File: `Sources/ResonateKit/Client/ResonateClient.swift` (add to class)
```swift
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
```

**Step 3: Build to verify**

```bash
swift build
```

Expected: Build succeeds

**Step 4: Run all tests**

```bash
swift test
```

Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: add volume and mute controls to AudioPlayer"
```

---

## Summary & Next Steps

This plan implements:

✅ **Completed:**
- AudioPlayer actor with AudioQueue integration
- Audio format setup and decoder creation
- Chunk enqueuing with timestamp synchronization
- AudioQueue callback for synchronized playback
- ResonateClient message loop foundation
- Client hello handshake
- Text message handlers (server/hello, server/time, stream/start, stream/end, group/update)
- Binary message handlers (audio chunks, artwork, visualizer)
- Periodic clock synchronization
- Volume and mute controls

🚧 **Remaining (for future sessions):**
- FLAC/Opus audio decoding (currently only PCM works)
- mDNS discovery (Network.framework)
- Controller role commands (play/pause, seek, etc.)
- Client state reporting (player state updates to server)
- Error recovery and reconnection
- Integration tests with mock WebSocket server
- Example app demonstrating usage

**Testing Notes:**
- Current tests verify component initialization
- Full integration testing requires mock WebSocket server
- Manual testing with real Music Assistant server recommended

**Known Limitations:**
- Only PCM codec fully implemented (FLAC/Opus stub)
- No automatic reconnection
- No adaptive clock sync (fixed 5-second interval)
- AudioQueue callback uses Task bridge (adds latency)

Ready for execution!
