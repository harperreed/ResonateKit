// ABOUTME: Core protocol message types for Resonate client-server communication
// ABOUTME: All messages follow the pattern: { "type": "...", "payload": {...} }

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Base protocol for all Resonate messages
public protocol ResonateMessage: Codable, Sendable {
    var type: String { get }
}

// MARK: - Client Messages

/// Client hello message sent after WebSocket connection
public struct ClientHelloMessage: ResonateMessage {
    public let type = "client/hello"
    public let payload: ClientHelloPayload

    public init(payload: ClientHelloPayload) {
        self.payload = payload
    }
}

public struct ClientHelloPayload: Codable, Sendable {
    public let clientId: String
    public let name: String
    public let deviceInfo: DeviceInfo?
    public let version: Int
    public let supportedRoles: [ClientRole]
    public let playerSupport: PlayerSupport?
    public let artworkSupport: ArtworkSupport?
    public let visualizerSupport: VisualizerSupport?

    public init(
        clientId: String,
        name: String,
        deviceInfo: DeviceInfo?,
        version: Int,
        supportedRoles: [ClientRole],
        playerSupport: PlayerSupport?,
        artworkSupport: ArtworkSupport?,
        visualizerSupport: VisualizerSupport?
    ) {
        self.clientId = clientId
        self.name = name
        self.deviceInfo = deviceInfo
        self.version = version
        self.supportedRoles = supportedRoles
        self.playerSupport = playerSupport
        self.artworkSupport = artworkSupport
        self.visualizerSupport = visualizerSupport
    }
}

public struct DeviceInfo: Codable, Sendable {
    public let productName: String?
    public let manufacturer: String?
    public let softwareVersion: String?

    public init(productName: String?, manufacturer: String?, softwareVersion: String?) {
        self.productName = productName
        self.manufacturer = manufacturer
        self.softwareVersion = softwareVersion
    }

    public static var current: DeviceInfo {
        #if os(iOS)
        return DeviceInfo(
            productName: UIDevice.current.model,
            manufacturer: "Apple",
            softwareVersion: UIDevice.current.systemVersion
        )
        #elseif os(macOS)
        return DeviceInfo(
            productName: "Mac",
            manufacturer: "Apple",
            softwareVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        #else
        return DeviceInfo(productName: nil, manufacturer: "Apple", softwareVersion: nil)
        #endif
    }
}

public enum PlayerCommand: String, Codable, Sendable {
    case volume
    case mute
}

public struct PlayerSupport: Codable, Sendable {
    public let supportFormats: [AudioFormatSpec]
    public let supportCodecs: [String]
    public let supportChannels: [Int]
    public let supportSampleRates: [Int]
    public let supportBitDepth: [Int]
    public let bufferCapacity: Int
    public let supportedCommands: [PlayerCommand]

    public init(supportFormats: [AudioFormatSpec], bufferCapacity: Int, supportedCommands: [PlayerCommand]) {
        self.supportFormats = supportFormats
        // Extract unique values from formats for Music Assistant compatibility
        self.supportCodecs = Array(Set(supportFormats.map { $0.codec.rawValue })).sorted()
        self.supportChannels = Array(Set(supportFormats.map { $0.channels })).sorted()
        self.supportSampleRates = Array(Set(supportFormats.map { $0.sampleRate })).sorted()
        self.supportBitDepth = Array(Set(supportFormats.map { $0.bitDepth })).sorted()
        self.bufferCapacity = bufferCapacity
        self.supportedCommands = supportedCommands
    }
}

public struct ArtworkSupport: Codable, Sendable {
    // TODO: Implement when artwork role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}

public struct VisualizerSupport: Codable, Sendable {
    // TODO: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}

// MARK: - Server Messages

/// Server hello response
public struct ServerHelloMessage: ResonateMessage {
    public let type = "server/hello"
    public let payload: ServerHelloPayload

    public init(payload: ServerHelloPayload) {
        self.payload = payload
    }
}

public struct ServerHelloPayload: Codable, Sendable {
    public let serverId: String
    public let name: String
    public let version: Int

    public init(serverId: String, name: String, version: Int) {
        self.serverId = serverId
        self.name = name
        self.version = version
    }
}

/// Client time message for clock sync
public struct ClientTimeMessage: ResonateMessage {
    public let type = "client/time"
    public let payload: ClientTimePayload

    public init(payload: ClientTimePayload) {
        self.payload = payload
    }
}

public struct ClientTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64

    public init(clientTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
    }
}

/// Server time response for clock sync
public struct ServerTimeMessage: ResonateMessage {
    public let type = "server/time"
    public let payload: ServerTimePayload

    public init(payload: ServerTimePayload) {
        self.payload = payload
    }
}

public struct ServerTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64
    public let serverReceived: Int64
    public let serverTransmitted: Int64

    public init(clientTransmitted: Int64, serverReceived: Int64, serverTransmitted: Int64) {
        self.clientTransmitted = clientTransmitted
        self.serverReceived = serverReceived
        self.serverTransmitted = serverTransmitted
    }
}

// MARK: - State Messages

/// Player state update message (sent by clients to report current state)
/// Matches Go implementation which uses "player/update" message type
public struct PlayerUpdateMessage: ResonateMessage {
    public let type = "player/update"
    public let payload: PlayerUpdatePayload

    public init(payload: PlayerUpdatePayload) {
        self.payload = payload
    }
}

public struct PlayerUpdatePayload: Codable, Sendable {
    /// Synchronization state: "synchronized" or "error"
    public let state: String
    /// Volume level (0-100)
    public let volume: Int
    /// Mute state
    public let muted: Bool

    public init(state: String, volume: Int, muted: Bool) {
        precondition(state == "synchronized" || state == "error", "State must be 'synchronized' or 'error'")
        precondition(volume >= 0 && volume <= 100, "Volume must be between 0 and 100")

        self.state = state
        self.volume = volume
        self.muted = muted
    }
}

// Legacy type aliases for backward compatibility
@available(*, deprecated, renamed: "PlayerUpdateMessage", message: "Use PlayerUpdateMessage instead to match protocol spec")
public typealias ClientStateMessage = PlayerUpdateMessage
@available(*, deprecated, renamed: "PlayerUpdatePayload", message: "Use PlayerUpdatePayload instead to match protocol spec")
public typealias ClientStatePayload = PlayerUpdatePayload
@available(*, deprecated, renamed: "PlayerUpdatePayload", message: "Use PlayerUpdatePayload instead to match protocol spec")
public typealias PlayerState = PlayerUpdatePayload

// MARK: - Stream Messages

/// Stream start message
public struct StreamStartMessage: ResonateMessage {
    public let type = "stream/start"
    public let payload: StreamStartPayload

    public init(payload: StreamStartPayload) {
        self.payload = payload
    }
}

public struct StreamStartPayload: Codable, Sendable {
    public let player: StreamStartPlayer?
    public let artwork: StreamStartArtwork?
    public let visualizer: StreamStartVisualizer?

    public init(player: StreamStartPlayer?, artwork: StreamStartArtwork?, visualizer: StreamStartVisualizer?) {
        self.player = player
        self.artwork = artwork
        self.visualizer = visualizer
    }
}

public struct StreamStartPlayer: Codable, Sendable {
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let bitDepth: Int
    public let codecHeader: String?

    public init(codec: String, sampleRate: Int, channels: Int, bitDepth: Int, codecHeader: String?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.codecHeader = codecHeader
    }
}

public struct StreamStartArtwork: Codable, Sendable {
    // TODO: Implement when artwork role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}

public struct StreamStartVisualizer: Codable, Sendable {
    // TODO: Implement when visualizer role is added

    public init() {}

    // Explicit Codable implementation for empty struct
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}

/// Stream end message
public struct StreamEndMessage: ResonateMessage {
    public let type = "stream/end"

    public init() {}
}

/// Group update message
public struct GroupUpdateMessage: ResonateMessage {
    public let type = "group/update"
    public let payload: GroupUpdatePayload

    public init(payload: GroupUpdatePayload) {
        self.payload = payload
    }
}

public struct GroupUpdatePayload: Codable, Sendable {
    public let playbackState: String?
    public let groupId: String?
    public let groupName: String?

    public init(playbackState: String?, groupId: String?, groupName: String?) {
        self.playbackState = playbackState
        self.groupId = groupId
        self.groupName = groupName
    }
}
