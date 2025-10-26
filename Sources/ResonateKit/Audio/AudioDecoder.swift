// ABOUTME: Audio decoder for FLAC, Opus, and PCM codecs
// ABOUTME: Converts compressed audio to PCM for playback (stub for now)

import AVFoundation
import Foundation

/// Audio decoder protocol
public protocol AudioDecoder {
    func decode(_ data: Data) throws -> Data
}

/// PCM pass-through decoder
public class PCMDecoder: AudioDecoder {
    public init() {}

    public func decode(_ data: Data) throws -> Data {
        return data // No decoding needed for PCM
    }
}

/// Creates decoder for specified codec
public enum AudioDecoderFactory {
    public static func create(
        codec: AudioCodec,
        sampleRate _: Int,
        channels _: Int,
        bitDepth _: Int,
        header _: Data?
    ) throws -> AudioDecoder {
        switch codec {
        case .pcm:
            return PCMDecoder()
        case .opus, .flac:
            // TODO: Implement using AVAudioConverter or AudioToolbox
            fatalError("Opus/FLAC decoding not yet implemented")
        }
    }
}
