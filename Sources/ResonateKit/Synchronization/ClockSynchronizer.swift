// ABOUTME: Maintains clock synchronization between client and server using NTP-style algorithm
// ABOUTME: Tracks offset samples and uses median to filter network jitter

import Foundation

/// Synchronizes local clock with server clock
public actor ClockSynchronizer {
    private var offsetSamples: [Int64] = []
    private let maxSamples = 10

    public init() {}

    /// Current clock offset (median of samples)
    /// Uses median to filter out network jitter outliers
    public var currentOffset: Int64 {
        guard !offsetSamples.isEmpty else { return 0 }
        let sorted = offsetSamples.sorted()

        // True median calculation
        if sorted.count % 2 == 0 {
            // Even number: average of two middle elements
            let mid1 = sorted[sorted.count / 2 - 1]
            let mid2 = sorted[sorted.count / 2]
            return (mid1 + mid2) / 2
        } else {
            // Odd number: middle element
            return sorted[sorted.count / 2]
        }
    }

    /// Process server time message to update offset
    public func processServerTime(
        clientTransmitted: Int64,
        serverReceived: Int64,
        serverTransmitted: Int64,
        clientReceived: Int64
    ) {
        // Validate timestamps are non-negative
        guard clientTransmitted >= 0, serverReceived >= 0,
              serverTransmitted >= 0, clientReceived >= 0 else {
            return  // Silently ignore invalid samples
        }

        // Validate timestamps are in reasonable order
        guard clientReceived >= clientTransmitted,
              serverTransmitted >= serverReceived else {
            return  // Silently ignore out-of-order samples
        }

        // NTP-style calculation
        // Round-trip delay: (t4 - t1) - (t3 - t2)
        // We calculate this for potential future use in filtering high-latency samples
        _ = (clientReceived - clientTransmitted) - (serverTransmitted - serverReceived)

        // Clock offset: ((t2 - t1) + (t3 - t4)) / 2
        let offset = ((serverReceived - clientTransmitted) + (serverTransmitted - clientReceived)) / 2

        offsetSamples.append(offset)
        if offsetSamples.count > maxSamples {
            offsetSamples.removeFirst()
        }
    }

    /// Convert server timestamp to local time
    public func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        return serverTime - currentOffset
    }

    /// Convert local timestamp to server time
    public func localTimeToServer(_ localTime: Int64) -> Int64 {
        return localTime + currentOffset
    }

    /// Reset clock synchronization (e.g., after reconnection)
    public func reset() {
        offsetSamples.removeAll()
    }
}
