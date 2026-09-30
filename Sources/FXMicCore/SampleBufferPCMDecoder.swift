import AVFoundation
import CoreMedia

public enum SampleBufferPCMError: Error, CustomStringConvertible {
    case notReady, invalidAudioFormat, invalidFrameCount, allocationFailed
    case copyFailed(OSStatus)

    public var description: String {
        switch self {
        case .notReady: return "capture sample data is not ready"
        case .invalidAudioFormat: return "capture sample is not supported linear PCM audio"
        case .invalidFrameCount: return "capture sample has an invalid or excessive frame count"
        case .allocationFailed: return "could not allocate owned PCM capture buffer"
        case .copyFailed(let status): return "could not copy capture PCM (OSStatus \(status))"
        }
    }
}

/// Makes an owned PCM copy before a capture delegate's borrowed sample can expire.
public enum SampleBufferPCMDecoder {
    public static func copyPCM(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample) else { throw SampleBufferPCMError.notReady }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: stream),
              format.commonFormat != .otherFormat else { throw SampleBufferPCMError.invalidAudioFormat }
        let frames = CMSampleBufferGetNumSamples(sample)
        // Device callbacks are short; cap a corrupt/pathological buffer before allocating.
        guard frames >= 0, frames <= 262_144 else { throw SampleBufferPCMError.invalidFrameCount }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))) else {
            throw SampleBufferPCMError.allocationFailed
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        if frames > 0 {
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw SampleBufferPCMError.copyFailed(status) }
        }
        return pcm
    }
}
