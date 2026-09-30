import XCTest
import FXMicCore

final class NativeHandleMonitorTests: XCTestCase {
    private let rate = 48000.0

    private func tone(_ frequencies: [Double], into monitor: NativeHandleMonitor,
                      frames: Int = 10) -> [NativeHandleEvent] {
        (0..<frames).flatMap { hop in
            monitor.process((0..<480).map { i in
                Float(frequencies.reduce(0.0) { sum, f in
                    sum + 0.12 * sin(2 * .pi * f * Double(hop * 480 + i) / rate)
                })
            })
        }
    }

    private func silence(_ monitor: NativeHandleMonitor) -> [NativeHandleEvent] {
        (0..<55).flatMap { _ in monitor.process([Float](repeating: 0, count: 480)) }
    }

    func testFullMarkerSequenceWithDuplicateAndCancelSignals() {
        let monitor = NativeHandleMonitor(sampleRate: rate)
        XCTAssertEqual(tone([14000, 15000], into: monitor), []) // No held turn.
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([17000, 18500], into: monitor), [.pressed])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([17000, 18500], into: monitor), []) // Duplicate burst.
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([12000, 13000], into: monitor), [.cancelSignal])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([12000, 13000], into: monitor), [])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([14000, 15000], into: monitor), [.released])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([17000, 18500], into: monitor), [.pressed])
    }

    func testSpeechBandAndLegacyTapNeverInvokeAssistantActions() {
        let monitor = NativeHandleMonitor(sampleRate: rate)
        XCTAssertEqual(tone([200, 400, 800], into: monitor, frames: 100), [])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([15500, 16500], into: monitor), [])
        XCTAssertEqual(silence(monitor), [])
        XCTAssertEqual(tone([12000, 13000], into: monitor), []) // Cancel outside a squeeze.
    }

    func testRestartDoesNotInheritHeldState() {
        let first = NativeHandleMonitor(sampleRate: rate)
        XCTAssertEqual(tone([17000, 18500], into: first), [.pressed])
        let restarted = NativeHandleMonitor(sampleRate: rate)
        XCTAssertEqual(tone([14000, 15000], into: restarted), [])
    }
}
