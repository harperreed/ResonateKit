// ABOUTME: Timestamp-based audio playback scheduler with priority queue
// ABOUTME: Converts server timestamps to local time and schedules precise playback

import Foundation

/// Protocol for clock synchronization
public protocol ClockSyncProtocol: Actor {
    func serverTimeToLocal(_ serverTime: Int64) -> Int64
}

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
public actor AudioScheduler<ClockSync: ClockSyncProtocol> {
    private let clockSync: ClockSync
    private let playbackWindow: TimeInterval
    private var queue: [ScheduledChunk] = []
    private var schedulerStats: SchedulerStats

    public init(clockSync: ClockSync, playbackWindow: TimeInterval = 0.05) {
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
