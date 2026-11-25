# prism-hubot

Personal Telegram client for multi-channel publishing through Prism.

`prism-hubot` is the first concrete client product built on [`aiaiaiai-org/prism-bot`](https://github.com/aiaiaiai-org/prism-bot). It composes shared bot infrastructure instead of reimplementing Telegram transport, Prism Hub authorisation, lifecycle, or publishing behaviour.

## Current client

Prism Hubot is a Whisper bot: **four commands and nothing else**. It extends the public client-composition contract of [`prism-bot`](https://github.com/aiaiaiai-org/prism-bot) and declares all four as *open commands*: nobody needs a Prism Hub identity, and each handler decides from Telegram's own member status what its sender may do.

| Command | Who | What |
| --- | --- | --- |
| `/start` | administrators and the creator of the group | switch [Whisper](docs/whisper.md) on for this group or topic; the group is told in public that message texts are being kept |
| `/stop` | administrators and the creator | switch it off and erase what was kept |
| `/whisper` | every member, after `/start` | choose messages privately; the voice goes to **everyone** in the group (`🔓 Для всіх · Whisper`) |
| `/whisper_private` | every member, after `/start` | the same choice; the voice goes **only to you** (`🔒 Приватно · Whisper`) |

All four are ephemeral commands: the group never sees them. Telegram's menu shows `/start` and `/stop` to administrators only, and shows nothing in private chats; the handlers check membership regardless of the menu. Every other command and message is ignored. The former publishing client (`/post`, `/publish`, `/channels`, `/status`, `/context`, `/help` and the create-post flow) is not part of this client.

Telegram channels (broadcast, no authors) are not supported; groups, supergroups and forum topics are.

Provider credentials never enter this client.

## Whisper status

[Whisper](docs/whisper.md) voice readback is implemented behind configuration (see [speech](docs/speech.md)): private selection, a private or group-wide voice, and the explicit privacy labels. It is not deployed and not yet checked against live Telegram or the speech service. A separate "share this private voice with everyone" confirmation is not planned: choosing `/whisper` is that choice.

## Run locally

Ruby `4.0.6` is pinned in `.ruby-version`.

```bash
bundle install
cp .env.example .env
set -a && source .env && set +a
bundle exec rackup config.ru -s Puma -p 9292
```

The `source` line is a local convenience. The rake tasks below read the same file with a parser that follows systemd's `EnvironmentFile=` rules, which parses rather than executes it, so keep values quoted instead of shell-escaped; `bundle exec rake env:check` reports what it reads. In production the container gets its environment from infra; see [docs/deploy.md](docs/deploy.md).

Configure Telegram to send updates to `/telegram/webhook` using the same webhook secret as `PRISM_BOT_TELEGRAM_WEBHOOK_SECRET`; `rake telegram:webhook` registers it from `PRISM_HUBOT_WEBHOOK_URL` and `rake telegram:webhook_status` reports what Telegram knows. `/healthz` is available for process liveness.

## Configuration

`.env.example` defines the runtime contract. Client defaults are explicit:

- instance: `prism-hubot`;
- locale: `uk-UA`;
- voice profile: `0x0sky.uk_SP`;
- dispatch policy: `require_all_valid`;
- interaction state TTL: `900` seconds;
- local interaction state directory: `var/interaction-state`.

`PRISM_HUBOT_INTERACTION_STATE_DIR` must point to persistent storage in a real deployment. The default relative directory is intended for local/single-node use. Do not place credentials in that directory; it contains only short-lived product interaction state.

Channel IDs remain empty until Hub exposes the concrete accounts/channels this client may publish to.

Setting `PRISM_BOT_DELIVERY_SECRET` mounts an additional, optional `POST /api/v1/delivery`: the receiving side of Prism Hub's delivery worker, which pushes content Hub already scheduled for a Hub-bound Telegram surface (mail digests today) so this client can relay it. Left unset, no such route exists. See [docs/deploy.md#receiving-hub-deliveries](docs/deploy.md#receiving-hub-deliveries).

### Rename migration

The Ruby entry point is `lib/prism_hubot`, with the `PrismHubot` namespace. Client-owned environment variables use `PRISM_HUBOT_INTERACTION_STATE_DIR` and `PRISM_HUBOT_INTERACTION_STATE_TTL_SECONDS`; previous names have no compatibility aliases. Shared `PRISM_BOT_*` and `PRISM_HUB_*` variables keep their existing contract.

The example instance ID is `prism-hubot`. For an existing installation, retain its current `PRISM_BOT_INSTANCE_ID`, state directory, and TTL when adopting the new variable names: the instance ID participates in interaction-state and publication idempotency keys. Changing it intentionally starts a separate logical instance. This rename does not migrate stored state or change routing, publication, or lifecycle behaviour.

### Surface-context dependency migration

The current Prism Bot pin replaces the old flat `telegram` interaction surface with `telegram:<chat_id>:<topic_id|root>`. Existing pending interactions under the previous key are intentionally not resumed because doing so would reintroduce cross-chat leakage.

`FileInteractionStateStore` hashes the whole interaction key, so old files cannot be identified by filename alone. If an existing installation needs to clean them up, stop writers and remove expired interaction-state files only after at least one configured TTL has elapsed. This repository does not perform that operational cleanup automatically.

## Architecture

```text
Telegram
  -> prism-hubot product composition
  -> aiaiaiai-prism-bot
  -> prism-hub API v1
  -> prism-execution.v1
  -> prism
```

See [`docs/architecture.md`](docs/architecture.md) for ownership, state-persistence, and dependency rules.

## Deployment

This repository only publishes: after Full CI verifies a `master` head, `Publish image` pushes and attests `ghcr.io/aiaiaiai-org/prism-hubot:<commit>` together with its runtime secrets sealed to the target's public key, and `aiaiaiai-org/infra` deploys it as a container on `edge-prod-2`. The container registers the Telegram webhook and command menu on every start. See [`docs/deploy.md`](docs/deploy.md) for the chain, the secrets and the runtime.

## Verification

```bash
bundle exec rubocop
bundle exec rake test
bundle exec bundle-audit check --update
```

No repository licence has been selected yet. Do not infer the licence of `prism-bot` or `prism` for this repository.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
