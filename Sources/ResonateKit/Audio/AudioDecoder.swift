// ABOUTME: Audio decoder for FLAC, Opus, and PCM codecs
// ABOUTME: Converts compressed audio to PCM for playback (stub for now)

import Foundation
import AVFoundation

/// Audio decoder protocol
protocol AudioDecoder {
    func decode(_ data: Data) throws -> Data
}

/// PCM pass-through decoder
class PCMDecoder: AudioDecoder {
    func decode(_ data: Data) throws -> Data {
        return data // No decoding needed for PCM
    }
}

/// Creates decoder for specified codec
enum AudioDecoderFactory {
    static func create(
        codec: AudioCodec,
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        header: Data?
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
