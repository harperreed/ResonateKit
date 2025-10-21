// ABOUTME: Core protocol message types for Resonate client-server communication
// ABOUTME: All messages follow the pattern: { "type": "...", "payload": {...} }

import Foundation

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
    public let supportedFormats: [AudioFormatSpec]
    public let bufferCapacity: Int
    public let supportedCommands: [PlayerCommand]

    public init(supportedFormats: [AudioFormatSpec], bufferCapacity: Int, supportedCommands: [PlayerCommand]) {
        self.supportedFormats = supportedFormats
        self.bufferCapacity = bufferCapacity
        self.supportedCommands = supportedCommands
    }
}

public struct ArtworkSupport: Codable, Sendable {
    // TODO: Implement when artwork role is added
}

public struct VisualizerSupport: Codable, Sendable {
    // TODO: Implement when visualizer role is added
}

// MARK: - Server Messages

/// Server hello response
public struct ServerHelloMessage: ResonateMessage {
    public let type = "server/hello"
    public let payload: ServerHelloPayload
}

public struct ServerHelloPayload: Codable, Sendable {
    public let serverId: String
    public let name: String
    public let version: Int
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
}

public struct ServerTimePayload: Codable, Sendable {
    public let clientTransmitted: Int64
    public let serverReceived: Int64
    public let serverTransmitted: Int64
}
