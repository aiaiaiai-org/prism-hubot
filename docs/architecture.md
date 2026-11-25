# Architecture

`prism-hubot` is a concrete Telegram client product for Prism. It is not a second publishing backend.

```text
Telegram
  |
  v
prism-hubot
  |  product copy + interaction flows + client state adapter
  v
PrismBot::Client::Composition
  |
  v
prism-bot
  |  Prism Hub API v1
  v
prism-hub
  |  prism-execution.v1
  v
prism
```

## Ownership

`prism-hubot` owns only product composition and Telegram-facing product choices specific to this client: enabled flows, copy, defaults, deployment configuration, and short-lived conversational state persistence.

`prism-bot` owns reusable messaging-client infrastructure: Telegram webhook verification and parsing, immutable Telegram `SurfaceContext`, Hub identity resolution, per-user lifecycle gating, command/interaction routing, message delivery, generated Hub API integration, and reusable publishing use cases.

`prism-hub` owns human identity, workspaces, service principals, social accounts and access, channels, permissions, OAuth/credential lifecycle when implemented, and publication orchestration.

`prism` owns deterministic content variants, provider capabilities, preflight, dispatch, provider adapters, and typed delivery outcomes.

## Client composition

The client builds a `PrismBot::Client::Composition` of its own instead of extending prism-bot's default one:
the default commands (`/start` onboarding, `/context`, `/help`, `/status`, `/stop`, `/resume`, `/channels`,
`/publish`) are Hub-backed and are not part of a Whisper bot.

- Command handlers: `start`, `stop` (administrators and creator), `whisper` (voice to the group) and
  `whisper_private` (voice to the person), all declared **open commands**, so the webhook neither looks the
  person up in Hub nor consults the bot lifecycle. The handlers read Telegram's member status themselves
  (`Whisper::Access`: the bot must be an administrator, and a lookup Telegram does not confirm is never
  permission).
- One callback route, `wp`, for the picker's buttons.
- One observer, which feeds ordinary group messages into the bounded history while Whisper is on.
- A fallback that ignores everything else.

`lib/prism_hubot/command_menu.rb` is the single list of the four commands and of which scope shows which
(administrators: all four; other group members: the two Whisper commands; private chats: none).

## Telegram surface context

`prism-bot` parses each Telegram update into an immutable `SurfaceContext` carrying the stable chat address plus an optional topic ID. Whisper is switched on per chat or topic, and every reply keeps the originating `message_thread_id` through `update.reply_target`.

Mutable chat titles are presentation-only. Human identity does not come from a chat surface.

## Interaction state

Conversational state implements `PrismBot::Ports::InteractionStateStore` in `FileInteractionStateStore`.

The key is derived from the canonical interaction tuple:

```text
client instance + telegram:<chat_id>:<topic_id|root> + Hub-resolved canonical actor reference
```

This prevents a pending interaction in one chat or topic from consuming a message from another surface for the same person.

The on-disk file name is a SHA-256 fingerprint of that tuple, so the actor reference and Telegram address are not exposed in the directory listing. Each state document contains only a format version, expiry timestamp, state name, and JSON-compatible state data.

Writes use a mode-`0600` temporary file, `fsync`, and atomic rename. States expire after a configurable TTL and are removed when next read. The implementation intentionally avoids process-global memory, so restarting the bot does not by itself discard an in-progress interaction.

The surface-key upgrade does not fall back to the previous flat `telegram` key: doing so would defeat cross-chat/topic isolation. Existing pending interactions therefore restart after adopting the new dependency pin. Because filenames are hashes, an operator cleaning old unreachable files should stop writers and wait at least one configured TTL before removing expired interaction-state files.

This adapter assumes one active process over one state directory. A future horizontally scaled deployment should replace it with a shared store implementing the same port; the product flow does not change.

## Dependency rules

- `prism-hubot` talks to providers only through `prism-bot` and Prism Hub contracts.
- Raw provider credentials never belong in this repository or Telegram messages.
- Client-specific UX must not be implemented by copying `prism-bot` internals.
- Shared behaviour needed by multiple bot clients moves down into `prism-bot` behind its public composition boundary.
- `prism-bot` is pinned to an immutable commit until a released package/versioning channel replaces the Git dependency.
- Infrastructure upgrades are deliberate dependency updates with CI, never implicit changes from a floating branch.
- The local interaction-state directory is operational client state, not identity, social-account, channel, credential, or publication truth.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
