// ABOUTME: Configuration for player role capabilities
// ABOUTME: Specifies buffer capacity and supported audio formats

import Foundation

/// Configuration for player role
public struct PlayerConfiguration: Sendable {
    /// Buffer capacity in bytes
    public let bufferCapacity: Int

    /// Supported audio formats in priority order
    public let supportedFormats: [AudioFormatSpec]

    public init(bufferCapacity: Int, supportedFormats: [AudioFormatSpec]) {
        self.bufferCapacity = bufferCapacity
        self.supportedFormats = supportedFormats
    }
}
