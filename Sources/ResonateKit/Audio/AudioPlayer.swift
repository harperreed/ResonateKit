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

    // Use NSLock for thread-safe access from AudioQueue callback (nonisolated)
    // Both lock and data must be nonisolated since we manage thread-safety manually
    private nonisolated let pendingChunksLock = NSLock()
    private nonisolated(unsafe) var pendingChunks: [(timestamp: Int64, data: Data)] = []
    private let maxPendingChunks = 50

    private var currentVolume: Float = 1.0
    private var isMuted: Bool = false

    public var isPlaying: Bool {
        return _isPlaying
    }

    public var volume: Float {
        return currentVolume
    }

    public var muted: Bool {
        return isMuted
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

        // Allocate and prime buffers BEFORE starting the queue
        let bufferSize: UInt32 = 16384  // 16KB per buffer
        for _ in 0..<3 {  // 3 buffers for smooth playback
            var buffer: AudioQueueBufferRef?
            let status = AudioQueueAllocateBuffer(queue, bufferSize, &buffer)

            if status == noErr, let buffer = buffer {
                // Prime buffer with initial chunk
                fillBuffer(queue: queue, buffer: buffer)
            }
        }

        // Start the queue AFTER buffers are enqueued
        print("[AUDIO] Starting AudioQueue with \(3) primed buffers")
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

        // Clear pending chunks to prevent stale audio on restart (using withLock for async context)
        pendingChunksLock.withLock {
            pendingChunks.removeAll()
        }
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

        // Store pending chunk (thread-safe) using withLock for async context
        let count = pendingChunksLock.withLock {
            pendingChunks.append((timestamp: localTimestamp, data: pcmData))

            // Limit pending queue size
            if pendingChunks.count > maxPendingChunks {
                pendingChunks.removeFirst()
            }

            return pendingChunks.count
        }

        print("[AUDIO] Enqueued chunk: \(pcmData.count) bytes, timestamp: \(localTimestamp), pending: \(count)")
    }

    /// Decode compressed audio data to PCM
    public func decode(_ data: Data) throws -> Data {
        guard let decoder = decoder else {
            throw AudioPlayerError.notStarted
        }
        return try decoder.decode(data)
    }

    /// Play PCM data directly (for scheduled playback)
    public func playPCM(_ pcmData: Data) async throws {
        guard audioQueue != nil, currentFormat != nil else {
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

    nonisolated fileprivate func fillBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        // Synchronously get next chunk - this is safe because AudioQueue manages its own thread
        let chunkData = getNextChunkSync()

        guard let chunk = chunkData else {
            // No data available - enqueue silence
            print("[AUDIO] No chunk available, enqueueing silence")
            memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        print("[AUDIO] Filling buffer with \(chunk.data.count) bytes at timestamp \(chunk.timestamp)")

        // Copy chunk data to buffer
        let copySize = min(chunk.data.count, Int(buffer.pointee.mAudioDataBytesCapacity))
        _ = chunk.data.withUnsafeBytes { srcBytes in
            memcpy(buffer.pointee.mAudioData, srcBytes.baseAddress, copySize)
        }

        buffer.pointee.mAudioDataByteSize = UInt32(copySize)

        // Enqueue buffer for immediate playback
        // TODO: For synchronized playback, we need to properly convert chunk.timestamp
        // to AudioQueue time using AudioQueueGetCurrentTime and calculate offset
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        print("[AUDIO] Buffer enqueued for immediate playback")

        // Update buffer manager asynchronously
        pruneBufferAsync()
    }

    private nonisolated func getNextChunkSync() -> (timestamp: Int64, data: Data)? {
        // Thread-safe access using NSLock - can be called from any thread
        pendingChunksLock.lock()
        defer { pendingChunksLock.unlock() }

        guard !pendingChunks.isEmpty else {
            return nil
        }
        return pendingChunks.removeFirst()
    }

    private nonisolated func pruneBufferAsync() {
        // Schedule buffer pruning on the actor
        Task {
            await self.pruneBuffer()
        }
    }

    private func pruneBuffer() async {
        await bufferManager.pruneConsumed(nowMicros: getCurrentMicroseconds())
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

    // Cleanup happens in stop() method called explicitly before deallocation
    // AudioQueue will be disposed when stop() is called or connection is closed
}

// AudioQueue callback (C function)
private let audioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    print("[AUDIO] Callback invoked! Buffer needs refilling")
    guard let userData = userData else {
        print("[AUDIO] ERROR: userData is nil in callback")
        return
    }

    let player = Unmanaged<AudioPlayer>.fromOpaque(userData).takeUnretainedValue()

    // Call nonisolated method directly from callback
    player.fillBuffer(queue: queue, buffer: buffer)
}

public enum AudioPlayerError: Error {
    case queueCreationFailed
    case notStarted
    case decodingFailed
    case bufferFull
}
