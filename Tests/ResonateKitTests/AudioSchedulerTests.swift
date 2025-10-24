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
