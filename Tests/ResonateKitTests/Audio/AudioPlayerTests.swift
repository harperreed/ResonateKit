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
