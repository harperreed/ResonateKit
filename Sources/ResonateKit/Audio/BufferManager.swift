// ABOUTME: Tracks buffered audio chunks to implement backpressure
// ABOUTME: Prevents buffer overflow by tracking consumed vs. pending chunks

import Foundation

/// Manages audio buffer tracking for backpressure control
public actor BufferManager {
    private let capacity: Int
    private var bufferedChunks: [(endTimeMicros: Int64, byteCount: Int)] = []
    private var bufferedBytes: Int = 0

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Check if buffer has capacity for additional bytes
    public func hasCapacity(_ bytes: Int) -> Bool {
        return bufferedBytes + bytes <= capacity
    }

    /// Register a chunk added to the buffer
    public func register(endTimeMicros: Int64, byteCount: Int) {
        bufferedChunks.append((endTimeMicros, byteCount))
        bufferedBytes += byteCount
    }

    /// Remove chunks that have finished playing
    public func pruneConsumed(nowMicros: Int64) {
        while let first = bufferedChunks.first, first.endTimeMicros <= nowMicros {
            bufferedBytes -= first.byteCount
            bufferedChunks.removeFirst()
        }
        bufferedBytes = max(bufferedBytes, 0)
    }

    /// Current buffer usage in bytes
    public var usage: Int {
        return bufferedBytes
    }
}
