# Audio Scheduler Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task in this session with fresh subagents and code review between tasks.

**Goal:** Implement timestamp-based audio scheduling to fix synchronization issues by ensuring chunks play at their correct server timestamps, not arrival times.

**Architecture:** Create AudioScheduler actor between decoder and AudioPlayer. Scheduler converts server timestamps to local times, maintains priority queue, checks every 10ms for ready chunks, drops late chunks (>50ms), and outputs to AudioPlayer at precise timing.

**Tech Stack:** Swift Concurrency (actors, AsyncStream), Foundation (Date, Timer), AudioToolbox (existing)

**Related Design Doc:** `docs/plans/2025-10-24-audio-scheduler-design.md`

---

## Task 1: Create AudioScheduler Core Structure

**Files:**
- Create: `Sources/ResonateKit/Audio/AudioScheduler.swift`

**Step 1: Write the failing test**

Create: `Tests/ResonateKitTests/AudioSchedulerTests.swift`

```swift
import XCTest
@testable import ResonateKit

final class AudioSchedulerTests: XCTestCase {
    func testSchedulerAcceptsChunk() async throws {
        // Mock clock sync that returns zero offset
        let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
        let scheduler = AudioScheduler(clockSync: clockSync)

        let pcmData = Data(repeating: 0x00, count: 1024)
        let serverTimestamp: Int64 = 1000000 // 1 second in microseconds

        // Should not throw
        await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

        let stats = await scheduler.stats
        XCTAssertEqual(stats.received, 1)
    }
}

// Mock ClockSynchronizer for testing
actor MockClockSynchronizer {
    private let offset: Int64
    private let drift: Double

    init(offset: Int64, drift: Double) {
        self.offset = offset
        self.drift = drift
    }

    func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        return serverTime - offset
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AudioSchedulerTests/testSchedulerAcceptsChunk`
Expected: BUILD FAILED - "Cannot find type 'AudioScheduler' in scope"

**Step 3: Write minimal implementation**

Create: `Sources/ResonateKit/Audio/AudioScheduler.swift`

```swift
// ABOUTME: Timestamp-based audio playback scheduler with priority queue
// ABOUTME: Converts server timestamps to local time and schedules precise playback

import Foundation

/// Statistics tracked by the scheduler
public struct SchedulerStats: Sendable {
    public let received: Int
    public let played: Int
    public let dropped: Int

    public init(received: Int = 0, played: Int = 0, dropped: Int = 0) {
        self.received = received
        self.played = played
        self.dropped = dropped
    }
}

/// A chunk scheduled for playback at a specific time
public struct ScheduledChunk: Sendable {
    public let pcmData: Data
    public let playTime: Date
    public let originalTimestamp: Int64
}

/// Actor managing timestamp-based audio playback scheduling
public actor AudioScheduler {
    private let clockSync: ClockSynchronizer
    private let playbackWindow: TimeInterval
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats

    public init(clockSync: ClockSynchronizer, playbackWindow: TimeInterval = 0.05) {
        self.clockSync = clockSync
        self.playbackWindow = playbackWindow
        self.schedulerStats = SchedulerStats()
    }

    /// Schedule a PCM chunk for playback
    public func schedule(pcm: Data, serverTimestamp: Int64) async {
        schedulerStats = SchedulerStats(
            received: schedulerStats.received + 1,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped
        )
    }

    /// Get current statistics
    public var stats: SchedulerStats {
        return schedulerStats
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AudioSchedulerTests/testSchedulerAcceptsChunk`
Expected: Test Suite 'AudioSchedulerTests' passed

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioScheduler.swift Tests/ResonateKitTests/AudioSchedulerTests.swift
git commit -m "feat: add AudioScheduler core structure with stats tracking"
```

---

## Task 2: Implement Priority Queue and Timestamp Conversion

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioScheduler.swift`
- Modify: `Tests/ResonateKitTests/AudioSchedulerTests.swift`

**Step 1: Write the failing test**

Add to `Tests/ResonateKitTests/AudioSchedulerTests.swift`:

```swift
func testSchedulerConvertsTimestamps() async throws {
    // Clock sync with 1 second offset (server ahead)
    let clockSync = MockClockSynchronizer(offset: 1_000_000, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync)

    let pcmData = Data(repeating: 0x00, count: 1024)
    let serverTimestamp: Int64 = 2_000_000 // 2 seconds server time

    await scheduler.schedule(pcm: pcmData, serverTimestamp: serverTimestamp)

    let chunks = await scheduler.getQueuedChunks()
    XCTAssertEqual(chunks.count, 1)

    // Expected: serverTime - offset = 2_000_000 - 1_000_000 = 1_000_000 microseconds = 1 second
    let expectedPlayTime = Date(timeIntervalSince1970: 1.0)
    let actualPlayTime = chunks[0].playTime
    XCTAssertEqual(actualPlayTime.timeIntervalSince1970, expectedPlayTime.timeIntervalSince1970, accuracy: 0.001)
}

func testSchedulerMaintainsSortedQueue() async throws {
    let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync)

    // Schedule chunks out of order
    await scheduler.schedule(pcm: Data([3]), serverTimestamp: 3_000_000)
    await scheduler.schedule(pcm: Data([1]), serverTimestamp: 1_000_000)
    await scheduler.schedule(pcm: Data([2]), serverTimestamp: 2_000_000)

    let chunks = await scheduler.getQueuedChunks()
    XCTAssertEqual(chunks.count, 3)

    // Should be sorted by playTime
    XCTAssertLessThan(chunks[0].playTime, chunks[1].playTime)
    XCTAssertLessThan(chunks[1].playTime, chunks[2].playTime)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AudioSchedulerTests`
Expected: FAILED - "Value of type 'AudioScheduler' has no member 'getQueuedChunks'"

**Step 3: Write implementation**

Modify `Sources/ResonateKit/Audio/AudioScheduler.swift`:

```swift
/// Schedule a PCM chunk for playback
public func schedule(pcm: Data, serverTimestamp: Int64) async {
    // Convert server timestamp to local playback time
    let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)
    let localTimeSeconds = Double(localTimeMicros) / 1_000_000.0
    let playTime = Date(timeIntervalSince1970: localTimeSeconds)

    let chunk = ScheduledChunk(
        pcmData: pcm,
        playTime: playTime,
        originalTimestamp: serverTimestamp
    )

    // Insert into sorted position
    insertSorted(chunk)

    schedulerStats = SchedulerStats(
        received: schedulerStats.received + 1,
        played: schedulerStats.played,
        dropped: schedulerStats.dropped
    )
}

/// Insert chunk maintaining sorted order by playTime
private func insertSorted(_ chunk: ScheduledChunk) {
    let index = queue.partition { $0.playTime < chunk.playTime }
    queue.insert(chunk, at: index)
}

/// Get queued chunks (for testing)
public func getQueuedChunks() -> [ScheduledChunk] {
    return queue
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AudioSchedulerTests`
Expected: Test Suite 'AudioSchedulerTests' passed (3 tests)

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioScheduler.swift Tests/ResonateKitTests/AudioSchedulerTests.swift
git commit -m "feat: implement timestamp conversion and priority queue in AudioScheduler"
```

---

## Task 3: Implement AsyncStream Output and Timer Loop

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioScheduler.swift`
- Modify: `Tests/ResonateKitTests/AudioSchedulerTests.swift`

**Step 1: Write the failing test**

Add to `Tests/ResonateKitTests/AudioSchedulerTests.swift`:

```swift
func testSchedulerOutputsReadyChunks() async throws {
    let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync)

    // Schedule chunk for immediate playback (current time)
    let now = Date()
    let nowMicros = Int64(now.timeIntervalSince1970 * 1_000_000)

    await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: nowMicros)
    await scheduler.startScheduling()

    // Should output chunk immediately
    var outputChunks: [ScheduledChunk] = []
    let task = Task {
        for await chunk in await scheduler.scheduledChunks {
            outputChunks.append(chunk)
            break // Just get first chunk
        }
    }

    try await Task.sleep(for: .milliseconds(50))
    await scheduler.stop()
    await task.value

    XCTAssertEqual(outputChunks.count, 1)
    XCTAssertEqual(outputChunks[0].pcmData, Data([0x01]))

    let stats = await scheduler.stats
    XCTAssertEqual(stats.played, 1)
}

func testSchedulerDropsLateChunks() async throws {
    let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync)

    // Schedule chunk 100ms in the past
    let now = Date()
    let pastMicros = Int64((now.timeIntervalSince1970 - 0.1) * 1_000_000)

    await scheduler.schedule(pcm: Data([0xFF]), serverTimestamp: pastMicros)
    await scheduler.startScheduling()

    try await Task.sleep(for: .milliseconds(50))
    await scheduler.stop()

    let stats = await scheduler.stats
    XCTAssertEqual(stats.dropped, 1)
    XCTAssertEqual(stats.played, 0)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AudioSchedulerTests`
Expected: FAILED - "Value of type 'AudioScheduler' has no member 'startScheduling'"

**Step 3: Write implementation**

Modify `Sources/ResonateKit/Audio/AudioScheduler.swift`:

```swift
public actor AudioScheduler {
    private let clockSync: ClockSynchronizer
    private let playbackWindow: TimeInterval
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats
    private var timerTask: Task<Void, Never>?

    // AsyncStream for output
    private let chunkContinuation: AsyncStream<ScheduledChunk>.Continuation
    public let scheduledChunks: AsyncStream<ScheduledChunk>

    public init(clockSync: ClockSynchronizer, playbackWindow: TimeInterval = 0.05) {
        self.clockSync = clockSync
        self.playbackWindow = playbackWindow
        self.schedulerStats = SchedulerStats()

        // Create AsyncStream
        (scheduledChunks, chunkContinuation) = AsyncStream.makeStream()
    }

    /// Start the scheduling timer loop
    public func startScheduling() {
        guard timerTask == nil else { return }

        timerTask = Task {
            while !Task.isCancelled {
                await checkQueue()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Stop the scheduler and clear queue
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        chunkContinuation.finish()
    }

    /// Check queue and output ready chunks
    private func checkQueue() {
        let now = Date()

        while let next = queue.first {
            let delay = next.playTime.timeIntervalSince(now)

            if delay > playbackWindow {
                // Too early, wait
                break
            } else if delay < -playbackWindow {
                // Too late, drop
                queue.removeFirst()
                schedulerStats = SchedulerStats(
                    received: schedulerStats.received,
                    played: schedulerStats.played,
                    dropped: schedulerStats.dropped + 1
                )

                // Log first 10 drops
                if schedulerStats.dropped <= 10 {
                    print("[SCHEDULER] Dropped late chunk: \(Int(-delay * 1000))ms late")
                }
            } else {
                // Ready to play (within ±50ms window)
                let chunk = queue.removeFirst()
                chunkContinuation.yield(chunk)

                schedulerStats = SchedulerStats(
                    received: schedulerStats.received,
                    played: schedulerStats.played + 1,
                    dropped: schedulerStats.dropped
                )
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AudioSchedulerTests`
Expected: Test Suite 'AudioSchedulerTests' passed (5 tests)

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioScheduler.swift Tests/ResonateKitTests/AudioSchedulerTests.swift
git commit -m "feat: implement timer loop and AsyncStream output in AudioScheduler"
```

---

## Task 4: Add Queue Management and Safety Features

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioScheduler.swift`
- Modify: `Tests/ResonateKitTests/AudioSchedulerTests.swift`

**Step 1: Write the failing test**

Add to `Tests/ResonateKitTests/AudioSchedulerTests.swift`:

```swift
func testSchedulerEnforcesQueueLimit() async throws {
    let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync, maxQueueSize: 5)

    let future = Date().addingTimeInterval(10) // 10 seconds in future
    let futureMicros = Int64(future.timeIntervalSince1970 * 1_000_000)

    // Schedule 10 chunks (exceeds limit of 5)
    for i in 0..<10 {
        await scheduler.schedule(
            pcm: Data([UInt8(i)]),
            serverTimestamp: futureMicros + Int64(i * 1000)
        )
    }

    let chunks = await scheduler.getQueuedChunks()
    XCTAssertLessThanOrEqual(chunks.count, 5)

    let stats = await scheduler.stats
    XCTAssertEqual(stats.received, 10)
    XCTAssertEqual(stats.dropped, 5) // Should have dropped oldest 5
}

func testSchedulerClearQueue() async throws {
    let clockSync = MockClockSynchronizer(offset: 0, drift: 0.0)
    let scheduler = AudioScheduler(clockSync: clockSync)

    let future = Date().addingTimeInterval(10)
    let futureMicros = Int64(future.timeIntervalSince1970 * 1_000_000)

    await scheduler.schedule(pcm: Data([0x01]), serverTimestamp: futureMicros)
    await scheduler.schedule(pcm: Data([0x02]), serverTimestamp: futureMicros + 1000)

    var chunks = await scheduler.getQueuedChunks()
    XCTAssertEqual(chunks.count, 2)

    await scheduler.clear()

    chunks = await scheduler.getQueuedChunks()
    XCTAssertEqual(chunks.count, 0)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AudioSchedulerTests`
Expected: FAILED - "Extra argument 'maxQueueSize' in call"

**Step 3: Write implementation**

Modify `Sources/ResonateKit/Audio/AudioScheduler.swift`:

```swift
public actor AudioScheduler {
    private let clockSync: ClockSynchronizer
    private let playbackWindow: TimeInterval
    private let maxQueueSize: Int
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats
    private var timerTask: Task<Void, Never>?

    // AsyncStream for output
    private let chunkContinuation: AsyncStream<ScheduledChunk>.Continuation
    public let scheduledChunks: AsyncStream<ScheduledChunk>

    public init(
        clockSync: ClockSynchronizer,
        playbackWindow: TimeInterval = 0.05,
        maxQueueSize: Int = 100
    ) {
        self.clockSync = clockSync
        self.playbackWindow = playbackWindow
        self.maxQueueSize = maxQueueSize
        self.schedulerStats = SchedulerStats()

        // Create AsyncStream
        (scheduledChunks, chunkContinuation) = AsyncStream.makeStream()
    }

    /// Schedule a PCM chunk for playback
    public func schedule(pcm: Data, serverTimestamp: Int64) async {
        // Convert server timestamp to local playback time
        let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)
        let localTimeSeconds = Double(localTimeMicros) / 1_000_000.0
        let playTime = Date(timeIntervalSince1970: localTimeSeconds)

        let chunk = ScheduledChunk(
            pcmData: pcm,
            playTime: playTime,
            originalTimestamp: serverTimestamp
        )

        // Enforce queue size limit
        while queue.count >= maxQueueSize {
            queue.removeFirst()
            schedulerStats = SchedulerStats(
                received: schedulerStats.received,
                played: schedulerStats.played,
                dropped: schedulerStats.dropped + 1
            )
            print("[SCHEDULER] Queue overflow: dropped oldest chunk")
        }

        // Insert into sorted position
        insertSorted(chunk)

        schedulerStats = SchedulerStats(
            received: schedulerStats.received + 1,
            played: schedulerStats.played,
            dropped: schedulerStats.dropped
        )
    }

    /// Clear all queued chunks
    public func clear() {
        queue.removeAll()
        print("[SCHEDULER] Queue cleared")
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AudioSchedulerTests`
Expected: Test Suite 'AudioSchedulerTests' passed (7 tests)

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioScheduler.swift Tests/ResonateKitTests/AudioSchedulerTests.swift
git commit -m "feat: add queue size limit and clear functionality to AudioScheduler"
```

---

## Task 5: Refactor AudioPlayer for Direct PCM Playback

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`
- Create: `Tests/ResonateKitTests/AudioPlayerTests.swift`

**Step 1: Write the failing test**

Create: `Tests/ResonateKitTests/AudioPlayerTests.swift`

```swift
import XCTest
@testable import ResonateKit

final class AudioPlayerTests: XCTestCase {
    func testAudioPlayerPlaysDirectPCM() async throws {
        let clockSync = ClockSynchronizer()
        let bufferManager = BufferManager(capacity: 1_048_576)
        let player = AudioPlayer(bufferManager: bufferManager, clockSync: clockSync)

        let format = AudioFormatSpec(
            codec: .pcm,
            channels: 2,
            sampleRate: 48000,
            bitDepth: 16
        )

        try await player.start(format: format, codecHeader: nil)

        // Create 1 second of silence
        let bytesPerSample = format.channels * format.bitDepth / 8
        let samplesPerSecond = format.sampleRate
        let pcmData = Data(repeating: 0, count: samplesPerSecond * bytesPerSample)

        // Should not throw
        try await player.playPCM(pcmData)

        await player.stop()
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AudioPlayerTests`
Expected: FAILED - "Value of type 'AudioPlayer' has no member 'playPCM'"

**Step 3: Write implementation**

Modify `Sources/ResonateKit/Audio/AudioPlayer.swift`:

Add new method before `fillBuffer()`:

```swift
/// Play PCM data directly (for scheduled playback)
public func playPCM(_ pcmData: Data) async throws {
    guard let audioQueue = audioQueue, let format = currentFormat else {
        throw AudioPlayerError.notStarted
    }

    // Add to pending chunks for AudioQueue callback to consume
    let now = getCurrentMicroseconds()

    pendingChunksLock.withLock {
        // Don't use timestamps for scheduled playback - chunks arrive at correct time
        pendingChunks.append((timestamp: now, data: pcmData))

        if pendingChunks.count > maxPendingChunks {
            pendingChunks.removeFirst()
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AudioPlayerTests`
Expected: Test Suite 'AudioPlayerTests' passed

**Step 5: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift Tests/ResonateKitTests/AudioPlayerTests.swift
git commit -m "feat: add direct PCM playback method to AudioPlayer"
```

---

## Task 6: Integrate AudioScheduler into ResonateClient

**Files:**
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Add AudioScheduler property and initialization**

In `ResonateClient` actor, add after `clockSync` property:

```swift
private var audioScheduler: AudioScheduler?
```

In `connect()` method, after creating `clockSync` (around line 109):

```swift
// Create dependencies
let transport = WebSocketTransport(url: url)
let clockSync = ClockSynchronizer()
let audioScheduler = AudioScheduler(clockSync: clockSync)  // NEW

self.transport = transport
self.clockSync = clockSync
self.audioScheduler = audioScheduler  // NEW
```

**Step 2: Start scheduler output consumer**

In `connect()` method, after starting message loop (around line 148):

```swift
// Start clock sync loop (detached from MainActor)
clockSyncTask = Task.detached { [weak self] in
    await self?.runClockSync()
}

// Start scheduler output consumer (NEW)
Task.detached { [weak self] in
    await self?.runSchedulerOutput()
}
```

**Step 3: Add scheduler output handler**

Add new method after `runClockSync()`:

```swift
nonisolated private func runSchedulerOutput() async {
    guard let audioScheduler = await audioScheduler,
          let audioPlayer = await audioPlayer else {
        return
    }

    for await chunk in await audioScheduler.scheduledChunks {
        do {
            try await audioPlayer.playPCM(chunk.pcmData)
        } catch {
            print("[CLIENT] Failed to play scheduled chunk: \(error)")
        }
    }
}
```

**Step 4: Update handleAudioChunk to use scheduler**

Modify `handleAudioChunk()` method (around line 445):

```swift
private func handleAudioChunk(_ message: BinaryMessage) async {
    guard let audioPlayer = audioPlayer,
          let audioScheduler = audioScheduler else { return }

    // Decode chunk
    guard let decoder = audioPlayer.decoder else {
        print("[DEBUG] No decoder available")
        return
    }

    do {
        let pcmData = try decoder.decode(message.data)

        // Schedule for playback instead of immediate enqueue
        await audioScheduler.schedule(pcm: pcmData, serverTimestamp: message.timestamp)
    } catch {
        print("[DEBUG] Failed to decode/schedule chunk: \(error)")
    }
}
```

**Step 5: Start scheduler when stream starts**

Modify `handleStreamStart()` method, after starting audio player (around line 416):

```swift
do {
    try await audioPlayer.start(format: format, codecHeader: codecHeader)
    playerSyncState = "synchronized"

    // Start scheduler
    await audioScheduler?.startScheduling()  // NEW

    eventsContinuation.yield(.streamStarted(format))
    try? await sendClientState()
} catch {
    connectionState = .error("Failed to start audio: \(error.localizedDescription)")
    playerSyncState = "error"
    try? await sendClientState()
}
```

**Step 6: Clear scheduler on stream end**

Modify `handleStreamEnd()` method:

```swift
private func handleStreamEnd(_ message: StreamEndMessage) async {
    guard let audioPlayer = audioPlayer else { return }

    await audioScheduler?.stop()  // NEW
    await audioScheduler?.clear()  // NEW
    await audioPlayer.stop()
    playerSyncState = "synchronized"
    eventsContinuation.yield(.streamEnded)
}
```

**Step 7: Clean up scheduler on disconnect**

Modify `disconnect()` method, after stopping audio player:

```swift
// Stop audio
if let audioPlayer = audioPlayer {
    await audioPlayer.stop()
}

// Stop and clear scheduler (NEW)
await audioScheduler?.stop()
await audioScheduler?.clear()

// Disconnect transport
await transport?.disconnect()

// Clean up
transport = nil
clockSync = nil
bufferManager = nil
audioPlayer = nil
audioScheduler = nil  // NEW
```

**Step 8: Build and verify no compilation errors**

Run: `swift build`
Expected: Build complete!

**Step 9: Commit**

```bash
git add Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: integrate AudioScheduler into ResonateClient pipeline

- Add AudioScheduler between decoder and AudioPlayer
- Schedule chunks instead of immediate playback
- Start/stop scheduler with stream lifecycle
- Clear queue on stream end and disconnect"
```

---

## Task 7: Remove Old AudioPlayer Enqueue Method

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioPlayer.swift`

**Step 1: Comment out or mark deprecated the old enqueue method**

Find the `enqueue(chunk:)` method and add deprecation:

```swift
/// Enqueue audio chunk for playback
@available(*, deprecated, message: "Use AudioScheduler instead - chunks should be scheduled, not enqueued directly")
public func enqueue(chunk: BinaryMessage) async throws {
    // Old implementation - keeping for reference but deprecated
    // Remove in future version after scheduler is proven
    guard audioQueue != nil else {
        throw AudioPlayerError.notStarted
    }
    // ... rest of old code
}
```

**Step 2: Add note about accessing decoder**

Make decoder accessible for ResonateClient:

```swift
// Make decoder accessible for external decoding
nonisolated public var decoder: AudioDecoder? {
    get async {
        await self.decoder
    }
}

// Update private decoder property
private var decoder: AudioDecoder?  // Already exists, just verify it's accessible
```

Actually, looking at the code - decoder is already private. Let's refactor properly:

Add after `stop()` method:

```swift
/// Get the current decoder (for external use)
public var currentDecoder: AudioDecoder? {
    return decoder
}
```

**Step 3: Build to verify**

Run: `swift build`
Expected: Build complete!

**Step 4: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioPlayer.swift
git commit -m "refactor: deprecate direct enqueue in favor of AudioScheduler"
```

---

## Task 8: Add Logging and Debug Stats

**Files:**
- Modify: `Sources/ResonateKit/Audio/AudioScheduler.swift`
- Modify: `Sources/ResonateKit/Client/ResonateClient.swift`

**Step 1: Add detailed logging to AudioScheduler**

Modify `AudioScheduler.schedule()` to log first few chunks:

```swift
/// Schedule a PCM chunk for playback
public func schedule(pcm: Data, serverTimestamp: Int64) async {
    let receivedBefore = schedulerStats.received

    // Convert server timestamp to local playback time
    let localTimeMicros = await clockSync.serverTimeToLocal(serverTimestamp)
    let localTimeSeconds = Double(localTimeMicros) / 1_000_000.0
    let playTime = Date(timeIntervalSince1970: localTimeSeconds)

    // Log first 5 chunks for debugging
    if receivedBefore < 5 {
        let now = Date()
        let delay = playTime.timeIntervalSince(now)
        let offset = await clockSync.statsOffset
        let rtt = await clockSync.statsRtt

        print("[SCHEDULER] Chunk #\(receivedBefore): server_ts=\(serverTimestamp)μs, delay=\(Int(delay * 1000))ms, offset=\(offset)μs, rtt=\(rtt)μs")
    }

    // ... rest of method
}
```

**Step 2: Add periodic stats logging to ResonateClient**

Add after `runSchedulerOutput()` method:

```swift
nonisolated private func logSchedulerStats() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))

        guard let audioScheduler = await audioScheduler else { continue }
        let stats = await audioScheduler.stats

        print("[CLIENT] Scheduler stats: received=\(stats.received), played=\(stats.played), dropped=\(stats.dropped)")
    }
}
```

Start this task in `connect()` after starting other tasks:

```swift
// Start scheduler stats logging (detached)
Task.detached { [weak self] in
    await self?.logSchedulerStats()
}
```

**Step 3: Build to verify**

Run: `swift build`
Expected: Build complete!

**Step 4: Commit**

```bash
git add Sources/ResonateKit/Audio/AudioScheduler.swift Sources/ResonateKit/Client/ResonateClient.swift
git commit -m "feat: add debug logging for scheduler and stats reporting"
```

---

## Task 9: Manual Testing and Validation

**Files:**
- Create: `Examples/SchedulerTest/main.swift` (if Examples directory exists)

**Step 1: Create simple test app** (if applicable)

If your project has an Examples directory, create a simple CLI test:

```swift
import ResonateKit
import Foundation

@main
struct SchedulerTestApp {
    static func main() async {
        print("Testing AudioScheduler integration...")

        let client = ResonateClient(
            clientId: "scheduler-test",
            name: "Scheduler Test Client",
            roles: [.player],
            playerConfig: PlayerConfiguration(
                supportedFormats: [
                    AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16)
                ],
                bufferCapacity: 1_048_576
            )
        )

        // Connect to local test server (adjust URL as needed)
        guard let url = URL(string: "ws://localhost:8927/resonate") else {
            print("Invalid URL")
            return
        }

        do {
            try await client.connect(to: url)
            print("Connected! Monitoring scheduler stats...")

            // Keep running for 60 seconds
            try await Task.sleep(for: .seconds(60))

            await client.disconnect()
            print("Disconnected.")
        } catch {
            print("Error: \(error)")
        }
    }
}
```

**Step 2: Manual testing checklist**

Run your app/example and verify:

- [ ] Connection succeeds
- [ ] Initial clock sync completes (check logs)
- [ ] Scheduler receives chunks (check "Chunk #0-4" logs)
- [ ] Scheduler plays chunks (stats show played > 0)
- [ ] Late chunks are dropped if network is slow (stats show dropped)
- [ ] Audio plays smoothly without glitches
- [ ] Multiple restarts work correctly

**Step 3: Document test results**

Create test notes in a comment or separate file documenting:
- Server used for testing
- Network conditions
- Observed behavior
- Any issues found

**Step 4: Commit test app (if created)**

```bash
git add Examples/SchedulerTest/
git commit -m "test: add manual scheduler test application"
```

---

## Task 10: Final Verification and Documentation

**Files:**
- Modify: `README.md` (if exists)
- Create: `docs/CHANGELOG.md` entry

**Step 1: Update documentation**

If your project has a README, add a note about the scheduler:

```markdown
## Audio Synchronization

ResonateKit uses timestamp-based audio scheduling to ensure precise synchronization:

- **AudioScheduler**: Maintains priority queue of audio chunks
- **Clock Sync**: Compensates for clock drift using Kalman filter
- **Playback Window**: ±50ms tolerance for network jitter
- **Late Chunk Handling**: Drops chunks >50ms late to maintain sync
```

**Step 2: Add changelog entry**

Create or update `docs/CHANGELOG.md`:

```markdown
## [Unreleased]

### Added
- Timestamp-based audio scheduling via AudioScheduler
- Priority queue for chunk playback ordering
- Clock drift compensation in ClockSynchronizer
- Automatic late chunk dropping (>50ms)
- AsyncStream-based chunk output pipeline

### Changed
- AudioPlayer now accepts direct PCM playback
- ResonateClient uses scheduler instead of immediate playback
- Deprecated AudioPlayer.enqueue() method

### Fixed
- Audio synchronization issues caused by network jitter
- Progressive desync over time from clock drift
```

**Step 3: Run full test suite**

Run: `swift test`
Expected: All tests pass

**Step 4: Final commit**

```bash
git add README.md docs/CHANGELOG.md
git commit -m "docs: document AudioScheduler implementation and changes"
```

---

## Verification Checklist

Before marking complete, verify:

- [ ] All tests pass (`swift test`)
- [ ] Build succeeds (`swift build`)
- [ ] No compiler warnings
- [ ] Scheduler logs show first 5 chunks
- [ ] Stats logging works every 10 seconds
- [ ] Manual testing shows synchronized playback
- [ ] Late chunks are dropped correctly
- [ ] Queue overflow handled gracefully
- [ ] Stream start/end clears queue
- [ ] Disconnect cleans up properly

---

## Success Criteria

✅ **Implementation Complete When:**
1. All unit tests pass
2. AudioScheduler correctly schedules chunks based on timestamps
3. Clock synchronization integrates with scheduler
4. Late chunks (>50ms) are dropped
5. Audio plays smoothly without network jitter affecting timing
6. Stats show received/played/dropped counts
7. Manual testing confirms synchronization with Go client

## Related Skills

- @superpowers:test-driven-development - Follow TDD for all changes
- @superpowers:verification-before-completion - Verify tests pass before claiming done
- @superpowers:systematic-debugging - If issues arise, debug methodically
