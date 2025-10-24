# Audio Scheduler Design

**Date:** 2025-10-24
**Status:** Approved for Implementation
**Author:** Claude + Harper

## Problem Statement

The current Swift ResonateKit implementation plays audio chunks immediately upon receipt, without timestamp-based scheduling. This causes synchronization issues because:

- Chunks play at network speed, not server timeline
- Network jitter directly affects playback timing
- No compensation for late/early chunks
- Even perfect clock sync can't help without scheduled playback

The working Go implementation has a Scheduler component that we're missing. This document designs the Swift equivalent.

## Current Architecture Issues

**Current Flow (Broken):**
```
WebSocket → Binary Message → Decode → AudioPlayer (immediate playback) ❌
```

**Problems:**
1. AudioPlayer line 222 has TODO about timestamp scheduling
2. `pendingChunks` queue plays chunks in arrival order, not timestamp order
3. No dropping of late chunks
4. No compensation for network jitter

## Proposed Architecture

**New Flow (Correct):**
```
WebSocket → Binary Message → Decode → AudioScheduler → AudioPlayer
                                          ↓
                                    Priority Queue
                                    Timer (10ms)
                                    Timestamp Conversion
```

### Core Components

#### 1. AudioScheduler Actor

**Responsibilities:**
- Accept decoded PCM chunks with server timestamps
- Convert server timestamps to local playback times using ClockSynchronizer
- Maintain priority queue sorted by playback time
- Check queue every 10ms for chunks ready to play
- Drop chunks >50ms late
- Output chunks within ±50ms window

**Public API:**
```swift
public actor AudioScheduler {
    public init(clockSync: ClockSynchronizer, playbackWindow: TimeInterval = 0.05)

    public func schedule(pcm: Data, serverTimestamp: Int64) async
    public func startScheduling() async
    public func stop() async
    public func clear() async

    public let scheduledChunks: AsyncStream<ScheduledChunk>
    public var stats: SchedulerStats { get }
}

public struct ScheduledChunk: Sendable {
    public let pcmData: Data
    public let playTime: Date
    public let originalTimestamp: Int64
}

public struct SchedulerStats: Sendable {
    public let received: Int
    public let played: Int
    public let dropped: Int
}
```

#### 2. AudioPlayer Refactoring

**Changes Required:**
- Remove `pendingChunks` and `pendingChunksLock`
- Remove `enqueue(chunk:)` method
- Add simple `playPCM(_:format:)` method for immediate playback
- Keep AudioQueue management, volume/mute controls

**New API:**
```swift
public actor AudioPlayer {
    public func start(format: AudioFormatSpec, codecHeader: Data?) throws
    public func playPCM(_ pcmData: Data) async throws  // New: direct PCM playback
    public func stop()
    public func setVolume(_ volume: Float)
    public func setMute(_ muted: Bool)
}
```

#### 3. Integration in ResonateClient

**New Pipeline Handler:**
```swift
// In ResonateClient.connect()
let scheduler = AudioScheduler(clockSync: clockSync)

// Start scheduler output consumer
Task.detached {
    for await chunk in scheduler.scheduledChunks {
        try? await audioPlayer.playPCM(chunk.pcmData)
    }
}

// In handleAudioChunk()
let pcm = try decoder.decode(message.data)
await scheduler.schedule(pcm: pcm, serverTimestamp: message.timestamp)
```

### Scheduler Algorithm

**Priority Queue:**
- Simple sorted array (chunks mostly arrive in order)
- Insert using binary search to maintain sort by playTime
- Alternative: Use Swift Collections Heap for O(log n) operations

**Timer Loop:**
```swift
private func checkQueue() async {
    let now = Date()

    while let next = queue.first {
        let delay = next.playTime.timeIntervalSince(now)

        if delay > playbackWindow {
            break  // Too early, wait
        } else if delay < -playbackWindow {
            queue.removeFirst()
            stats.dropped += 1
            // Log drop for first 10
        } else {
            queue.removeFirst()
            chunkOutput.yield(next)
            stats.played += 1
        }
    }
}
```

**Timing:**
- Check every 10ms (matches Go implementation)
- ±50ms playback window
- Drop chunks >50ms late
- Buffer chunks >50ms early

## Error Handling

### Late Chunks
- Drop chunks >50ms past playback time
- Log first 10 drops with timing details
- Track drop count in stats

### Clock Sync Quality
- Continue scheduling even with degraded sync
- Current simplified Kalman filter adequate for MVP
- Future: Integrate Resonate time-filter library

### Queue Overflow
- Max 100 chunks in queue (configurable)
- Drop oldest if exceeded
- Indicates network/player speed mismatch

### Stream Lifecycle
- `stream/start`: Clear scheduler queue
- `stream/end`: Drain queue, stop scheduling
- Format changes: Clear queue (safest)

### Graceful Degradation
- If clock sync fails entirely, fall back to immediate playback
- Log warning but keep audio flowing
- Better than silence

## Testing Strategy

### Unit Tests
- Mock ClockSynchronizer with fixed offset/drift
- Schedule chunks with known timestamps
- Verify chunks output at correct times (±10ms tolerance)
- Test late chunk dropping (>50ms)
- Test early chunk buffering
- Test queue overflow handling

### Integration Tests
- Full pipeline: ResonateClient → Decoder → Scheduler → AudioPlayer
- Mock WebSocket sending chunks at various rates
- Verify synchronized playback under:
  - Perfect network (in-order arrival)
  - Jittery network (out-of-order arrival)
  - Slow network (late arrival)

### Manual Testing
- Connect to real Resonate server
- Compare Swift vs. Go client sync quality
- Audio analysis to measure sync accuracy
- Test with multiple clients in same group

### Success Criteria
- Chunks play within ±50ms of intended time
- Late chunks dropped cleanly
- No audio glitches during normal playback
- Memory usage stable

## Implementation Plan

### Phase 1: AudioScheduler Core
1. Create `AudioScheduler.swift` with basic structure
2. Implement priority queue with sorted array
3. Implement timer loop with 10ms interval
4. Add timestamp conversion using ClockSynchronizer
5. Implement AsyncStream output

### Phase 2: AudioPlayer Refactoring
1. Remove `pendingChunks` queue
2. Remove `enqueue(chunk:)` method
3. Add `playPCM(_:)` for direct playback
4. Simplify `fillBuffer()` to just copy PCM data

### Phase 3: Integration
1. Update ResonateClient to use AudioScheduler
2. Move decoding before scheduling
3. Connect scheduler output to AudioPlayer
4. Update stream lifecycle handling

### Phase 4: Testing & Validation
1. Write unit tests for scheduler
2. Write integration tests
3. Manual testing with real server
4. Performance profiling
5. Tune parameters if needed

## Future Enhancements

### Phase 5 (Optional): Advanced Clock Sync
- Port Resonate time-filter library to Swift
- Replace simplified Kalman with full implementation
- Add covariance tracking for quality metrics
- Implement adaptive forgetting factor

### Performance Optimizations
- Use Swift Collections Heap instead of sorted array
- Batch chunk processing
- Optimize memory allocations

## References

- Go implementation: `internal/player/scheduler.go`
- Resonate time-filter: https://github.com/Resonate-Protocol/time-filter
- Current AudioPlayer: `Sources/ResonateKit/Audio/AudioPlayer.swift:222` (TODO comment)
