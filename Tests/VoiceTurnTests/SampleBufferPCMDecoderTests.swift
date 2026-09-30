import AVFoundation
import CoreMedia
import XCTest
import FXMicCore

final class SampleBufferPCMDecoderTests: XCTestCase {
    private func sampleBuffer(from pcm: AVAudioPCMBuffer, ready: Bool = true) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: pcm.format.formatDescription, sampleCount: Int(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertEqual(status, noErr)
        let result = try XCTUnwrap(sample)
        if ready {
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        }
        return result
    }

    func testCopiesNativeInterleavedInt16At48000Hz() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 48000, channels: 2, interleaved: true))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        pcm.frameLength = 3
        let data = try XCTUnwrap(pcm.int16ChannelData)
        let left: [Int16] = [16384, -32768, 0]
        let right: [Int16] = [0, 0, 16384]
        for i in 0..<3 { data[0][i * pcm.stride] = left[i]; data[1][i * pcm.stride] = right[i] }
        let copied = try SampleBufferPCMDecoder.copyPCM(sampleBuffer(from: pcm))
        XCTAssertEqual(copied.format.sampleRate, 48000)
        XCTAssertEqual(copied.frameLength, 3)
        XCTAssertEqual(try PCMBufferDecoder.mono(copied), [0.25, -0.5, 0.25])
    }

    func testCopyOwnsPlanarAudioAfterSampleDataChanges() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 2, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        pcm.frameLength = 2
        let data = try XCTUnwrap(pcm.floatChannelData)
        data[0][0] = 0.5; data[0][1] = -0.5
        data[1][0] = 0; data[1][1] = 0
        let sample = try sampleBuffer(from: pcm)
        let copied = try SampleBufferPCMDecoder.copyPCM(sample)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: CMBlockBufferGetDataLength(block)), noErr)
        XCTAssertEqual(try PCMBufferDecoder.mono(copied), [0.25, -0.25])
        XCTAssertEqual(try PCMBufferDecoder.mono(SampleBufferPCMDecoder.copyPCM(sample)), [0, 0])
    }

    func testUnreadySampleFailsExplicitly() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        pcm.frameLength = 1
        XCTAssertThrowsError(try SampleBufferPCMDecoder.copyPCM(sampleBuffer(from: pcm, ready: false))) {
            XCTAssertEqual(String(describing: $0), "capture sample data is not ready")
        }
    }
}
