// ABOUTME: Clock synchronization with drift compensation using Kalman filter approach
// ABOUTME: Tracks both offset AND drift rate to handle clock frequency differences

import Foundation

/// Quality of clock synchronization
public enum SyncQuality: Sendable {
    case good
    case degraded
    case lost
}

/// Synchronizes local clock with server clock using drift compensation
public actor ClockSynchronizer: ClockSyncProtocol {
    // Clock synchronization state
    private var offset: Int64 = 0           // Current offset in microseconds (server - client)
    private var drift: Double = 0.0         // Clock drift rate (dimensionless: μs/μs)
    private var rawOffset: Int64 = 0        // Latest raw offset measurement
    private var rtt: Int64 = 0              // Latest round-trip time
    private var quality: SyncQuality = .lost
    private var lastSyncTime: Date?
    private var lastSyncMicros: Int64 = 0   // Client time (μs) when offset/drift were last updated
    private var sampleCount: Int = 0
    private let smoothingRate: Double = 0.1 // 10% weight to new samples (Kalman gain)

    public init() {}

    /// Current clock offset in microseconds
    public var currentOffset: Int64 {
        return offset
    }

    /// Current sync quality
    public var currentQuality: SyncQuality {
        return quality
    }

    /// Get sync statistics
    public func getStats() -> (offset: Int64, rtt: Int64, quality: SyncQuality) {
        // Return tuple with named components for clarity
        return (offset: offset, rtt: rtt, quality: quality)
    }

    /// Get individual stats for Sendable contexts
    public var statsOffset: Int64 { offset }
    public var statsRtt: Int64 { rtt }
    public var statsQuality: SyncQuality { quality }

    /// Process server time message to update offset and drift
    public func processServerTime(
        clientTransmitted: Int64,     // t1
        serverReceived: Int64,        // t2
        serverTransmitted: Int64,     // t3
        clientReceived: Int64         // t4
    ) {
        // Calculate RTT and measured offset
        let (calculatedRtt, measuredOffset) = calculateOffset(
            t1: clientTransmitted,
            t2: serverReceived,
            t3: serverTransmitted,
            t4: clientReceived
        )

        self.rtt = calculatedRtt
        self.rawOffset = measuredOffset
        self.lastSyncTime = Date()

        // Debug logging for first few syncs
        if sampleCount < 3 {
            print("[SYNC] Raw timestamps: t1=\(clientTransmitted), t2=\(serverReceived), t3=\(serverTransmitted), t4=\(clientReceived)")
            print("[SYNC] Calculated: rtt=\(calculatedRtt)μs, measured_offset=\(measuredOffset)μs")
        }

        // Discard samples with negative RTT (timestamp issues)
        if calculatedRtt < 0 {
            print("[SYNC] Discarding sync sample: negative RTT \(calculatedRtt)μs (timestamp issue)")
            return
        }

        // Discard samples with high RTT (network congestion)
        if calculatedRtt > 100_000 { // 100ms
            print("[SYNC] Discarding sync sample: high RTT \(calculatedRtt)μs")
            return
        }

        // First sync: initialize offset, no drift yet
        if sampleCount == 0 {
            offset = measuredOffset
            lastSyncMicros = clientReceived
            sampleCount += 1
            quality = .good
            print("[SYNC] Initial sync: offset=\(offset)μs, rtt=\(calculatedRtt)μs")
            return
        }

        // Second sync: calculate initial drift
        if sampleCount == 1 {
            let dt = Double(clientReceived - lastSyncMicros)
            if dt > 0 {
                // Drift = change in offset over time
                drift = Double(measuredOffset - offset) / dt
                print("[SYNC] Drift initialized: drift=\(String(format: "%.9f", drift)) μs/μs over Δt=\(Int(dt))μs")
            }
            offset = measuredOffset
            lastSyncMicros = clientReceived
            sampleCount += 1
            quality = .good
            print("[SYNC] Second sync: offset=\(offset)μs, drift=\(String(format: "%.9f", drift)), rtt=\(calculatedRtt)μs")
            return
        }

        // Subsequent syncs: predict offset using drift, then update both
        let dt = Double(clientReceived - lastSyncMicros)
        if dt <= 0 {
            print("[SYNC] Discarding sync sample: non-monotonic time")
            return
        }

        // Predict what offset should be based on drift
        let predictedOffset = offset + Int64(drift * dt)

        // Residual = how much our prediction was off
        let residual = measuredOffset - predictedOffset

        // Reject outliers (residual > 50ms suggests network issue or clock jump)
        if abs(residual) > 50_000 {
            print("[SYNC] Discarding sync sample: large residual \(residual)μs (possible clock jump)")
            return
        }

        // Update offset from PREDICTED offset plus gain * residual
        // This is the Kalman filter update formula (simplified with fixed gain)
        offset = predictedOffset + Int64(smoothingRate * Double(residual))

        // Update drift: drift correction is residual / dt
        // This estimates how much the drift rate needs to change
        let driftCorrection = Double(residual) / dt
        drift = drift + smoothingRate * driftCorrection

        lastSyncMicros = clientReceived
        sampleCount += 1

        // Update quality based on RTT
        if calculatedRtt < 50_000 { // <50ms
            quality = .good
        } else {
            quality = .degraded
        }

        if sampleCount < 10 {
            print("[SYNC] Sync #\(sampleCount): offset=\(offset)μs, drift=\(String(format: "%.9f", drift)), residual=\(residual)μs, rtt=\(calculatedRtt)μs")
        }
    }

    /// Calculate RTT and clock offset from timestamps
    private func calculateOffset(t1: Int64, t2: Int64, t3: Int64, t4: Int64) -> (rtt: Int64, offset: Int64) {
        // Round-trip time
        // RTT = (receive_time - send_time) - (server_transmit - server_receive)
        let rtt = (t4 - t1) - (t3 - t2)

        // Estimated offset (positive = server ahead of client)
        // offset = ((server_receive - client_transmit) + (server_transmit - client_receive)) / 2
        let offset = ((t2 - t1) + (t3 - t4)) / 2

        return (rtt, offset)
    }

    /// Convert server timestamp to local time
    /// Accounts for both offset and drift over time
    public func serverTimeToLocal(_ serverTime: Int64) -> Int64 {
        // If we haven't synced yet, assume server time = client time
        if sampleCount == 0 {
            return serverTime
        }

        // Inverse of the forward transform:
        // server_time = client_time + offset + drift * (client_time - last_sync)
        // Rearranging: server_time = client_time * (1 + drift) + offset - drift * last_sync
        // Solving: client_time = (server_time - offset + drift * last_sync) / (1 + drift)

        let denominator = 1.0 + drift

        // Guard against division by zero (would require drift = -1.0, extremely unlikely)
        guard abs(denominator) > 1e-10 else {
            // Fallback to simple offset if drift is pathological
            print("[SYNC] WARNING: Pathological drift detected (\(drift)), using simple offset")
            return serverTime - offset
        }

        let numerator = Double(serverTime) - Double(offset) + drift * Double(lastSyncMicros)
        let clientMicros = Int64(numerator / denominator)

        return clientMicros
    }

    /// Convert local timestamp to server time
    /// Accounts for both offset and drift over time
    public func localTimeToServer(_ localTime: Int64) -> Int64 {
        // If we haven't synced yet, assume client time = server time
        if sampleCount == 0 {
            return localTime
        }

        // Apply offset and drift: server_time = client_time + offset + drift * (client_time - last_sync)
        let dt = localTime - lastSyncMicros
        let serverTime = localTime + offset + Int64(drift * Double(dt))

        return serverTime
    }

    /// Check and update quality based on time since last sync
    public func checkQuality() -> SyncQuality {
        if let lastSync = lastSyncTime, Date().timeIntervalSince(lastSync) > 5.0 {
            quality = .lost
        }
        return quality
    }

    /// Reset clock synchronization (e.g., after reconnection)
    public func reset() {
        offset = 0
        drift = 0.0
        rawOffset = 0
        rtt = 0
        quality = .lost
        lastSyncTime = nil
        lastSyncMicros = 0
        sampleCount = 0
        print("[SYNC] Clock synchronization reset")
    }
}
