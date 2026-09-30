# Release readiness

## Earlier local transcription prototype

- Firmware 1.1.2 and the custom scripts were already installed when Mac mini setup began. The earlier prototype had verified that firmware over USB; the Mac mini work did not flash it.
- Generated mic script and control sounds installed with byte-for-byte verification.
- Sonos input recognized; local English transcription accepted after level calibration.
- Squeeze interrupted local synthesized speech; user confirmed it felt responsive.
- Follow-up speech reached the active assistant, which wrote a spoken reply.
- Tests cover stale replies after a press, replies while held, duplicates, and cancellation.

## Required before an easy public release

- For the older local synthesis bridge, implement and test a persistent assistant connector. That demonstration relies on an active task and local files; native subscription voice does not need this connector.
- Test on a clean second Mac and all claimed hardware/firmware variants.
- Provide a signed/notarized application and stable permissions across upgrades.
- Add guided setup, input calibration, explicit output selection, diagnostics, and recovery.
- Harden audio-device loss, concurrent transcription, stale callbacks, session cancellation, and event log retention.
- Test installation failures and restoration from backup. Drive backups do not restore firmware.
- For the older local synthesis bridge, measure physical squeeze-to-acoustic-silence latency; software event timestamps alone are insufficient. Native playback interruption is a separate unimplemented integration.
- Verify native Voice integration separately from the local synthesis bridge.
- Add provider adapters only alongside end-to-end tests; do not claim universal compatibility.

## Subscription-native preview on the Mac mini

- Claude and Grok Bot installed English voice-start controls were inspected. The app now opens either native provider and has an optional bounded Accessibility start action.
- Native mode is the default and uses a separate marker-only capture path. It does not transcribe/deliver text, play local speech, or change the device buffer size.
- Seventeen Swift tests pass, including synthetic marker sequences, exact native voice-label matching, cancellation of queued native actions, PCM sample formats/channel layouts, and owned CoreMedia sample-buffer copies. Forty-one Python tests pass across the offline LED foundation and optional device adapter.
- No model or speech API client, API credentials, extra billing settings, or microphone firmware changes were added. The optional LED script was separately installed and tested on the connected device.
- The user confirmed Sonos voice audio in both Claude and Grok Bot, restored Listening/meter feedback with Mac mini speakers on 0.2.2, and the optional device adapter's physical hold/release LED pattern. The adapter's startup hook is saved and read back; the user reported lights still working after a restart, while repeatable battery-only cold-start validation remains pending. The helper's experimental voice-start invocation remains unverified. Squeeze-to-interrupt native playback is not implemented.
- Existing Swift concurrency warnings in the legacy transcription/synthesis path remain; passing release tests do not establish race-free legacy behavior.

### Sonos with AirPlay output: live capture failure

After the native preview restart, microphone permission was granted and Sonos was selected, but the helper received zero raw audio callbacks. Sonos's nominal and hardware input rates were 48 kHz; AVAudioEngine exposed its input output format at 44.1 kHz, matching the selected AirPlay output. The earlier working session logged 48 kHz. The display could show the permission toast, but without samples it could not detect physical markers. Automated marker/PCM tests did not cover this hardware configuration.

The diagnostic preview now distinguishes an opened device from received audio, records callback/frame/format diagnostics without recording speech, and stops recovery after three failed retries.

With Mac mini speakers selected, restarting the unchanged installed 0.2.1 diagnostic preview restored matching 48 kHz formats and continuous usable samples. The user then confirmed both **Handle held** and **Handle released** toasts. This verifies local marker feedback in that configuration. The user also recalls failure before selecting AirPlay, so the original regression's full cause is not established by this comparison.

Source for 0.2.2 replaces the AVAudioEngine input graph with exact-UID, input-only AVCapture, checks delivered sample rates, preserves stopped-stream diagnostics, clears stale recovery status, and guards HUD hide completions against a newer toast. Its seventeen Swift tests pass. The 0.2.2 app was subsequently installed, real Sonos audio was confirmed at 48 kHz, and the user verified the restored yellow Listening toast and live meter with Mac mini speakers. The earlier successful Claude and Grok Bot voice tests used the working 0.2.1 installation. AirPlay support remains unverified.

## Distribution boundaries

Preserve the MIT license and upstream attribution. Exclude generated device scripts, vendor firmware, factory samples, PDFs, personal backups, transcripts, credentials, build caches, and local signing material. This source package intentionally contains no compiled binary or captured user speech.

## Current usage scope

Everyday use is battery-powered with only the microphone's bottom audio cable, through Sonos. Persistent-USB assistant-state LEDs are deferred because they do not fit this setup. Orange-button approval remains blocked on a verified integration with the existing Codex desktop approval prompt; the detector-only prototype was stopped without device or app installation. The user subsequently tested Sonos input on the iPhone Air in Apple Notes dictation: whispered speech was transcribed with the phone far away while the handle was held, and was not transcribed when released. Remote voice remains a separate pending test. No iOS companion is implemented; Mac feedback and controls do not automatically follow the microphone onto the phone.

## Native input reconnection preview (0.2.3)

The 0.2.2 helper stopped after Sonos was unplugged and stayed idle when it returned. Restarting that installation restored real 48 kHz audio and handle events, confirming the immediate failure was stopped monitoring.

Version 0.2.3 retains the exact device UID only when an active native input disappears, and resumes that input if it returns within the original idle window. Explicit Stop, input/mode changes, microphone permission loss, and idle expiry cancel the pending resume. Device notifications coalesce into one attempt, stale callbacks cannot reopen an obsolete session, and failed starts are limited to three. A pending microphone-permission response is also invalidated by Stop or an input/mode change.

The release build and all 23 Swift tests pass, including six new reconnect-policy tests. Independent source review found no remaining blocker. The app was installed for the current user, its signature and installed bytes were verified, and startup delivered usable Sonos audio at 48 kHz. Live unplug/replug then passed: logs show device removal, automatic reopening of Sonos, usable 48 kHz audio, and new press/release events; the user confirmed the Listening toast returned without a helper restart. Stop-while-absent and timeout behavior still need hardware tests; their policy checks pass in the automated suite. No microphone scripts or firmware changed for this fix.
