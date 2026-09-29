import XCTest
import FXMicCore

final class VoiceTurnTests: XCTestCase {
    func testPressRejectsPreviousResponseAndHeldResponse() {
        var gate = VoiceTurnGate()
        let old = gate.turnID
        gate.press(serial: 1)
        XCTAssertFalse(gate.accept(replyID: "old", turnID: old))
        XCTAssertFalse(gate.accept(replyID: "held", turnID: gate.turnID))
        gate.release()
        XCTAssertFalse(gate.accept(replyID: "late", turnID: old))
        XCTAssertTrue(gate.accept(replyID: "new", turnID: gate.turnID))
        XCTAssertFalse(gate.accept(replyID: "new", turnID: gate.turnID))
    }
    func testCancelInvalidatesPendingReply() {
        var gate = VoiceTurnGate()
        gate.press(serial: 2)
        let turn = gate.turnID
        gate.cancel()
        gate.release()
        XCTAssertFalse(gate.accept(replyID: "canceled", turnID: turn))
    }
}
