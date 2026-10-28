# prism-hubot

Personal Telegram client for multi-channel publishing through Prism.

`prism-hubot` is the first concrete client product built on [`aiaiaiai-org/prism-bot`](https://github.com/aiaiaiai-org/prism-bot). It composes shared bot infrastructure instead of reimplementing Telegram transport, Prism Hub authorisation, lifecycle, or publishing behaviour.

## Current client

The client pins an immutable `aiaiaiai-prism-bot` commit and extends its public client-composition contract with the first Prism Hubot-specific conversational flow.

Available interactions:

- `/start` — onboard or resolve the Telegram user through Prism Hub and show the current Telegram Context Card;
- `/context` — show the current chat/topic context without claiming an unverified Hub binding;
- `/post` — start a two-message create-post flow;
- `зробити допис` — natural-text alias for `/post`;
- `/cancel` — cancel a pending conversational action;
- `/help` — show the Prism Hubot command surface;
- `/status` — read the caller-owned bot lifecycle state;
- `/stop` — persistently pause the caller-owned logical bot instance;
- `/resume` — resume a paused instance;
- `/channels` — list Hub-authorised publishing channels;
- `/publish text` — publish text through configured default channels;
- `/publish [channel-a,channel-b] text` — publish to explicit Hub channel IDs.

`/post` stores `awaiting_post_content`, prompts for text, and publishes the next ordinary message through the same shared publication handler used by `/publish`. Successful publication clears the state. A publishing failure leaves the state pending so the user can retry or use `/cancel`.

Telegram interaction state is scoped by client instance, chat ID, topic ID (or root), and the Hub-resolved canonical actor. A pending flow in one group topic therefore cannot consume an ordinary message from another topic or chat. Product-specific replies preserve the originating `message_thread_id` through the shared `SurfaceContext.reply_target` contract.

Provider credentials never enter this client. Telegram identity evidence, human authorisation, social-account access, channels, and publication permissions are resolved server-side by Prism Hub.

## Run locally

Ruby `4.0.6` is pinned in `.ruby-version`.

```bash
bundle install
cp .env.example .env
set -a && source .env && set +a
bundle exec rackup config.ru -s Puma -p 9292
```

The `source` line is a local convenience. On the VPS the same file is read by systemd as an `EnvironmentFile=`, which parses rather than executes it, so keep values quoted instead of shell-escaped, and check what systemd would take from the file with `bundle exec rake env:check`. The rake tasks below read it through that same parser; see [docs/deploy.md](docs/deploy.md#environment-file).

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

`Deploy` is manual-only and accepts an optional `ref`. It dispatches to `aiaiaiai-org/infra`, which deploys this service exclusively on `edge-prod-2` using its host credentials and the reviewed workload contract. Merging to `master` runs verification workflows but does not deploy. The systemd unit is shipped with the repository (`deploy/prism-hubot.service`) and installed on the VPS once with `deploy/install-service.sh`. The Telegram command menu is published from `lib/prism_hubot/command_menu.rb` by `rake telegram:commands`, which `Deploy` runs on every release. See [`docs/deploy.md`](docs/deploy.md) for the required secrets, remote layout, and server prerequisites.

## Verification

```bash
bundle exec rubocop
bundle exec rake test
bundle exec bundle-audit check --update
```

No repository licence has been selected yet. Do not infer the licence of `prism-bot` or `prism` for this repository.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
