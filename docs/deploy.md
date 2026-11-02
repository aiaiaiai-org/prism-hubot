# Deployment

`prism-hubot` is a container workload of `aiaiaiai-org/infra` on `edge-prod-2`.
This repository publishes; infra deploys. It holds no credential for infra and
no SSH material.

## Delivery chain

`Full CI (master) → Publish image → ghcr.io image + sealed secrets, both attested → infra Reconcile deliveries → infra Deploy workload`

1. **Full CI** verifies a commit on `master`.
2. **Publish image** (`.github/workflows/publish.yml`) runs only after a green
   Full CI for the current `master` head. It builds that commit, pushes
   `ghcr.io/aiaiaiai-org/prism-hubot:<full commit SHA>` and attests it. In this
   repository's `production` Environment it then seals the runtime secrets with
   `age` to the target server's public key (`encryptionRecipient` in infra's
   server contract) and publishes them as `…:<full commit SHA>.secrets`,
   attested the same way. The secret names come from infra's `prism-hubot`
   contract; if they differ from what the workflow seals, it stops.
3. **Infra** verifies both, decrypts the envelope only inside its deploy job
   for the target, and starts the container. See infra's
   `docs/automatic-delivery.md`.

**Image** proves on every pull request that the image builds and serves
`/healthz`. Rollbacks are manual in infra: **Deploy workload** with an earlier
verified digest.

## Runtime

`bin/prism-hubot-container` is the image's one process. On every start it
checks that `PRISM_BOT_TELEGRAM_WEBHOOK_SECRET` is a value Telegram accepts
(32–256 characters of `A-Z a-z 0-9 _ -`), points Telegram at
`PRISM_HUBOT_WEBHOOK_URL` with that secret (`rake telegram:webhook`), publishes
the command menu (`rake telegram:commands`), and then serves Puma on port 1927.
If Telegram rejects either call, the container exits and the deployment fails.

Infra's contract sets the non-secret configuration: the instance id, the Hub
URL, the webhook URL (`https://api.aiaiaiai.org/prism-hubot/telegram/webhook`,
behind the `/prism-hubot/` edge route) and the interaction state directory on
the `prism-hubot-state` volume. Other settings keep the defaults in
`.env.example`.

## Secrets

In this repository's `production` Environment:

| Secret | Meaning |
| --- | --- |
| `PRISM_BOT_TELEGRAM_TOKEN` | BotFather token |
| `PRISM_BOT_TELEGRAM_WEBHOOK_SECRET` | Telegram's `secret_token` for this webhook; set on every start, so changing it here and republishing rotates it |
| `PRISM_HUB_API_TOKEN` | scoped Prism Hub client credential, at least 32 characters |
| `PRISM_BOT_DELIVERY_SECRET` | authenticates `POST /api/v1/delivery` from Prism Hub; 32–256 characters of `A-Z a-z 0-9 _ -`. prism-bot requires it. Generate it for this bot alone: Hub delivers to one destination (h-ua-bot today), so it is not shared yet |

They leave this repository only sealed to the target's public key. Infra stores
none of them. `INFRA_DEPLOY_TOKEN` is no longer used and can be deleted.

## Receiving Hub deliveries

`PRISM_BOT_DELIVERY_SECRET` mounts `POST /api/v1/delivery`, the receiving side
of Prism Hub's delivery worker, with its idempotency records in
`/data/delivery-idempotency` on the state volume. Hub sends to one destination,
so this bot receives deliveries only once Hub is pointed at it with the same
secret.

## Telegram command menu

The in-app command list (the `/` menu in Telegram clients) is server-side state
owned by the bot token, not by the running process: a bot that never calls
`setMyCommands` shows an empty menu no matter how many commands it routes.
`lib/prism_hubot/command_menu.rb` is the single source of truth for that list,
and `/help` is rendered from the same entries, so the menu and the help text
cannot drift. A test asserts the menu covers exactly the routed commands.

The container publishes it on every start (`bin/prism-hubot-container`), together
with the webhook. Locally, the task reads the token from `.env` in the working
directory; `PRISM_HUBOT_ENV_FILE` overrides the path, and variables already
exported into the process win over the file. To do it by hand:

```bash
bundle exec rake telegram:commands         # publish the menu
bundle exec rake telegram:commands_status  # show what Telegram currently serves
```

The menu is per bot token and global, so it applies to every chat at once.
Telegram clients cache it; an open chat may need a restart to redraw the list.

## Telegram webhook

`prism-bot` serves `/telegram/webhook` but never registers it, so a fresh bot
token receives nothing until an operator points Telegram at the deployment. An
unregistered webhook looks exactly like a broken bot: every command is routed
correctly and no update ever arrives.

Set `PRISM_HUBOT_WEBHOOK_URL` in `shared/.env` to the public HTTPS URL of
`/telegram/webhook`, then:

```bash
bundle exec rake telegram:webhook         # register it
bundle exec rake telegram:webhook_status  # url, pending updates, last error
```

Registration is idempotent and is deliberately not part of `Deploy`: the
public URL belongs to the fronting TLS terminator, not to a release. Re-run it
when the public URL or the webhook secret changes.

`telegram:webhook` sends `secret_token`, and the process rejects updates whose
`X-Telegram-Bot-Api-Secret-Token` header does not match
`PRISM_BOT_TELEGRAM_WEBHOOK_SECRET`. A `last_error_message` of `403` in
`webhook_status` therefore means the two have drifted apart.

## Receiving Hub deliveries

Prism Hub can schedule content — mail digests today — for a Telegram surface
this deployment already exposes, without going through `/telegram/webhook` or
any command: its delivery worker resolves a `TelegramSurfaceBinding`, renders
the content through Porter, and pushes each rendered chunk straight to
`POST /api/v1/delivery` on this deployment's public origin
(`PrismHub::Adapters::HttpBotDeliveryGateway`, configured there as
`PRISM_BOT_ORIGIN`).

This client only relays what Hub already decided to send; it does not decide
what gets sent, to whom, or on what schedule — that stays entirely Hub-owned,
same as channels and identity. Setting `PRISM_BOT_DELIVERY_SECRET` in
`shared/.env` is what opts this deployment into the integration:

```text
#PRISM_BOT_DELIVERY_SECRET=replace-with-at-least-16-random-characters
#PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR=var/delivery-idempotency
#PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS=86400
#PRISM_HUBOT_DELIVERY_RESERVATION_TTL_SECONDS=30
#PRISM_HUBOT_DELIVERY_MAX_BODY_BYTES=65536
```

Leave it unset and nothing changes: `config.ru` mounts no `/api/v1/delivery`
route at all, so there is nothing for an unconfigured Hub deployment to reach
and nothing for an attacker to probe. Set it and it must equal, byte for byte,
whatever Hub's own `PRISM_BOT_DELIVERY_SECRET` is configured with — that is the
only credential authenticating this endpoint; there is no per-request Telegram
or Hub identity check here, by design, because Hub already did that resolution
before it ever calls in.

Every request must carry the matching `x-prism-bot-delivery-secret` header and
a `chat_id`/`text`/`idempotency_key` (and optional `message_thread_id`) JSON
body; anything else is `401`/`415`/`400`.

### Duplicate suppression is best-effort, not exactly-once

Telegram's Bot API has no client-supplied idempotency key of its own: once a
chunk is sent, there is no way to ask Telegram "did I already send this?",
only this client's own record of having tried. Each `idempotency_key` moves
through a small reservation under `PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR`:

- a request atomically claims the key before calling Telegram, so a second
  request for the same key arriving while the first is still in flight — a
  real possibility, since Hub's own lease can expire and retry while this
  client's call to Telegram is still outstanding — sees the reservation and
  answers `409` instead of also calling Telegram; Hub's normal retry/backoff
  handles the `409` like any other transient failure;
- a completed delivery is remembered for `PRISM_HUBOT_DELIVERY_IDEMPOTENCY_TTL_SECONDS`
  (default one day) and replayed on retry instead of calling Telegram again;
- a delivery attempt that fails in a way this process observes (Telegram
  rejects it, rate-limits it) releases its reservation immediately, so the
  next retry is not made to wait.

What this cannot close: if the process dies — a normal `Deploy` restart counts
— between Telegram accepting a chunk and that fact being recorded, the
reservation is orphaned. A retry for that key waits out
`PRISM_HUBOT_DELIVERY_RESERVATION_TTL_SECONDS` (default 30s, sized to outlast
one real attempt to Telegram, not to survive a crash) and then reclaims it,
which can duplicate that one message. No file-based store on this side can
close that window to zero; a lower TTL narrows it at the cost of occasionally
reclaiming a reservation while it is still genuinely in flight.

Like `var/interaction-state`, this directory is short-lived client
bookkeeping, not business data: losing it entirely only risks a duplicate
message on the next retry, never a wrong delivery.

A `429` from Telegram is reported back as `429` with `retry_after_seconds`, so
Hub's own backoff applies; anything else Telegram rejects is reported as `502`
so Hub retries; a malformed request from Hub itself is `400` and is not
retried, since Hub is expected to always send a well-formed request.

## Rollback

```bash
ln -sfn "/opt/prism-hubot/releases/<previous-sha>" "$DEPLOY_PATH/current.tmp"
mv -T "/opt/prism-hubot/current.tmp" "/opt/prism-hubot/current"
sudo systemctl restart prism-hubot.service
```

Re-running `Deploy` with an older `ref` is equivalent and keeps the release
history consistent.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
