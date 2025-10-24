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
}

// Mock ClockSynchronizer for testing
actor MockClockSynchronizer: ClockSyncProtocol {
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
