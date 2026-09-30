# Native Claude and Grok Bot voice

EP2350 Voice opens the installed Claude or Grok Bot app so you can use its native voice conversation with your existing account. This path makes no model or speech API requests, asks for no API keys, and adds no API fees through this app. The provider's plan limits and any existing extra-usage settings still apply; EP2350 Voice does not change billing settings.

Select Sonos in the native app's microphone menu (or as the system input if that app follows it), open the desired conversation, and start native voice. The helper's own input menu selects only its handle-monitoring input. Microphone permission and sign-in belong to the selected app. The EP-2350 remains an audio input: squeeze to speak. Direct squeeze-to-interrupt playback, native voice state reporting, and device status LEDs are not implemented by this launcher. Speech-triggered interruption is handled by the native provider. Each app's Sonos input and live behavior require a separate hardware test.

Native voice is the default mode. While the handle is held, the optional local monitor shows a yellow microphone, **Listening**, and a live local input meter. The toast fades on release; a shake shows **Shake detected**. These are local microphone observations, not confirmation that a provider listened, submitted, canceled or stopped. Native mode does not show **Sending** or **Sent** because the app cannot verify those states. It does not transcribe speech, copy text, deliver messages, use the developer reply mailbox, or play Apple speech. It leaves the shared input device's buffer size unchanged. The older workflow remains available under **Mode → Local transcription / bridge**. End a native call in its own app before changing assistants; this selector neither ends calls nor moves history.

## Start voice (experimental)

The optional **Start voice (experimental)** action opens the selected app and presses one verified native start button through macOS Accessibility:

| App | Exact native button | Requirement |
| --- | --- | --- |
| Claude | Use voice mode | Open a Claude conversation with voice available |
| Grok Bot | Start voice chat | Open a Bot conversation with an empty composer |

It requires Accessibility access already granted to EP2350 Voice. It does not display a permission request automatically. You can start voice directly in the provider app without granting EP2350 Voice this access.

The helper reads only the selected app's focused/main window accessibility hierarchy, button roles, enabled state, titles, and descriptions. It does not read composer values or transcript text elements, retain or log button labels, send messages, simulate keyboard/mouse input, or use private provider endpoints. Traversal is limited to 600 elements, depth 24, and approximately two seconds, with short per-call timeouts. It presses only a unique, enabled button whose title or description exactly matches the inspected English label. Changes in app UI or language can make the action unavailable; use the native control instead.

Successful completion means the app accepted an accessibility button press. It does not verify that a call connected or that audio was heard. End, mute, and direct playback interruption are left to the provider's native controls.

Changing the selected assistant or mode cancels pending start requests before their final button press. A call that already started remains under the native app's control.

## Native product behavior

- **Claude:** Native voice is available on desktop and web. Voice conversations use normal plan allowances, and speaking can interrupt a response. The documented desktop links open a new/existing chat or project; no voice-control link is documented. Caps Lock quick entry is dictation, which is different from two-way voice. [Voice mode](https://support.claude.com/en/articles/11101966-use-voice-mode), [desktop links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link), [quick entry](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac).
- **Grok Bot:** Native live voice starts from the empty composer. The documented shortcut list says it has no live-voice keybinding. Command-D is dictation and is never used by this helper. Eligible Cursor plans and linked individual SuperGrok plans include Bot access, subject to plan usage and optional on-demand settings. [Voice and shortcuts](https://docs.x.ai/grok-bot/chat-and-collaboration), [plans and FAQ](https://docs.x.ai/grok-bot/faq).

Documentation and English button labels were checked on September 29, 2026. Unit tests cover exact label matching and rejection of dictation, stop, partial-match, and other-provider controls. They do not establish end-to-end native voice or Sonos compatibility.
