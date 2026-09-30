import AVFoundation
import XCTest
import FXMicCore

final class PCMBufferDecoderTests: XCTestCase {
    private func makeBuffer(_ common: AVAudioCommonFormat, interleaved: Bool,
                            values: [[Double]]) throws -> AVAudioPCMBuffer {
        let frames = values[0].count
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 44100,
            channels: AVAudioChannelCount(values.count), interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        // Fill raw storage in its physical layout, independently of decoder channel pointers.
        let storage = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in values.indices {
            let raw = try XCTUnwrap(storage[interleaved ? 0 : channel].mData)
            for frame in values[channel].indices {
                let index = interleaved ? frame * values.count + channel : frame
                let value = values[channel][frame]
                switch common {
                case .pcmFormatFloat32: raw.assumingMemoryBound(to: Float.self)[index] = Float(value)
                case .pcmFormatFloat64: raw.assumingMemoryBound(to: Double.self)[index] = value
                case .pcmFormatInt16: raw.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32768)
                case .pcmFormatInt32: raw.assumingMemoryBound(to: Int32.self)[index] = Int32(value * 2147483648)
                default: XCTFail("unexpected fixture format")
                }
            }
        }
        return buffer
    }

    private func assertSamples(_ actual: [Float], _ expected: [Float],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (sample, wanted) in zip(actual, expected) {
            XCTAssertEqual(sample, wanted, accuracy: 0.000001, file: file, line: line)
        }
    }

    func testPlanarFloat32AveragesChannelsWithoutChangingRate() throws {
        let buffer = try makeBuffer(.pcmFormatFloat32, interleaved: false,
            values: [[0.5, -0.25, 0, 0.75], [-0.25, -0.75, 0.5, 0.25]])
        assertSamples(try PCMBufferDecoder.mono(buffer), [0.125, -0.5, 0.25, 0.5])
        XCTAssertEqual(buffer.format.sampleRate, 44100)
    }

    func testInterleavedFloat32HonorsChannelStride() throws {
        let buffer = try makeBuffer(.pcmFormatFloat32, interleaved: true,
            values: [[0.5, -0.25, 0, 0.75], [-0.25, -0.75, 0.5, 0.25]])
        XCTAssertEqual(buffer.stride, 2)
        assertSamples(try PCMBufferDecoder.mono(buffer), [0.125, -0.5, 0.25, 0.5])
    }

    func testIntegerFormatsNormalizePlanarAndInterleavedSamples() throws {
        let formats: [AVAudioCommonFormat] = [.pcmFormatInt16, .pcmFormatInt32]
        for common in formats {
            for interleaved in [false, true] {
                let buffer = try makeBuffer(common, interleaved: interleaved,
                    values: [[-1, 0.5, 0, -0.5], [0, -0.25, 0.75, -0.5]])
                assertSamples(try PCMBufferDecoder.mono(buffer), [-0.5, 0.125, 0.375, -0.5])
            }
        }
    }

    func testMonoFormatsKeepSampleOrderAndAmplitude() throws {
        let formats: [AVAudioCommonFormat] = [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32]
        for common in formats {
            for interleaved in [false, true] {
                let buffer = try makeBuffer(common, interleaved: interleaved,
                    values: [[-1, -0.5, 0, 0.25, 0.75]])
                assertSamples(try PCMBufferDecoder.mono(buffer), [-1, -0.5, 0, 0.25, 0.75])
            }
        }
    }

    func testFloat64AveragesPlanarAndInterleavedChannels() throws {
        for interleaved in [false, true] {
            let buffer = try makeBuffer(.pcmFormatFloat64, interleaved: interleaved,
                values: [[0.5, -0.25, 0, 0.75], [-0.25, -0.75, 0.5, 0.25]])
            assertSamples(try PCMBufferDecoder.mono(buffer), [0.125, -0.5, 0.25, 0.5])
        }
    }

    func testEmptyBufferYieldsNoAudio() throws {
        let buffer = try makeBuffer(.pcmFormatFloat32, interleaved: false, values: [[0, 0]])
        buffer.frameLength = 0
        XCTAssertEqual(try PCMBufferDecoder.mono(buffer), [])
    }
}
