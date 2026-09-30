# iPhone input-sharing probe

This is the first experiment toward a Listening indicator and input-level bars in Dynamic Island. It is a separate, explicit 90-second microphone test, **not a finished iPhone companion or Live Activity**.

The user has already reported successful EP-2350/Sonos input in Apple Notes dictation, then a Remote voice conversation that continued with the iPhone Air locked. Those are single-app input tests. The remaining question is whether this probe can receive the same external input while Remote continues to hear and speak.

## What the probe measures

- The actual USB input route, sample rate, callback/frame counts, and nonzero sample count.
- Input level in dBFS and bars derived from that measured level. These are audio levels, not speech recognition or proof that Remote hears anything.
- Press, release, and cancel markers from the existing microphone scripts, using the same detector sources as the Mac app.
- Separate user checkboxes for Remote hearing speech, audible replies, and locked-screen operation. Local samples alone never mark the two-app test successful.

No audio is saved or transmitted. There is no transcription, model client, speech synthesis, background playback workaround, or assistant-control action. The share sheet exports only counters, route/status text, and the user's observations, when explicitly requested.

The probe requires an external USB input and verifies that it remains the selected route. It does not fall back to the built-in microphone. Input rates that cannot carry the existing high-frequency markers are rejected. Microphone permission is requested only after pressing Start.

Capture stops after 90 seconds, five seconds without sample updates, an interruption, or an audio route/configuration change. Stop also cancels pending permission/start callbacks. Background audio permits this bounded test while switching to Remote or locking the phone; it does not guarantee that iOS will allow both apps to record. There is no automatic restart after a conflict.

## Build

Use full Xcode with the iOS SDK. The project targets iOS 18 or later and uses the current Swift compiler shipped with Xcode on the test Mac. No external packages are required.

```sh
tools/build-ios-probe.sh all
```

The script creates unsigned device and simulator Debug builds beneath `.build/ios-probe`, with logs alongside them. It does not sign, provision, install, boot a simulator, or change an Apple account. An unsigned device build cannot run on an iPhone.

Open `ios/EP2350Probe.xcodeproj`, choose the `EP2350Probe` scheme and an iPhone simulator, then Run. A simulator can verify the interface and unavailable-input handling. Pure signal tests verify framing and marker detection. Neither proves Sonos routing or simultaneous capture alongside Remote on a physical iPhone.

Run the offline signal checks on the Mac with:

```sh
tools/test-ios-probe.sh
```

This compiles the existing detector and probe accumulator into a standalone host test, using synthetic signals with variable callback sizes at 44.1, 48, and 96 kHz. It checks marker pairing, duplicate presses, fresh-run state, silence, and invalid buffers. Its executable and writable compiler cache go in `.build/ios-probe-tests`; set `EP2350_IOS_TEST_DIR` to choose another writable directory. The checks do not access a microphone, simulator, or phone.

## Install the physical test

**TestFlight alternative:** after a signed build is uploaded, finishes processing, and becomes available to the internal test group, install TestFlight on the iPhone and accept the invitation there. This route needs no Mac cable or Developer Mode; Apple distinguishes TestFlight from [development-signed installation](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). The TestFlight setup is in progress; no uploaded build is available yet.

**Direct Xcode installation:**

In Xcode, sign into the intended Apple account and select its development team for the app. Pair the unlocked iPhone with the Mac, complete the device's Trust/Developer Mode steps, select it as the run destination, then build and run. Account and device prompts require the user's participation. See Apple's [device-run guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) and [Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

After installation, disconnect the phone from the Mac and reconnect the microphone through Sonos. Keep the microphone's own data USB cable disconnected. This app makes no firmware or microphone-script changes.

## Live test order

Start with the handle released. Capture may interrupt the voice call; Stop the probe and resume Remote if it does.

1. **Remote first:** begin a Remote voice call, start the probe, return to Remote, then squeeze, speak, and release several times. Confirm both microphone input and replies still work. Return before the 90-second test ends and inspect the counters.
2. **Probe first:** start a fresh probe run, then begin Remote voice. Check the same markers and conversation behavior.
3. **Phone locked:** repeat a working order with the phone locked for part of the run, then unlock and inspect the result. Also verify that the probe stops at its timeout.

Other checks: disconnect Sonos during a run, stop manually, and leave the app while a permission request is pending. Each should stop or cancel the probe without silently switching inputs or restarting it.

Only a successful real two-app test justifies proceeding to a Live Activity. If that fails, the existing audio-only setup has no verified independent source of handle events for an iPhone display. The mic's local LEDs and Remote voice can still work without this probe.

## Current evidence

- Generic simulator and device builds pass on the Mac mini.
- The offline signal checks pass. The user confirmed Sonos input in Remote voice on the iPhone Air, including a conversation continuing with the phone locked. This confirms the existing audio path, without simultaneous probe capture.
- Physical microphone sharing, phone installation, and Dynamic Island rendering have not been verified.
- The Mac helper and installed microphone scripts are unchanged by this experiment.

The app includes `PrivacyInfo.xcprivacy`, declaring no tracking or developer data collection. Its only required-reason API category is system boot time, with Apple's approved reason `35F9.1` for the bounded test timer and local update intervals. Raw system uptime is not included in the shared report. See Apple's [required-reason API definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

Apple supports custom Live Activities through [ActivityKit](https://developer.apple.com/documentation/ActivityKit). Its [audio mixing option](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) is not a promise of shared input, and [session activation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)) can fail when another app hosts a call. A smooth, continuously updating Dynamic Island meter also remains unverified.
