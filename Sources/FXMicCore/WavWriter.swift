import Foundation

/// Minimal 16-bit PCM mono WAV writer.
public final class WavWriter {
    public let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private var dataBytes: UInt32 = 0

    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.write(WavWriter.header(sampleRate: sampleRate, dataBytes: 0))
    }

    public func append(_ samples: [Float]) {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        dataBytes += UInt32(data.count)
    }

    /// Patches the header and closes the file. Returns the duration in seconds.
    @discardableResult
    public func close() -> Double {
        handle.seek(toFileOffset: 0)
        handle.write(WavWriter.header(sampleRate: sampleRate, dataBytes: dataBytes))
        handle.closeFile()
        return Double(dataBytes) / 2 / Double(sampleRate)
    }

    private static func header(sampleRate: Int, dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
