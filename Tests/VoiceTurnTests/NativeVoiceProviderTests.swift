import XCTest
import FXMicCore

final class NativeVoiceProviderTests: XCTestCase {
    func testCanceledQueuedRequestCannotPressAnOldProvidersButton() {
        let pendingStart = NativeActionToken()
        var pressed = false
        let delayedAction = { pendingStart.performIfActive { pressed = true } }
        pendingStart.cancel() // Provider switched before the background lookup finished.
        XCTAssertNil(delayedAction())
        XCTAssertFalse(pressed)
        let nextProvider = NativeActionToken()
        XCTAssertNotNil(nextProvider.performIfActive { pressed = true })
        XCTAssertTrue(pressed)
    }

    func testVoiceMatcherNeverAcceptsDictationOrStopControls() {
        for provider in NativeVoiceProvider.allCases {
            for label in ["Start voice input", "Start dictation", "Stop", "Stop voice chat", "Use voice mode later"] {
                XCTAssertFalse(provider.matchesStartVoiceButton(title: label, description: nil))
                XCTAssertFalse(provider.matchesStartVoiceButton(title: nil, description: label))
            }
            XCTAssertFalse(provider.matchesStartVoiceButton(title: nil, description: nil))
        }
    }

    func testVoiceMatcherUsesExactProviderSpecificTitleOrDescription() {
        XCTAssertTrue(NativeVoiceProvider.claude.matchesStartVoiceButton(title: "Use voice mode", description: nil))
        XCTAssertTrue(NativeVoiceProvider.grok.matchesStartVoiceButton(title: nil, description: "Start voice chat"))
        XCTAssertFalse(NativeVoiceProvider.claude.matchesStartVoiceButton(title: "Start voice chat", description: nil))
        XCTAssertFalse(NativeVoiceProvider.grok.matchesStartVoiceButton(title: nil, description: "Use voice mode"))
        XCTAssertFalse(NativeVoiceProvider.grok.matchesStartVoiceButton(title: "start voice chat", description: nil))
    }
}
