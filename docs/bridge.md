# Local voice bridge

This transport decouples microphone controls from assistant providers. The prototype's playback is local Apple speech synthesis. A natural voice transport remains future work.

This is the separate developer path. Select **Mode → Local transcription / bridge** before using it. The default Native voice mode suspends the bridge: no reply polling, synthesis or transcript delivery occurs there. Native Claude/Grok Bot use their own subscription voice instead; see [native voice](native-voice.md).

Enable before starting the app:

```sh
defaults write local.ep2350.voice voiceBridgeDirectory -string "$HOME/Library/Application Support/EP2350Voice/bridge"
```

Disable before restarting the app to return to clipboard mode:

```sh
defaults delete local.ep2350.voice voiceBridgeDirectory
```

The app writes `state.json` and append-only `events.jsonl` in that directory. These files contain spoken text; they are local private runtime data and must not be published. No raw audio is recorded by this bridge. The inherited diagnostic utility can record audio unless `--no-record` is specified.

## Events

`ready`, `press`, `release`, `utterance`, `reply_accepted`, `speaking`, `interrupted`, `finished`, `reply_rejected`, `cancel`, and `stopped` carry `turnID` and timestamps. `utterance` carries `text`.

Every press creates a fresh turn ID and immediately requests local playback stop. Providers should cancel their previous generation on a press. After release, the accepted transcript becomes an utterance event. Replies must carry that event's turn ID.

Write a JSON object atomically to `reply.json`:

```json
{"id":"unique-reply-id","turnID":"the-current-utterance-turn-id","text":"Your spoken answer."}
```

Replies for older turns, duplicate IDs, and replies arriving while the handle is held are rejected. This preview uses a single reply mailbox; a producer should wait for acceptance before writing another response. There is no chunked audio or text streaming yet.

`interrupted` includes an approximate spoken prefix based on synthesis word callbacks. It is not sample-accurate proof of what the listener heard. A future provider adapter must manage cancellation and context truncation explicitly.

The included `tools/voice_session.py` can read events using a returned cursor and write a reply for a specified turn. This is a development tool, not a background assistant service.

## Adapter boundary

A future adapter should implement: connect/authenticate, receive utterance, cancel generation on press, stream a reply, report connection/error state, and preserve per-provider conversation state. Credentials must remain outside the repo. Switching providers should be explicit, with clear treatment of whether history is carried across.

Current limitations include runtime event-file growth, main-queue playback scheduling, no acoustic latency measurement, no always-on model connector, and incomplete disconnect/recovery handling. Resolve these before unattended or public binary use.
