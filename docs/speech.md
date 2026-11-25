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

## In `/whisper`

Choosing a message in the picker fixes the range; with speech configured the bot then:

1. edits the person's own ephemeral picker message to `Вибрано N повідомлень (M символів). Озвучую…`;
2. in a small bounded background pool (2 workers, 6 queued; synthesis outlasts what Telegram waits for
   a webhook answer, and an unanswered update is sent again) turns the narration into a `VoiceClip`;
3. sends it as an ephemeral native voice **to that person only**, addressed as a member (the bot is an
   administrator wherever Whisper is on, which is what allows it after the 15 seconds a button press
   entitles it to), with the caption `🔒 Приватно · Whisper`;
4. edits the same status message to `Готово: голос надіслано лише вам.`

A person has one voice in progress per chat and topic; a second press, or a full pool, answers
"busy". Every failure is told in the same private status message by code (service busy, too long,
timeout, encoding, not deliverable privately); none is ever posted to the group, a status that cannot
be edited privately is dropped, and the log carries a code and a class name only, never message text.
With no speech configured, the range is still chosen and the status says voice is not available.

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
