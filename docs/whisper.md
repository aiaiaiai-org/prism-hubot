# Whisper — Telegram group message readback (proposal)

**Status:** proposed; documentation only. No message collection, speech generation, or Telegram voice delivery is implemented by this document.

Whisper lets a group member select an existing message or a range of messages and get **a native Telegram voice message visible only to that member by default**. This is literal text-to-speech readback, not summarization or transcription, and requires no LLM. **A public group voice message is a separate opt-in share action, never a default effect.**

The product name **Whisper** does not imply integration with OpenAI's Whisper speech-to-text model: this feature needs **text-to-speech (TTS)**.

## Privacy and product invariants

1. **Private by default:** the selection UI, progress, errors, and final voice output are ephemeral messages targeted to the requesting Telegram user within the originating group/topic (or an explicitly requested private conversation). No group message text or generated audio is posted publicly without a deliberate, authenticated share action.
2. **Every bot-owned private message must visibly state its audience:** prefix private text, picker, updates, and voice captions with **`🔒 Приватно · Whisper`**. When a user explicitly shares, label the outgoing public voice **`🔓 Для всіх · Whisper`**. Never label a public message as private. Telegram's own ephemeral UI indicators supplement, but do not replace, this label.
3. **Single mutable status message:** selection → synthesis → delivery updates use one `ephemeral_message_id` and `editEphemeralMessageText` (or the appropriate ephemeral edit method), not a stream of new bot status messages. `set_message` is the product's state-update concept, **not** a Telegram API method. The finished voice is its own native `sendVoice` message; edit the status to “Готово” with an optional “Поділитися з усіма” button.
4. **No implicit public fallback:** if Telegram cannot deliver privately, show no public transcription, audio, picker, or error containing private message content. Record a redacted operational failure instead; offer a private chat when safely possible.
5. **Privacy of the *user's request* matters too:** sending a normal `@prism_hubot …` message to a group is visible to the group. Merely replying ephemerally does **not** retroactively hide that request. For the fully private invocation guarantee, register `/whisper` as an `is_ephemeral` bot command in supported groups (or use a private chat). The @mention syntax below is a **desired shorthand** for compatible surfaces, not a claim that Telegram makes ordinary mentions private.

## User experience and command contract

| Proposed request / selection | Meaning |
| --- | --- |
| `/whisper` (ephemeral group command) | Privately open the current group's message picker without posting a visible command |
| `@prism_hubot` | Intended shorthand: all authors; ordinary @mention text is **public**, so do not silently claim a private invocation |
| `@prism_hubot @username` | Intended shorthand: filter the private message picker to one author |
| `@prism_hubot @username @username_2` | Intended shorthand: show messages by either author (combined chronological range) |
| `@prism_hubot 5` / `10` | Optional bounded count; the default picker does not require “останні” |
| Reply with `/whisper` | Use the replied-to message as a possible anchor when supported by the client |
| `/whisper 10` in a Reply | Select the replied-to message **and the 9 eligible preceding messages** (legacy backward-count contract) |
| `/whisper екран` | Approximate screen-sized preset; Telegram does not expose the user's viewport |

**Primary interaction — picker:** show a **private, paginated list** of recently observed messages, with the author, time, and a short, safe text snippet (never a public inline-result list). Selecting a message chooses that message as the **inclusive starting point**, and reads that message plus every newer eligible message matching the selected author filter up to a **fixed invocation-time snapshot**. Order of spoken text is chronological (oldest → newest); a second user joining the chat cannot extend an in-flight selection. Preserve the same `chat_id` and `message_thread_id` throughout.

- Multiple authors: the query `@username @username_2` selects the **union** of both authors, not N messages per author. Resolve observed author IDs and confirm identities; user-facing handles are mutable labels, not permanent identity keys.
- Initial proposed safety limits: at most 50 messages / 4,000 narrated characters (about 5 minutes of speech, the speech service's cap) per generation, applied *before* TTS. If a selection exceeds these limits, show the exact limitation **privately** and require narrowing it; never silently truncate.
- Telegram Bot API cannot tell a bot which messages are visible on an iPhone screen. The word `екран` is only a preset for approximately 2,000 characters / 20 messages.
- Text and captions are eligible; service messages, stickers, video/voice-only messages, bot replies, the invocation itself, and unobserved history are not. Quote text is an anchor/selection only, not duplicate content. Identify author changes in narration without guessing missing content.
- The simplest starting version is a **single narrator voice**, speaking author names on changes. Multi-voice dialogue is an optional later feature, not a prerequisite.
- **No public Telegram Inline Mode for group-history snippets:** traditional inline results appear over the keyboard but selecting one sends content to the current chat; `InlineQuery` does not identify the exact group history. The desired “list over the keyboard” resembles inline UX but cannot guarantee private per-group browsing. Implement the safe MVP as an ephemeral `/whisper` command with private inline-keyboard buttons; revisit the exact keyboard-overlay affordance only with a verified Telegram API that can maintain the privacy contract.
- **User-confirmed publishing:** after private delivery, offer “Поділитися з усіма” → explicit confirmation (scope, voice preview, destination) → one public `sendVoice` to the same authorized group/topic, labeled `🔓 Для всіх · Whisper`. No auto-share, no external Prism publication workflow, and no cross-chat forward. The private voice stays private even if sharing fails.


### User-visible failures

All failures must be **ephemeral and visibly marked `🔒 Приватно · Whisper`**. Explain precisely when Whisper is not enabled, the bot lacks ordinary-message access, the anchor or requested history is unavailable, a selected author cannot be resolved, the request exceeds generation limits, TTS fails, or Telegram refuses private delivery. If ephemeral delivery fails, **never post a public replacement containing context**.

Do not pretend that requested unavailable history was read, or silently reduce the selected range. The user may choose a smaller range or retry. Avoid group-visible error text that includes quotes, usernames, or private history details.

## Telegram API constraints

The Telegram Bot API cannot fetch arbitrary historic group messages. A bot must first be made able to observe new updates (administrator status or Privacy Mode disabled), then buffer only that group's explicitly enabled messages. History before observation is unavailable; an ordinary Reply may provide `reply_to_message`, not the surrounding history.

**Ephemeral messages:** Bot API 10.2+ supports `BotCommand.is_ephemeral` for private group commands, `sendMessage` and `sendVoice` with `ephemeral_message_parameters`, and `editEphemeralMessageText` for mutable private status. The ephemeral response must be addressed to the initiating `receiver_user_id` (or use an authorized callback context) with the original `chat_id` and topic where applicable. Preserve `ephemeral_message_id` for edits and verify `Message.receiver_user` and ephemeral properties in live tests. Telegram does not guarantee that every ephemeral message/edit reaches an offline user; never infer delivery from an API success alone.

**Native voice:** upload OGG/Opus (preferred), or another format explicitly supported by Telegram `sendVoice`; use `sendVoice`, **not** `sendAudio` / `sendDocument`. A private voice carries the explicit caption `🔒 Приватно · Whisper` and `ephemeral_message_parameters`; a user-approved public voice carries `🔓 Для всіх · Whisper` and no ephemeral parameters. Verify the Bot API result is a `Message.voice`. Respect the current Telegram file-size limit and bounded audio duration.

**Regular mentions are public:** while the bot can answer a normal @mention ephemerally, the mention itself is posted to the group. Do not imply that such a flow meets the “private conversation” invariant. The user can invoke `/whisper` privately or open a private bot conversation instead.

References: [Telegram Bot API — sendVoice](https://core.telegram.org/bots/api#sendvoice), [EphemeralMessageParameters](https://core.telegram.org/bots/api#ephemeralmessageparameters), [ephemeral message editing](https://core.telegram.org/bots/api#editephemeralmessagetext), [Telegram bot feature: two-way privacy](https://core.telegram.org/bots/features#ephemeral-messages), [Inline Mode](https://core.telegram.org/bots/inline).

## Proposed ownership and data flow

```text
Observed Telegram updates (opted-in group/topic)
  -> prism-bot: verified webhook, Telegram surface + author addressing
  -> bounded, opt-in per-surface message buffer
  -> prism-hubot: ephemeral /whisper + private picker + author filtering
  -> immutable anchor/selection snapshot
  -> TTS port: bounded, provider-agnostic synthesis
  -> prism-bot: ephemeral sendVoice, caption "🔒 Приватно · Whisper"
  -> optional explicit confirmation -> public sendVoice in originating group/topic
```

- **prism-hubot** owns Whisper intent, private selection UX, defaults, immutable range selection, explicit share consent and clear privacy markers.
- **prism-bot** owns Telegram transport and the reusable ephemeral-message, edit, reply, callback, and native voice delivery ports. Do not bypass its public client composition by copying Telegram request handling.
- **History buffer** is a dedicated store keyed by client instance + `chat_id` + topic. The existing per-actor `FileInteractionStateStore` is not group history; request state additionally keys the canonical actor and originating message/selection to prevent cross-user callback reuse.
- **TTS** uses an injectable adapter; server-side generation is required for `sendVoice`. Mobile iPhone TTS does not supply bot-side audio. Keep provider credentials out of the client and never treat a pre-existing “voice profile” as proof of TTS implementation.
- **prism-hub** continues to own existing actor/authorization boundaries; only add Hub contracts if shared policy truly requires them. Do not send private Bond IDs, chat excerpts or provider credentials into other products.
- **Infrastructure** owns runtime constraints and deployment. This proposal changes no runtime and provides no permission to publish or deploy.

### Buffer and audio processing policy (proposed defaults)

- Enable Whisper per chat/topic only with explicit administrator authorization; visibly disclose that message text is buffered for voice readback. Disabling the feature clears retained history and stops new collection.
- Retain **at most the last 100 eligible messages per surface**, for **up to 24 hours**; expire by both count and age. These are starting defaults, not existing deployed settings. Do not store message content in logs, analytics, or a global cross-chat cache.
- Store only what is needed: message ID, chat ID, topic ID, timestamp, author display label, and text/caption. Avoid unnecessary provider identity metadata; protect persistence at rest and segregate tenants.
- Handle duplicate/out-of-order Telegram updates idempotently; respect edit/delete notifications where Telegram actually supplies them, and document that Bot API does not guarantee every deletion event can be observed.
- Restrict selection and callbacks to the original requester, group and forum topic; never fulfill a Reply from another surface or let a forged callback change the speaker/target. Apply per-user/per-chat rate limits and a total character/audio-duration cap.
- Store a frozen upper bound (invocation-time newest message ID) for every private selection; later arrivals cannot expand the generated voice range.
- Mark **every** private user-facing picker, state update, error and voice as `🔒 Приватно · Whisper`; mark explicitly approved public audio `🔓 Для всіх · Whisper`. Include a permission/label assertion in integration tests.
- Assemble deterministic, ordered text, trim unsupported markup, chunk at message/sentence boundaries, synthesize asynchronously with bounded concurrency, and stop producing more chunks when the request is canceled or times out.
- If TTS is external, inform administrators that selected message text is sent to a third-party provider; apply data-retention controls and disable provider-side logging where the contract permits.
- Avoid permanent storage of completed audio on the server. Delete temporary files when delivery succeeds or fails. Do not cache one group's output for another group.
- Reporting/telemetry can record status, correlation ID, duration, counts, and provider failure codes **without message text or synthesized audio**. Reporting must never block normal bot recovery.

## Acceptance scenarios

1. **Default privacy:** in an enabled supergroup, the user invokes ephemeral `/whisper`; only that user sees `🔒 Приватно · Whisper`, the message picker, progress updates and completed native Telegram `voice`.
2. **One mutable status:** selection, synthesis and completion use the same ephemeral status message ID via edit methods, not successive public bot messages; the actual voice is sent separately.
3. **Author filtering:** the picker lists snippets for `@username` or the union `@username @username_2`. Selected author identities are resolved to stable Telegram IDs, and displayed usernames are not used as persistent keys.
4. **Selected start:** selecting an older message yields that message and all newer eligible filtered messages up to the fixed invocation-time snapshot, read oldest → newest; no unobserved or later-arriving messages are added.
5. **Legacy reply-count:** `/whisper 10` in Reply reads the selected anchor and the 9 preceding eligible messages, not the newer picker-forward range. Both directions are explicit and tested.
6. **Native transport:** verify a real `sendVoice` response includes `Message.voice` and the private recipient fields; no `sendAudio`, document or file-link fallback. Private voice caption clearly labels the audience.
7. **Public sharing:** an explicit “Поділитися з усіма” and confirmation cause one properly labeled `🔓 Для всіх · Whisper` voice in the original group/topic; closing/canceling never produces public output.
8. **No implicit leaks:** ephemeral transport error, TTS failure, stale callback, unknown @username or exceeded audio cap never emits private history/snippets/status as public group text.
9. **Regular mention honesty:** a standard `@prism_hubot` query is recognized as public input and does not claim fully private invocation; private command path works independently of Telegram Inline Mode.
10. **Telegram Inline Mode:** selecting public inline results cannot reveal buffered group history or be mistaken for a private picker; backend cannot infer chat ID from an inline query.
11. **Isolation:** simultaneous requests from two users and different topics never mix state, audio, or callback permissions. Private audio cannot be shared into another chat through forged callback data.
12. **Missing history, retention and compatibility:** unavailable older context reports a private error; opt-out clears buffered history; existing `/post`, `/status`, `/publish` and other handlers continue to work.

Tests for ephemeral delivery/recipient labeling and explicit public share confirmation are mandatory before Whisper can be considered implemented.

## Delivery status

This document is the feature specification. Implemented so far (not deployed, not checked against live Telegram): bounded opt-in history, administrator-gated enable/disable with public disclosure, group-message observation, and the private message picker with author, count and screen filters; see [whisper-history.md](whisper-history.md). Open implementation work remains: reply-count selection, TTS port/adapter, native-voice delivery wiring (the sender ports ship in prism-bot), explicit share confirmation, cost/rate controls, privacy tests, and live Telegram E2E. Do not mark Whisper implemented or deployed until the exact-head code, CI, and runtime behavior have been verified.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
