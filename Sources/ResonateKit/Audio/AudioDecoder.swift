// ABOUTME: Audio decoder for FLAC, Opus, and PCM codecs
// ABOUTME: Converts compressed audio to PCM for playback, handles 24-bit unpacking

@preconcurrency import AVFoundation
import Foundation

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

/// Opus decoder using AVAudioConverter
public class OpusDecoder: AudioDecoder {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    public init(sampleRate: Int, channels: Int, bitDepth: Int) throws {
        // Input format: Opus compressed audio
        guard let opusFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,  // Opus decodes to int16 internally
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("Opus input format")
        }

        // Output format: PCM int32 (normalized output)
        // For 16-bit and 24-bit, we normalize to int32 for consistency
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw AudioDecoderError.formatCreationFailed("PCM output format")
        }

        guard let audioConverter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw AudioDecoderError.converterCreationFailed
        }

        self.inputFormat = opusFormat
        self.outputFormat = pcmFormat
        self.converter = audioConverter
    }

    public func decode(_ data: Data) throws -> Data {
        // Create input buffer from Opus frame data
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let frameLength = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameLength) else {
            throw AudioDecoderError.bufferCreationFailed
        }
        inputBuffer.frameLength = frameLength

        // Copy Opus data to buffer
        data.withUnsafeBytes { srcBytes in
            guard let src = srcBytes.baseAddress else { return }
            memcpy(inputBuffer.audioBufferList.pointee.mBuffers.mData, src, data.count)
        }

        // Create output buffer (decoded PCM)
        // Opus typically expands ~10x, so allocate conservatively
        let outputFrameCapacity = frameLength * 10
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw AudioDecoderError.bufferCreationFailed
        }

        // Convert Opus → PCM
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
