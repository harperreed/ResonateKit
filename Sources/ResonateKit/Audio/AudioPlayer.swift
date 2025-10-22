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

    private var pendingChunks: [(timestamp: Int64, data: Data)] = []
    private let maxPendingChunks = 50

    public var isPlaying: Bool {
        return _isPlaying
    }

    public init(bufferManager: BufferManager, clockSync: ClockSynchronizer) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
    }

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

    /// Enqueue audio chunk for playback
    public func enqueue(chunk: BinaryMessage) async throws {
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

    // Cleanup happens in stop() method called explicitly before deallocation
    // AudioQueue will be disposed when stop() is called or connection is closed
}

// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    // TODO: Implement in next task
}

public enum AudioPlayerError: Error {
    case queueCreationFailed
    case notStarted
    case decodingFailed
    case bufferFull
}
