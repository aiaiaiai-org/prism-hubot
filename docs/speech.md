# Whisper speech (text to voice)

Whisper turns the chosen messages into one native Telegram voice message. This repository owns the
*adapters* of that path; the speech runtime itself is prism-ai's (`services/tts`), the identity is
AIS's, and Telegram transport is prism-bot's.

```text
chosen messages -> narration text (<= 4000 characters)
  -> AisTokenSource   product token: client_credentials + private_key_jwt (Ed25519), aud prism-ai,
                      scope tts.synthesize, kept in memory only
  -> HttpSynthesizer  POST <PRISM_HUBOT_TTS_URL> {"text","voice"}  ->  PCM16 WAV (validated)
  -> OpusEncoder      opusenc (opus-tools) over pipes             ->  Ogg/Opus
  -> Voice            PrismBot::Domain::VoiceClip (whole-second duration)
```

Nothing here keeps text or audio: the text goes to the service once over HTTPS, the audio only passes
through the process's pipes, and failures carry a code (`Speech::Failure`), never text, audio, tokens
or response bodies.

## Configuration

Speech is optional and all-or-nothing. With no `PRISM_HUBOT_TTS_URL`, Whisper works as before and
says voice is unavailable; with a URL and a missing credential the process refuses to start.

| Variable | Meaning |
| --- | --- |
| `PRISM_HUBOT_TTS_URL` | https URL of prism-ai's `POST /v1/speech` |
| `PRISM_HUBOT_TTS_VOICE` | voice alias the service knows (default `uk-UA`) |
| `PRISM_HUBOT_AIS_CLIENT_ID` | this product's AIS client id |
| `PRISM_HUBOT_AIS_PRIVATE_KEY` | its Ed25519 private key, PEM (secret; `\n` escapes allowed) |
| `PRISM_HUBOT_AIS_TOKEN_URL` | AIS token endpoint (default `https://auth.aiaiaiai.org/token`) |

## What is not verified, and what this does not provide

- **The AIS token request is unverified.** It follows RFC 7523 and the Hub's protocol notes
  (`client_credentials`, `private_key_jwt`, EdDSA, `exp` ≤ 5 minutes). AIS's own contract
  (`aiaiaiai-org/4x-ais`, `docs/runtime.md`) was not readable when this was written; the parameter
  naming the audience (`audience`) is the first thing to check against it. The source is a plain
  object (`#call`, `#reject`), so replacing it does not touch the rest.
- **The speech service is not deployed**, and no AIS client or `tts.synthesize` grant exists for
  prism-hubot. Without both, nothing here can produce audio in production.
- **Encoding uses `opusenc`**, so the image needs `opus-tools`. prism-ai's README names prism-porter as
  the owner of delivery-format conversion; Porter's interface could not be read, so this is an interim
  adapter behind a one-method port (`#call(wav) -> Ogg/Opus bytes`).
- The result is not wired into `/whisper` yet: that is a separate change.
