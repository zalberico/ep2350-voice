# EP-2350 Voice — developer preview

A physical push-to-talk experiment for the Teenage Engineering EP-2350 and macOS. Squeeze to capture speech, release to submit it, and interrupt the prototype's spoken reply with another squeeze.

Based on [Miguel de la Garza's fx-mic-claude](https://github.com/migueldelag/fx-mic-claude), used under its MIT license. The upstream license is preserved in `LICENSE`. This is an independent derivative, not an official Teenage Engineering, OpenAI, Anthropic, or xAI product.

**This is a source release for developers, not a finished universal voice assistant.** The hardware and local interruption loop were tested on one Mac. A standalone assistant connection, signed installer, and guided setup are not implemented yet.

## What works

| Capability | Status |
| --- | --- |
| EP-2350 FX MIC with official firmware 1.1.2 | Tested |
| Sonos USB-C Line-in Adapter on Mac | Tested |
| Handle press/release detection over audio marker tones | Tested |
| Local English transcription using Apple's speech recognition | Tested |
| Clipboard transcription | Tested |
| Local synthesized speech stopped by a squeeze | Tested end to end |
| Reject stale, duplicate, or held-turn replies | Automated tests pass |
| ChatGPT native Voice using Sonos as microphone input | User-tested audio input and speech-triggered interruption |
| Handle directly controlling ChatGPT native Voice playback | **Not implemented** |
| Persistent connection to this Codex task | **Not implemented**; the demonstration used an active assistant reading local events and writing replies |
| Claude text delivery | Inherited upstream implementation; not verified in this derivative |
| Claude spoken replies, Grok, other providers | Not implemented |
| Status LEDs and new button mappings | Design proposals only |

The native ChatGPT Voice test and the local speech prototype are separate paths. The local prototype uses Apple's system speech voice, not ChatGPT's voice. Native Voice currently detects speech to interrupt; squeezing alone has not been integrated with it.

## Requirements

- macOS 26 or newer, Xcode command-line tools, and Python 3.
- EP-2350 FX MIC with batteries and a USB-C data cable for setup.
- A compatible line-input adapter and the mic's 3.5 mm audio cable. The Sonos adapter was tested; other combinations require calibration.
- Official compatible firmware, downloaded directly from Teenage Engineering. No vendor firmware or original device files are included here.

## Build the Mac app

```sh
swift test -c release
sh tools/build-app.sh
open 'build/EP2350 Voice.app'
```

Allow microphone access. No Accessibility permission is needed for clipboard or the local voice bridge. The optional inherited Claude delivery uses Accessibility and should be enabled only when you intend to send messages to Claude.

This preview uses an ad-hoc signature. macOS may request permissions again after a rebuild. It is not notarized or distributed as a trusted one-click application yet.

## Set up the mic

1. Copy the entire mic drive to a backup first. Keep that backup private.
2. Follow [Teenage Engineering's official update instructions](https://teenage.engineering/downloads/ep-2350) if an update is needed. Use the firmware matching the bootloader's FX MIC or Ting identity. This derivative was tested with FX MIC 1.1.2; do not assume other variants are equivalent.
3. Connect the mic's USB-C port and power it on. Confirm the normal `FX MIC DISK` drive is mounted, not its bootloader drive.
4. Generate a patched startup script from your own device:

```sh
python3 tools/build_fxmic_script.py --from-device
python3 tools/install_mic.py
```

The installer backs up all existing files to a private local folder, checks the exact target volume, copies the marker files, verifies their bytes, and installs the startup file last. Do not commit the generated startup script or backups: they contain vendor-owned material.

5. Eject the drive in Finder. Unplug USB-C, press the small button above the port once to power off, then squeeze to restart on batteries.
6. Connect the mic's 3.5 mm line output through the Sonos adapter to the Mac. Start the app and test a spoken sentence. The default result is copied to the clipboard.

Never use a serial tool that toggles modem control lines on this mic; it can reset it. The included reader avoids that behavior.

## Calibration

This preview defaults to the tested Sonos input and a speech cutoff calibrated for one quiet setup. Hardware volume, speaking distance, and other adapters will differ. Use the diagnostic meter and adjust the mic's volume before relying on recognition. Do not connect the mic output directly to headphones.

```sh
swift run -c release fxmic-cal --list
swift run -c release fxmic-cal --device Sonos --meter --no-record --duration 20
```

## Local voice bridge

See [the bridge protocol](docs/bridge.md). An external assistant connector must read utterance events and supply replies. This package does **not** automatically call a model, use a subscription, or obtain API credentials.

## Restore stock operation

Eject safely before restarting. With the mic mounted normally, remove only the added `main.py` and `fxmic.py` startup files to stop executing the custom code, and restore the original drive files from your backup to recover your sample/configuration setup. Firmware updates are separate; a drive backup is not a full firmware image.

## Release roadmap

1. Reliable standalone assistant connector with cancellation and clear connection status.
2. Guided microphone selection, level calibration, device backup, installation, and rollback.
3. Natural streaming voice with explicit push-to-talk interruption and conversation history that reflects what was actually heard.
4. Provider adapters and provider-specific compatibility tests.
5. Signed/notarized Mac app and a public binary release after installation and recovery are tested on a second Mac.
6. Device LEDs and deliberate cancel/repeat/provider buttons, after reliable host-to-device status is available.

See [release readiness](docs/release-readiness.md) before calling this a consumer-ready release.
