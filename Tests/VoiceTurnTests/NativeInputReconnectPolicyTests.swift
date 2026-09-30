import XCTest
import FXMicCore

final class NativeInputReconnectPolicyTests: XCTestCase {
    private let sonos = "verified-sonos-uid"

    private func waiting(deadline: TimeInterval? = 100) -> NativeInputReconnectPolicy {
        var policy = NativeInputReconnectPolicy()
        policy.waitForReturn(uid: sonos, now: 1, deadline: deadline)
        return policy
    }

    func testOnlyPreviouslyActiveExactInputCanResumeAndNotificationsCoalesce() throws {
        var policy = NativeInputReconnectPolicy()
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 2))
        policy.waitForReturn(uid: sonos, now: 2, deadline: 100)
        XCTAssertNil(policy.schedule(availableUIDs: ["another Sonos", "built-in"], authorized: true, now: 3))
        XCTAssertNil(policy.schedule(availableUIDs: [], authorized: true, now: 4))
        let request = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 5))
        XCTAssertEqual(request.uid, sonos)
        for _ in 0..<20 {
            XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 5))
        }
        XCTAssertTrue(policy.begin(request, availableUIDs: [sonos], authorized: true, now: 6))
        XCTAssertFalse(policy.begin(request, availableUIDs: [sonos], authorized: true, now: 6))
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 6))
        policy.finish(request, succeeded: true)
        XCTAssertFalse(policy.isWaiting)
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 7))
    }

    func testExplicitStopRevokesQueuedReconnectAndDoesNotArmOnLaterPlug() throws {
        var policy = waiting()
        let old = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 2))
        policy.cancel()
        XCTAssertFalse(policy.begin(old, availableUIDs: [sonos], authorized: true, now: 3))
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 4))
        policy.waitForReturn(uid: "new-input", now: 5, deadline: 100)
        let current = try XCTUnwrap(policy.schedule(availableUIDs: ["new-input"], authorized: true, now: 6))
        XCTAssertFalse(policy.begin(old, availableUIDs: [sonos], authorized: true, now: 7))
        XCTAssertTrue(policy.begin(current, availableUIDs: ["new-input"], authorized: true, now: 7))
        policy.finish(old, succeeded: true)
        XCTAssertEqual(policy.targetUID, "new-input")
    }

    func testUnplugBeforeDelayedAttemptDoesNotConsumeRetryAndOldTicketCannotWin() throws {
        var policy = waiting()
        let old = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 2))
        XCTAssertFalse(policy.begin(old, availableUIDs: [], authorized: true, now: 3))
        let current = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 4))
        XCTAssertEqual(current.attempt, 1)
        XCTAssertNotEqual(current, old)
        XCTAssertFalse(policy.begin(old, availableUIDs: [sonos], authorized: true, now: 5))
        XCTAssertTrue(policy.begin(current, availableUIDs: [sonos], authorized: true, now: 5))
    }

    func testUnavailablePermissionCancelsWithoutAnyAttempt() throws {
        var policy = waiting()
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: false, now: 2))
        XCTAssertFalse(policy.isWaiting)
        policy = waiting()
        let request = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 2))
        XCTAssertFalse(policy.begin(request, availableUIDs: [sonos], authorized: false, now: 3))
        XCTAssertFalse(policy.isWaiting)
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 4))
    }

    func testOriginalIdleDeadlineExpiresWhileDeviceIsAwayOrAttemptIsQueued() throws {
        var policy = waiting(deadline: 10)
        let request = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 9))
        XCTAssertFalse(policy.begin(request, availableUIDs: [sonos], authorized: true, now: 10))
        XCTAssertFalse(policy.isWaiting)
        policy = waiting(deadline: 10)
        XCTAssertTrue(policy.expire(now: 11))
        XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 12))
        policy = waiting(deadline: nil)
        XCTAssertFalse(policy.expire(now: 1_000_000))
        XCTAssertTrue(policy.isWaiting)
    }

    func testThreeFailuresExhaustIntentDespiteMoreDeviceNotifications() throws {
        var policy = waiting()
        for attempt in 1...3 {
            let request = try XCTUnwrap(policy.schedule(availableUIDs: [sonos], authorized: true, now: 2))
            XCTAssertEqual(request.attempt, attempt)
            XCTAssertTrue(policy.begin(request, availableUIDs: [sonos], authorized: true, now: 2))
            policy.finish(request, succeeded: false)
        }
        XCTAssertFalse(policy.isWaiting)
        for _ in 0..<20 {
            XCTAssertNil(policy.schedule(availableUIDs: [sonos], authorized: true, now: 3))
        }
    }
}
