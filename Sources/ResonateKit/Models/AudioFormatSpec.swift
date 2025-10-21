// ABOUTME: Specifies an audio format with codec, sample rate, channels, and bit depth
// ABOUTME: Used to negotiate audio format between client and server

/// Specification for an audio format
public struct AudioFormatSpec: Codable, Sendable, Hashable {
    /// Audio codec
    public let codec: AudioCodec
    /// Number of channels (1 = mono, 2 = stereo)
    public let channels: Int
    /// Sample rate in Hz (e.g., 44100, 48000)
    public let sampleRate: Int
    /// Bit depth (16 or 24)
    public let bitDepth: Int

    public init(codec: AudioCodec, channels: Int, sampleRate: Int, bitDepth: Int) {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}
