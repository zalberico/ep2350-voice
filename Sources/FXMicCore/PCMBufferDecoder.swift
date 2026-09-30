import AVFoundation

public enum PCMBufferDecodeError: Error, CustomStringConvertible {
    case invalidFormat
    case missingChannelData
    case invalidBufferLayout
    case unsupportedFormat(AVAudioCommonFormat)

    public var description: String {
        switch self {
        case .invalidFormat: return "input PCM has an invalid sample rate, channel count, or stride"
        case .missingChannelData: return "input PCM channel data is unavailable"
        case .invalidBufferLayout: return "input PCM storage does not match its frame/channel layout"
        case .unsupportedFormat(let format): return "unsupported input PCM format \(format.rawValue)"
        }
    }
}

/// Converts one bounded input buffer to mono floats, without changing the device format.
/// Integer PCM is normalized to [-1, 1]; floating point PCM retains its original scale.
public enum PCMBufferDecoder {
    public static func mono(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        guard channels > 0, stride > 0, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0 else { throw PCMBufferDecodeError.invalidFormat }
        guard buffer.frameLength <= buffer.frameCapacity else { throw PCMBufferDecodeError.invalidBufferLayout }
        guard frames > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { throw PCMBufferDecodeError.missingChannelData }
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += samples[frame * stride] * scale }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { throw PCMBufferDecodeError.missingChannelData }
            let gain = scale / 32768
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += Float(samples[frame * stride]) * gain }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { throw PCMBufferDecodeError.missingChannelData }
            let gain = scale / 2147483648
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += Float(samples[frame * stride]) * gain }
            }
        case .pcmFormatFloat64:
            // AVAudioPCMBuffer has no doubleChannelData convenience property.
            let interleaved = buffer.format.isInterleaved
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard buffers.count >= (interleaved ? 1 : channels) else {
                throw PCMBufferDecodeError.invalidBufferLayout
            }
            for channel in 0..<channels {
                let storage = buffers[interleaved ? 0 : channel]
                let offset = interleaved ? channel : 0
                let requiredSamples = (frames - 1) * stride + offset + 1
                guard let raw = storage.mData,
                      Int(storage.mDataByteSize) / MemoryLayout<Double>.stride >= requiredSamples else {
                    throw PCMBufferDecodeError.invalidBufferLayout
                }
                let samples = raw.assumingMemoryBound(to: Double.self)
                for frame in 0..<frames { mono[frame] += Float(samples[frame * stride + offset]) * scale }
            }
        default:
            throw PCMBufferDecodeError.unsupportedFormat(buffer.format.commonFormat)
        }
        return mono
    }
}
