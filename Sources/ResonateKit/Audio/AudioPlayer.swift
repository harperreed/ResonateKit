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

    public var isPlaying: Bool {
        return _isPlaying
    }

    public init(bufferManager: BufferManager, clockSync: ClockSynchronizer) {
        self.bufferManager = bufferManager
        self.clockSync = clockSync
    }

    // Cleanup happens in stop() method called explicitly before deallocation
    // AudioQueue will be disposed when stop() is called or connection is closed
}
