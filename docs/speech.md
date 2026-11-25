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

Nothing here keeps text or audio: the text goes to the service once (over HTTPS, or over cleartext HTTP to a private Docker network alias on the same server, see below), the audio only passes
through the process's pipes, and failures carry a code (`Speech::Failure`), never text, audio, tokens
or response bodies.

## In `/whisper`

Choosing a message in the picker fixes the range; with speech configured the bot then:

1. edits the person's own ephemeral picker message to `Вибрано N повідомлень (M символів). Озвучую…`;
2. in a small bounded background pool (2 workers, 6 queued; synthesis outlasts what Telegram waits for
   a webhook answer, and an unanswered update is sent again) turns the narration into a `VoiceClip`;
3. sends the voice: for `/whisper_private` as an ephemeral native voice **to that person only**, addressed as
   a member (the bot is an administrator wherever Whisper is on, which is what allows it after the 15
   seconds a button press entitles it to); for `/whisper` as a public voice in the group or topic. The
   caption is the audience label, then `Повідомлення від: ` and the display names of the authors whose
   messages are actually in the voice, in the order they first speak (not everyone the request named;
   if they do not all fit Telegram's 1024 characters, the rest is counted: `та ще N`);
4. **removes** the private status message once the voice has been delivered, so the voice stands in its
   place. Telegram cannot edit a text message into a voice (`editEphemeralMessageMedia` has no voice type,
   and `replace_callback_query_message` is not allowed on ephemeral messages), so the voice is a new
   message and the status is deleted. If the status cannot be deleted it is edited to
   `Готово: голос надіслано …` instead; if the voice could not be delivered the status stays and says why.

A person has one voice in progress per chat and topic; a second press, or a full pool, answers
"busy". Every failure is told in the private status message by code (service busy, too long,
timeout, encoding, not deliverable privately); none is ever posted to the group, a status that cannot
be edited privately is dropped, and the log carries a code and a class name only, never message text.
With no speech configured, the range is still chosen and the status says voice is not available.

## Configuration

Speech is optional and all-or-nothing. With no `PRISM_HUBOT_TTS_URL`, Whisper works as before and
says voice is unavailable; with a URL and a missing credential the process refuses to start.

| Variable | Meaning |
| --- | --- |
| `PRISM_HUBOT_TTS_URL` | URL of prism-ai's `POST /v1/speech`: https, or http to a single-label Docker network alias such as `http://prism-ai-tts:1927/v1/speech` (the service is private to the server's network and has no public route). A dotted name, an IP or `localhost` is never accepted over http. The AIS token URL is always https. |
| `PRISM_HUBOT_TTS_VOICE` | voice alias the service knows (default `uk-UA`) |
| `PRISM_HUBOT_AIS_CLIENT_ID` | this product's AIS client id: the one registered in 4x-ais, `prism-hubot` |
| `PRISM_HUBOT_AIS_KEY_ID` | the `kid` the public half of the key is registered under (default `k1`) |
| `PRISM_HUBOT_AIS_PRIVATE_KEY` | its Ed25519 private key (secret): one line of base64 of the PEM, or the PEM with `\n` escapes |
| `PRISM_HUBOT_AIS_TOKEN_URL` | AIS token endpoint (default `https://auth.aiaiaiai.org/token`) |

## What is not verified, and what this does not provide

- **The AIS token request is checked against AIS's own source** (`aiaiaiai-org/4x-ais`: `docs/runtime.md`,
  `src/product_token.rs`, the `client_credentials` branch of `src/issuer.rs`), not against a live AIS. The
  assertion needs `kid` in its header (a bug here until this was read), `iss` = `sub` = the client id, `aud`
  = the token endpoint, a 16-128 character `jti` and `exp` within five minutes; the form carries `audience`
  and `scope`, never a secret.
- **The speech service is not deployed**, and no AIS client or `tts.synthesize` grant exists for
  prism-hubot. Without both, nothing here can produce audio in production.
- **Encoding uses `opusenc`**, so the image needs `opus-tools`. prism-ai's README names prism-porter as
  the owner of delivery-format conversion; Porter's interface could not be read, so this is an interim
  adapter behind a one-method port (`#call(wav) -> Ogg/Opus bytes`).

## Registering prism-hubot in AIS

There is no portal and nothing is issued: a client exists once it is listed in `AIS_CLIENTS` in
`deploy/prepare-runtime-env.sh` of `aiaiaiai-org/4x-ais` (a reviewed change). `client_id` is chosen there
(lowercase letters, digits and `-`). For Whisper two entries are needed, because a product may only ask for
tokens for another registered **product**:

```json
{"client_id":"prism-hubot","name":"prism-hubot","skin":"slug","redirect_uris":[],
 "product":{"keys":[{"kid":"k1","x":"<public key of prism-hubot>"}],"tokens":{"prism-ai":["tts.synthesize"]},"relay":false}},
{"client_id":"prism-ai","name":"prism-ai","skin":"slug","redirect_uris":[],
 "product":{"keys":[{"kid":"k1","x":"<any Ed25519 public key>"}],"tokens":{},"relay":false}}
```

`x` is the raw 32-byte Ed25519 public key as unpadded base64url, from the PEM private key:

```bash
openssl pkey -in hubot-ais.key -pubout -outform DER | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
```

prism-ai's own entry only has to exist and hold a key (AIS requires one); it asks for no tokens, so a throwaway
key is enough. The speech service verifies tokens against `https://auth.aiaiaiai.org/.well-known/jwks.json`
(`TTS_AIS_JWKS_URL`), audience `prism-ai`, scope `tts.synthesize`.
