// ABOUTME: Audio decoder for FLAC, Opus, and PCM codecs
// ABOUTME: Converts compressed audio to PCM for playback, handles 24-bit unpacking

@preconcurrency import AVFoundation
import Foundation
import Opus

/// Audio decoder protocol
public protocol AudioDecoder {
    func decode(_ data: Data) throws -> Data
}

/// PCM decoder supporting 16-bit and 24-bit formats
public class PCMDecoder: AudioDecoder {
    private let bitDepth: Int
    private let channels: Int

    public init(bitDepth: Int, channels: Int) {
        self.bitDepth = bitDepth
        self.channels = channels
    }

    public func decode(_ data: Data) throws -> Data {
        switch bitDepth {
        case 16:
            // 16-bit PCM - pass through (already correct format)
            return data

        case 24:
            // 24-bit PCM - unpack 3-byte samples to 4-byte Int32
            return try decode24Bit(data)

        case 32:
            // 32-bit PCM - pass through
            return data

        default:
            throw AudioDecoderError.unsupportedBitDepth(bitDepth)
        }
    }

    private func decode24Bit(_ data: Data) throws -> Data {
        let bytesPerSample = 3
        guard data.count % bytesPerSample == 0 else {
            throw AudioDecoderError.invalidDataSize(
                expected: "multiple of 3",
                actual: data.count
            )
        }

        let sampleCount = data.count / bytesPerSample
        let bytes = [UInt8](data)

        // Unpack 24-bit samples to Int32 (4 bytes per sample)
        var samples = [Int32]()
        samples.reserveCapacity(sampleCount)

        for i in 0 ..< sampleCount {
            let sample = PCMUtilities.unpack24Bit(bytes, offset: i * bytesPerSample)
            samples.append(sample)
        }

        // Convert Int32 array to Data
        return samples.withUnsafeBytes { Data($0) }
    }
}

/// Opus decoder using libopus via swift-opus package
public class OpusDecoder: AudioDecoder {
    private let decoder: Opus.Decoder
    private let channels: Int

    public init(sampleRate: Int, channels: Int, bitDepth: Int) throws {
        self.channels = channels

        // Create AVAudioFormat for Opus decoder
        // swift-opus accepts standard PCM formats and handles Opus internally
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("Failed to create audio format for Opus")
        }

        // Create opus decoder (validates sample rate internally)
        do {
            self.decoder = try Opus.Decoder(format: format)
        } catch {
            throw AudioDecoderError.formatCreationFailed("Opus decoder: \(error.localizedDescription)")
        }
    }

    public func decode(_ data: Data) throws -> Data {
        // Decode Opus packet to AVAudioPCMBuffer
        let pcmBuffer: AVAudioPCMBuffer
        do {
            pcmBuffer = try decoder.decode(data)
        } catch {
            throw AudioDecoderError.conversionFailed("Opus decode failed: \(error.localizedDescription)")
        }

        // swift-opus outputs float32 in AVAudioPCMBuffer
        // Convert float32 → int32 (24-bit left-justified format)
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw AudioDecoderError.conversionFailed("No float channel data in decoded buffer")
        }

        let frameLength = Int(pcmBuffer.frameLength)
        let totalSamples = frameLength * channels
        var int32Samples = [Int32](repeating: 0, count: totalSamples)

        // Convert interleaved float32 samples to int32
        // float range [-1.0, 1.0] → int32 range [Int32.min, Int32.max]
        if channels == 1 {
            // Mono: direct conversion
            let floatData = floatChannelData[0]
            for i in 0..<frameLength {
                let floatSample = floatData[i]
                int32Samples[i] = Int32(floatSample * Float(Int32.max))
            }
        } else {
            // Stereo or multi-channel: interleave
            for channel in 0..<channels {
                let floatData = floatChannelData[channel]
                for frame in 0..<frameLength {
                    let floatSample = floatData[frame]
                    let sampleIndex = frame * channels + channel
                    int32Samples[sampleIndex] = Int32(floatSample * Float(Int32.max))
                }
            }
        }

        // Convert [Int32] to Data
        return int32Samples.withUnsafeBytes { Data($0) }
    }
}

/// FLAC decoder using AVAudioConverter
public class FLACDecoder: AudioDecoder {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    public init(sampleRate: Int, channels: Int, bitDepth: Int) throws {
        // Input format: FLAC compressed audio
        guard let flacFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,  // FLAC can be 16/24 bit
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("FLAC input format")
        }

        // Output format: PCM int32 (normalized output)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("PCM output format")
        }

        guard let audioConverter = AVAudioConverter(from: flacFormat, to: pcmFormat) else {
            throw AudioDecoderError.converterCreationFailed
        }

        self.inputFormat = flacFormat
        self.outputFormat = pcmFormat
        self.converter = audioConverter
    }

    public func decode(_ data: Data) throws -> Data {
        // Create input buffer from FLAC frame data
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let frameLength = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameLength) else {
            throw AudioDecoderError.bufferCreationFailed
        }
        inputBuffer.frameLength = frameLength

        // Copy FLAC data to buffer
        data.withUnsafeBytes { srcBytes in
            guard let src = srcBytes.baseAddress else { return }
            memcpy(inputBuffer.audioBufferList.pointee.mBuffers.mData, src, data.count)
        }

        // Create output buffer (decoded PCM)
        let outputFrameCapacity = frameLength * 4  // FLAC compression ratio
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw AudioDecoderError.bufferCreationFailed
        }

        // Convert FLAC → PCM
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            throw AudioDecoderError.conversionFailed(error.localizedDescription)
        }

        // Extract PCM data from output buffer
        let outputData = Data(bytes: outputBuffer.audioBufferList.pointee.mBuffers.mData!,
                              count: Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
        return outputData
    }
}

/// Creates decoder for specified codec
public enum AudioDecoderFactory {
    public static func create(
        codec: AudioCodec,
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        header _: Data?
    ) throws -> AudioDecoder {
        switch codec {
        case .pcm:
            return PCMDecoder(bitDepth: bitDepth, channels: channels)
        case .opus:
            return try OpusDecoder(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
        case .flac:
            return try FLACDecoder(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
        }
    }
}

/// Audio decoder errors
public enum AudioDecoderError: Error {
    case unsupportedBitDepth(Int)
    case invalidDataSize(expected: String, actual: Int)
    case formatCreationFailed(String)
    case converterCreationFailed
    case bufferCreationFailed
    case conversionFailed(String)
}
