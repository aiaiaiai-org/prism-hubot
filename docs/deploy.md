# Deployment

`prism-hubot` is deployed through the canonical `aiaiaiai-org/infra`
repository. This repository's Deploy workflow never opens SSH to a VPS and
does not contain the target host, user, private key, port, or deployment path.

The release remains directory-based: infra checks out the requested commit,
archives that exact source tree, installs it under the contracted
`/opt/prism-hubot` path, preserves shared runtime state, atomically repoints
`current`, restarts `prism-hubot.service`, and verifies that the unit remains
active. The target, path, service name, and release retention are all resolved
from the merged workload contract in infra.

## Trigger

- manually via `workflow_dispatch`, optionally with an explicit `ref`.

Deploy is deliberately not triggered by merges or CI completion. Merging to
`master` runs normal verification only; an operator explicitly starts Deploy
and selects the ref to release.

The workflow dispatches `deploy-workload` to `aiaiaiai-org/infra`. Infra then
selects the target GitHub Environment from the workload contract and reuses that
environment's machine credentials. GitHub's repository-dispatch API requires a credential with Contents write access
to the target repository; that credential is the only deployment secret kept
here and it grants no SSH access.

Deployments are serialised through the `deploy-vps` concurrency group and run
in the `production` environment, so approval or branch restrictions can be
attached there.

## Repository secrets

| Secret | Required | Meaning |
| --- | --- | --- |
| `INFRA_DEPLOY_TOKEN` | yes | GitHub credential allowed to create `repository_dispatch` events in `aiaiaiai-org/infra` |

No `SSH_*` secret belongs in this repository.

## Deployment contract

The current infra contract resolves:

| Property | Contract |
| --- | --- |
| Workload | `prism-hubot` |
| Repository | `aiaiaiai-org/prism-hubot` |
| Runtime | `systemd-release` |
| Target | `edge-prod-2` |
| Deployment path | `/opt/prism-hubot` |
| Service | `prism-hubot.service` |
| Release retention | `5` |
| Post-activation hook | `bundle exec rake telegram:commands` |

The target's `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, and optional
`SSH_PORT) are owned only by the corresponding GitHub Environment in infra.
The product repository supplies only the requested release ref. All `aiaiaiai-org/*`
product workloads (including Prism Hubot) are placed on `edge-prod-2`; 0x1
and Market workloads remain on `edge-prod-1`.

## Migration from edge-prod-1

Updating the infra contract changes where **future** dispatches deploy; it does not
move an existing systemd unit, files, credentials, webhook, or running process.
An explicitly authorised cutover must:

1. Prepare Ruby, Bundler, git, the systemd unit and SSH permissions on `edge-prod-2`.
2. Securely transfer the necessary `/opt/prism-hubot/shared/` runtime state
   (especially `.env` and persistent interaction/delivery state), retaining
   correct ownership and restrictive permissions; do not commit or print secrets.
3. Validate the new host and release before activation. Stop the old instance
   before activating the new one so the same Telegram bot does not have two
   live consumers.
4. Deploy via the product `Deploy` workflow (which dispatches to infra), then
   update and verify the public webhook origin as required. Confirm `/healthz`,
   webhook status, menu and Hub delivery before retiring the old host state.

Merging the infra or documentation PR must not deploy or restart either VPS.

## Remote layout

The release runtime uses:

```text
/opt/prism-hubot/
  current -> releases/<sha>
  releases/<sha>/
  shared/
    .env
    bundle/
    var/interaction-state/
    var/delivery-idempotency/
```

`shared/.env` and both state directories survive releases. The release
retention policy is owned by the infra contract, not by a product-repository
secret or variable.

## Server prerequisites

Infra does not provision the machine. Before the first deployment on
`edge-prod-2`, that target must already have:

- Ruby `4.0.6` and Bundler on the deploy user's `PATH`;
- `git`, because `aiaiaiai-prism-bot` is a pinned Git dependency;
- `/opt/prism-hubot/shared/.env`, containing the real runtime values and never
  committed to Git;
- `prism-hubot.service` installed and restartable by the deploy user through
  passwordless `sudo -n systemctl`.

The existing `deploy/install-service.sh` remains the provisioning tool for the
systemd unit. It is intentionally separate from release deployment.

## Environment file

`shared/.env` is read by systemd as an `EnvironmentFile=`, not by a shell. The
two are different languages, and the difference is not cosmetic: `bash` executes
what it reads, so `PRISM_BOT_TELEGRAM_TOKEN=<from-botfather>` is a redirection,
`SECRET=a|b` is a pipeline, and `URL=$(cat /etc/shadow)` is a command
substitution. A file the service starts from perfectly well used to abort the
deployment with `syntax error near unexpected token`.

Nothing in this repository sources that file any more. Deployment tasks read it
with `PrismHubot::EnvFile`, a transcription of systemd's own parser, so what the
tasks see is what the running service sees:

- `NAME=value`, one assignment per line; no `export`, and no whitespace around
  the `=`;
- `#` or `;` in the first non-blank column starts a comment;
- single and double quotes protect whitespace, `#` and shell metacharacters, and
  may span lines; `\` escapes the next character and continues the line at the
  end of one;
- trailing whitespace of an unquoted value is dropped;
- no variable expansion and no command substitution. `$` is a literal `$`.

systemd ignores lines it cannot parse and starts the service without them, which
looks exactly like a credential that was never set. `Deploy` therefore checks the
file after installing the release and before repointing `current`, so a bad line
fails while the previous release is still serving. Run the same check by hand:

```bash
cd /opt/prism-hubot/current
bundle exec rake env:check
```

It prints variable names, never values, and exits non-zero when systemd would
drop a line, quoting the line number.

## systemd unit

The unit is shipped with the repository as a template
(`deploy/prism-hubot.service`) and installed by `deploy/install-service.sh`. Run
it once on the VPS, as root, from a checkout of this repository, before the
first deployment:

```bash
sudo DEPLOY_PATH=/opt/prism-hubot DEPLOY_USER=deploy ./deploy/install-service.sh
```

The script substitutes the deployment path, service user, `bundle` path, bind
address and port into the unit, writes it to
`/etc/systemd/system/prism-hubot.service`, writes a `sudoers` drop-in that lets
the deploy user restart that unit without a password or TTY, reloads systemd and
enables the unit. It deliberately does not start it: the unit needs
`$DEPLOY_PATH/current`, which the first `Deploy` run creates. Re-running the
script is safe.

Overridable environment variables: `DEPLOY_PATH` (`/opt/prism-hubot`),
`DEPLOY_USER` (`deploy`), `BIND_ADDRESS` (`127.0.0.1`), `PORT` (`9292`),
`BUNDLE_BIN` (resolved from the deploy user's `PATH`), `UNIT_NAME`
(`prism-hubot.service`) and `INSTALL_SUDOERS` (`yes`).

`WorkingDirectory` points at the `current` symlink, so a restart after a deploy
picks up the new release. Terminate TLS in front of the process and forward
Telegram webhook requests to `/telegram/webhook`; `/healthz` stays internal.

If the service is managed some other way — a user unit, a container, a different
unit name — leave this script alone and set the `DEPLOY_RESTART_COMMAND`
repository variable instead. The workflow checks before uploading anything: with
no `DEPLOY_RESTART_COMMAND` set, it requires `prism-hubot.service` to exist on
the host and fails with installation instructions when it does not.

## Telegram command menu

The in-app command list (the `/` menu in Telegram clients) is server-side state
owned by the bot token, not by the running process: a bot that never calls
`setMyCommands` shows an empty menu no matter how many commands it routes.
`lib/prism_hubot/command_menu.rb` is the single source of truth for that list,
and `/help` is rendered from the same entries, so the menu and the help text
cannot drift. A test asserts the menu covers exactly the routed commands.

`infra` runs the contracted post-activation hook (`bundle exec rake telegram:commands`) after the new release is active. The task reads
the token from `.env` in the working directory, which in a release is the symlink
to `shared/.env`; `PRISM_HUBOT_ENV_FILE` overrides the path, and variables
already exported into the process win over the file. To do it by hand:

```bash
cd /opt/prism-hubot/current
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
cd /opt/prism-hubot/current
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
