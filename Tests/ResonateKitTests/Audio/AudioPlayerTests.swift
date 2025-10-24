import Testing
import Foundation
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

    @Test("Play PCM data directly")
    func testPlayPCM() async throws {
        let bufferManager = BufferManager(capacity: 1_048_576)
        let clockSync = ClockSynchronizer()
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
