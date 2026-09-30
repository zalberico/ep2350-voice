# EP-2350 Voice — developer preview

Use a Teenage Engineering EP-2350 microphone with native voice conversations on macOS, through your existing subscriptions. The Sonos USB-C Line-in Adapter carries the mic's audio; EP2350 Voice adds local handle feedback and a live input meter. Its launcher opens Claude or Grok Bot, while ChatGPT/Codex voice can use the same microphone directly.

The current Mac preview is **0.2.2**. Audio has been user-tested with native ChatGPT/Codex, Claude, and Grok Bot. The yellow **Listening** toast and meter work with Sonos input and Mac mini speakers. An optional on-microphone script adds squeeze/release LEDs; its live behavior is verified and its saved automatic-start hook still needs a normal restart test.

Based on [Miguel de la Garza's fx-mic-claude](https://github.com/migueldelag/fx-mic-claude), used under its MIT license. The upstream license is preserved in `LICENSE`. This is an independent derivative, not an official Teenage Engineering, OpenAI, Anthropic, or xAI product.

**This is a developer preview, not a finished universal voice assistant.** Native apps own their audio, voices, conversations, and account usage. This app asks for no API keys and makes no model or speech API requests. Direct hardware control of native voice playback, a signed installer, and full guided setup remain unfinished.

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
| Native Claude / Grok Bot app selection and opening | Implemented; uses existing app sign-in and subscription |
| Start native voice from this app | Experimental Accessibility action; exact installed button labels inspected, live call not yet tested |
| Local microphone HUD in native mode | User-tested on Sonos with Mac mini speakers, including the restored yellow Listening toast and live meter in 0.2.2 |
| Handle directly controlling ChatGPT native Voice playback | **Not implemented** |
| Persistent connection to this Codex task | **Not implemented**; the demonstration used an active assistant reading local events and writing replies |
| Claude text delivery | Inherited upstream implementation; not verified in this derivative |
| Claude / Grok Bot natural spoken replies | User-tested end to end with Sonos in both native apps |
| Device handle LEDs | User-tested: two lower lights while held, three briefly on release, then stock display. Optional startup hook saved; normal restart validation pending |
| New physical button mappings | Not implemented |

The native voice path and the local speech prototype are separate. Native mode never transcribes, copies or sends speech, reads developer reply files, or uses Apple's system speech voice. It observes handle markers and local audio levels for the Mac HUD. While held, the HUD shows a yellow microphone, “Listening,” and a live meter; releasing fades it out. This is local microphone feedback, not a submission acknowledgment or a report of the assistant's state. Native apps hear the microphone directly, and shaking cannot retract speech they already received. Squeezing alone has not been integrated with native playback control.

## Audio and control connections

- **Audio:** EP-2350 3.5 mm output → Sonos USB-C Line-in Adapter → Mac. Select Sonos as the microphone in the native voice app.
- **Mac feedback:** the helper detects the custom script's audio markers and shows Listening while the handle is held. It does not submit a message or stop native voice playback.
- **Device setup and future status LEDs:** connect the microphone's own USB-C port separately with a data cable. Sonos carries audio; it is not a return channel for the Mac to control the lights.

Start and end native voice calls in their own apps. The helper's provider selector does not transfer conversations or end a call. Native services retain their normal subscription limits.

## Requirements

- macOS 26 or newer, Xcode, and Python 3. The XCTest suite needs the full Xcode developer directory; standalone command-line tools alone may not provide XCTest.
- EP-2350 FX MIC with batteries and a USB-C data cable for setup.
- A compatible line-input adapter and the mic's 3.5 mm audio cable. The Sonos adapter was tested; other combinations require calibration.
- Official compatible firmware, downloaded directly from Teenage Engineering. No vendor firmware or original device files are included here.

## Build the Mac app

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test -c release
python3 -B -m unittest discover -s Tests/Python -v
sh tools/build-app.sh
open 'build/EP2350 Voice.app'
```

Adjust `DEVELOPER_DIR` if Xcode is installed elsewhere. The completed preview has 17 Swift and 41 Python tests. For a per-user installation, quit an older running helper, then copy the built app to `~/Applications` and open that copy.

Allow microphone access for local handle feedback. No Accessibility permission is needed for the HUD or for starting voice yourself in a native app. The optional experimental Start voice action and inherited Claude text delivery use Accessibility.

This preview uses an ad-hoc signature. macOS may request permissions again after a rebuild. It is not notarized or distributed as a trusted one-click application yet.

## Use existing subscriptions

Right-click the menu bar handset. In **Native voice (subscriptions)** mode:

1. Choose **Voice assistant → Claude / Grok Bot** and **Open** that app.
2. In the native app, open the desired conversation, select the Sonos input, and start its voice mode. **Start voice (experimental)** can press its voice button when EP2350 Voice already has Accessibility access.
3. Optionally choose **Start handle feedback** to see the Listening toast and live input meter while holding the handle. This does not start or stop a native call.
4. End a call in its own app before switching assistants. Selection here does not transfer history, change the native app's microphone, or end its call.

Native ChatGPT Voice remains usable directly with Sonos, as tested. The launcher currently targets Claude and Grok Bot. Provider subscription limits and any extra-usage settings still apply; this app does not change billing settings. See [native voice setup and limits](docs/native-voice.md).

The older clipboard/local synthesis experiment is available explicitly under **Mode → Local transcription / bridge**. In that mode, `autoArm` and existing developer settings still apply.

## Set up the mic

**Skip device setup entirely if compatible firmware and these scripts are already installed.** Mac app updates do not require reinstalling them. The Mac app build and installer do not change installed microphone firmware or scripts. The optional LED add-on described below is a separate, explicit script update.

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
6. Connect the mic's 3.5 mm line output through the Sonos adapter to the Mac. Use native voice as described above, or select Local transcription / bridge to test clipboard delivery.

Never use a serial tool that toggles modem control lines on this mic; it can reset it. The included reader avoids that behavior.

## Calibration

This preview defaults to the tested Sonos input and a speech cutoff calibrated for one quiet setup. Hardware volume, speaking distance, and other adapters will differ. Use the diagnostic meter and adjust the mic's volume before relying on recognition. Do not connect the mic output directly to headphones.

```sh
swift run -c release fxmic-cal --list
swift run -c release fxmic-cal --device Sonos --meter --no-record --duration 20
```

## Local voice bridge

See [the bridge protocol](docs/bridge.md). This separate developer mode needs an external connector to read utterance events and supply replies. The bridge itself does **not** automatically call a model or obtain API credentials. Native subscription voice does not use this bridge.

## LED development

The [optional device LED adapter](docs/led-overlay.md) adds user-tested local handle feedback to the verified 1.1.2 custom script. The general microphone installer does not enable it. The earlier [offline feedback module](docs/device-feedback.md) remains a separate simulation foundation. Assistant thinking/speaking indicators still need a reliable return channel from the Mac.

## Restore stock operation

Eject safely before restarting. With the mic mounted normally, remove only the added `main.py` and `fxmic.py` startup files to stop executing the custom code, and restore the original drive files from your backup to recover your sample/configuration setup. Firmware updates are separate; a drive backup is not a full firmware image.

## Next work

1. **Upper-bank working LEDs:** connect actual assistant status to the mic over its direct USB connection. The current release only has physical squeeze/release feedback; it does not infer thinking or speaking from audio.
2. **Orange approval button:** use a deliberate physical press and release for the current Codex permission prompt, choosing the broadest option actually offered. This is planned, not enabled; a reliable prompt connection and stale-click protection are required.
3. **iPhone hub experiment:** test Sonos audio on a USB-C iPhone Air, then voice through the Remote app while the Mac stays awake. Compatibility is unverified. Mac helper controls would not automatically run on the phone.
4. **Direct native voice controls:** verify squeeze-to-interrupt, release-to-submit, cancel/repeat, and provider switching separately for each service. Hearing microphone audio is not proof of hardware control.
5. **Distribution:** validate microphone restart persistence, AirPlay output, clean installation and rollback on a second Mac, then add guided setup and signed/notarized releases.

Thinking LEDs and approval-button integration are being developed separately from this tested checkpoint. No microphone firmware update is required for the Mac app or optional LED script work.

See [release readiness](docs/release-readiness.md) before calling this a consumer-ready release.
