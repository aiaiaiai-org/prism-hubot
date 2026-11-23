# Whisper — Telegram group message readback (proposal)

**Status:** proposed; documentation only. No message collection, speech generation, or Telegram voice delivery is implemented by this document.

Whisper lets a member of a Telegram group ask `@prism-hubot` to **read a short range of group messages aloud and reply with a native Telegram voice message in that same chat/topic**. It is readback, not summarization or transcription. A language model is not required.

The product name **Whisper** does not imply integration with OpenAI's Whisper speech-to-text model: this feature needs **text-to-speech (TTS)**.

## User experience and command contract

| Group message sent by a member | Messages included in voice output |
| --- | --- |
| `@prism-hubot последние 5` | The 5 most recent eligible messages before the command |
| `@prism-hubot последние 10` | The 10 most recent eligible messages before the command |
| `@prism-hubot экран` | An **approximate** screen-sized selection, not actual device viewport content |
| Reply to a message with `@prism-hubot последние 10` | The replied-to message **and the 9 eligible messages immediately before it** |
| Reply with `@prism-hubot экран` | The screen-sized selection **ending at and including** the replied-to message |

- `N` is the **number of eligible messages**, not the number of Telegram message IDs, and never denotes a forward-looking range. Voice playback is in **chronological order (oldest → newest)**.
- No Reply: anchor is the last eligible message **strictly before the request**. With Reply: anchor is the Telegram `reply_to_message.message_id` in the same chat/topic, **inclusive**. A reply to a message after which new messages arrived still ends at the selected older message.
- Initial proposed bounds: `N = 1..50`; common shortcuts are 5 and 10. The special `экран` mode selects up to **2,000 characters / 20 eligible messages**, walking backward from its anchor; these limits are product defaults to validate during implementation.
- Telegram does **not** provide the bot with the requesting user's currently visible screen, scroll position, or viewport size. The word “экран” is therefore a convenience preset, **not** a literal screenshot-reading feature.
- A successful request produces **one normal Telegram voice message** as a reply to the request in the same chat and forum topic. No document attachment, `sendAudio` music-player item, external link, or Mini App is an acceptable substitute.
- Keep author changes audible (e.g., “Vlad: …”, “023: …”); preserve punctuation and the original order. Text and captions are eligible; stickers, videos, voice notes, service messages, bot-generated output, and the invocation itself do not count. Do not silently invent text for non-text media.
- Treat Telegram reply quoting as a location marker only; do not prepend the quoted message a second time. Messages that themselves quote another message contribute only their own authored text/caption.
- The feature must never publish the selected chat text to Prism publication channels: the output is confined to the requesting Telegram chat/topic.

### User-visible failures

Respond in the requesting chat/topic with a concise explanation when:

- Whisper has not been enabled by that chat's administrators;
- the bot cannot receive ordinary group messages because of Telegram group privacy settings;
- the requested older history was never observed (including messages predating the bot's arrival);
- the selected Reply anchor is unavailable, outside the retained history, or belongs to a different chat/topic;
- no eligible text exists, the request exceeds limits, or speech generation fails.

Do **not** pretend to have read the full requested range if fewer messages are available. A deliberate, explicitly labeled partial-readback mode could be added later; it is not part of the initial contract.

## Telegram API constraints

Telegram Bot API does **not** expose an arbitrary “get last N messages from group history” endpoint. The bot must observe new updates as they arrive and maintain a bounded history buffer. A reply update supplies `reply_to_message` (subject to Telegram availability), identifying an anchor, **not** the surrounding history.

To receive normal group messages, the bot must be a group administrator or have Group Privacy Mode disabled and be correctly re-added when required. The group should opt in explicitly to retained history; being able to receive messages is not itself consent to indefinitely archive them.

Native voice delivery uses **`sendVoice`**, with a compatible synthesized file (prefer **OGG/Opus**), the original `chat_id`, the applicable `message_thread_id`, and `reply_parameters.message_id` identifying the user's invocation. Validate that the returned Telegram message has the voice-message form; a `sendAudio`, `sendDocument`, or URL response fails acceptance. Audio limits and encoding must be checked against the current Bot API contract.

References: [Telegram Bot API](https://core.telegram.org/bots/api#sendvoice), [Message reply fields](https://core.telegram.org/bots/api#message), [Privacy Mode](https://core.telegram.org/bots/features#privacy-mode).

## Proposed ownership and data flow

```text
Telegram group/topic updates
    -> prism-bot: verified webhook, update parsing, shared Telegram transport
    -> bounded per-surface message buffer (focused port / adapter)
    -> prism-hubot: Whisper command parsing + range selection + user copy
    -> TTS port: chunked text synthesis (provider adapter, local or cloud)
    -> prism-bot: Telegram sendVoice -> same chat/topic, reply to invocation
```

- **prism-hubot** owns the Whisper product workflow: vocabulary, anchor/range rules, author narration, configured limits, opt-in, and user-facing errors.
- **prism-bot** owns reusable Telegram update ingestion, transport, message/reply/thread addressing, and a reusable voice-sending capability if it needs extending. Do not duplicate webhook processing or Telegram HTTP handling inside the product client.
- **Message history buffer** is an explicit short-lived store keyed by `client_instance + chat_id + (message_thread_id|root)`. The current per-actor `FileInteractionStateStore` is **not** suitable as chat history: one surface contains many authors and needs separate retention and access controls. Use a dedicated bounded store; a shared store is required if horizontally scaling.
- **TTS** is an injectable port. A cloud adapter may minimize CPU; a server-local engine can reduce variable provider charges. A mobile iPhone TTS engine cannot generate a voice message for a bot running on the server. Do not couple the client to one TTS vendor or treat the existing publication `voice profile` as proof of a speech-synthesis implementation.
- **prism-hub** remains responsible for existing identity/lifecycle/authorization contracts. Only add a Hub API if a cross-client policy truly requires it. No raw private identity IDs, cross-product conversation content, or new shared publication workflow should leak into this client feature.
- **Infrastructure** owns deploy, runtime secrets, resource limits, and operational configuration; this documentation does not authorize deployment.

### Buffer and audio processing policy (proposed defaults)

- Enable Whisper per chat/topic only with explicit administrator authorization; visibly disclose that message text is buffered for voice readback. Disabling the feature clears retained history and stops new collection.
- Retain **at most the last 100 eligible messages per surface**, for **up to 24 hours**; expire by both count and age. These are starting defaults, not existing deployed settings. Do not store message content in logs, analytics, or a global cross-chat cache.
- Store only what is needed: message ID, chat ID, topic ID, timestamp, author display label, and text/caption. Avoid unnecessary provider identity metadata; protect persistence at rest and segregate tenants.
- Handle duplicate/out-of-order Telegram updates idempotently; respect edit/delete notifications where Telegram actually supplies them, and document that Bot API does not guarantee every deletion event can be observed.
- Restrict membership/permission to the originating group and preserve thread isolation; never fulfill a Reply that points outside the accessible surface. Apply a per-user/per-chat request rate limit and a total character/audio-duration cap.
- Assemble deterministic, ordered text, trim unsupported markup, chunk at message/sentence boundaries, synthesize asynchronously with bounded concurrency, and stop producing more chunks when the request is canceled or times out.
- If TTS is external, inform administrators that selected message text is sent to a third-party provider; apply data-retention controls and disable provider-side logging where the contract permits.
- Avoid permanent storage of completed audio on the server. Delete temporary files when delivery succeeds or fails. Do not cache one group's output for another group.
- Reporting/telemetry can record status, correlation ID, duration, counts, and provider failure codes **without message text or synthesized audio**. Reporting must never block normal bot recovery.

## Acceptance scenarios

1. **Five messages:** after the bot has observed at least five eligible messages, a group member writes `@prism-hubot последние 5`. One native Telegram `voice` message is returned in reply to the invocation, with exactly those five authored messages read in oldest-to-newest order.
2. **Older Reply anchor:** a member replies to an earlier eligible message with `@prism-hubot последние 10`. Voice narration ends with the selected earlier message, includes it once, and excludes all later chat messages.
3. **Screen preset:** `@prism-hubot экран` uses the documented character/message preset, does not claim access to the user's actual phone viewport, and respects a Reply anchor if present.
4. **Forum isolation:** identical requests in two topics never mix their buffered message history or send output to the wrong `message_thread_id`.
5. **History gap:** if a request needs messages from before the bot joined or before retention began, a clear error is sent; no hallucinated or silently incomplete voice output.
6. **Privacy:** a group without explicit opt-in is not buffered; an admin disable erases the stored buffer, and data from another chat is never readable via a Reply or command.
7. **Transport check:** verify an actual Bot API `sendVoice` call and returned `Message.voice` from a Telegram test chat; simply generating an audio file does not pass.
8. **Failure and bounds:** invalid N, unavailable reply target, TTS failure, deduplicated request, and exceeded provider/Telegram limits leave a recoverable state without leaking text or generating unintended duplicate voice messages.
9. **Compatibility:** existing `/post`, `/publish`, `/status`, and other client interaction routes remain unchanged; Whisper does not inadvertently consume a pending publish-flow message.

## Delivery status

This document is a **feature specification only**. Open implementation work remains: Telegram message observation and bounded history, group opt-in, reply-aware range parser, TTS port/adapter, shared native-voice sender, cost/rate controls, privacy tests, and live Telegram E2E. Do not mark Whisper implemented or deployed until the exact-head code, CI, and runtime behavior have been verified.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
