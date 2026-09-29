# Release readiness

## Confirmed in the local prototype

- Official FX MIC 1.1.2 update completed and verified over USB.
- Generated mic script and control sounds installed with byte-for-byte verification.
- Sonos input recognized; local English transcription accepted after level calibration.
- Squeeze interrupted local synthesized speech; user confirmed it felt responsive.
- Follow-up speech reached the active assistant, which wrote a spoken reply.
- Tests cover stale replies after a press, replies while held, duplicates, and cancellation.

## Required before an easy public release

- Implement and test a persistent assistant connector. The current demonstration relies on an active task and local files.
- Test on a clean second Mac and all claimed hardware/firmware variants.
- Provide a signed/notarized application and stable permissions across upgrades.
- Add guided setup, input calibration, explicit output selection, diagnostics, and recovery.
- Harden audio-device loss, concurrent transcription, stale callbacks, session cancellation, and event log retention.
- Test installation failures and restoration from backup. Drive backups do not restore firmware.
- Measure physical squeeze-to-acoustic-silence latency; software event timestamps alone are insufficient.
- Verify native Voice integration separately from the local synthesis bridge.
- Add provider adapters only alongside end-to-end tests; do not claim universal compatibility.

## Distribution boundaries

Preserve the MIT license and upstream attribution. Exclude generated device scripts, vendor firmware, factory samples, PDFs, personal backups, transcripts, credentials, build caches, and local signing material. This source package intentionally contains no compiled binary or captured user speech.
