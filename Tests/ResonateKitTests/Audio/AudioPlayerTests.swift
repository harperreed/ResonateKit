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
}
