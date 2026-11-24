# Whisper history domain

This slice is process-local and deliberately not wired to Telegram. An authenticated
administrator/disclosure flow must call enable; the verified webhook adapter must
filter ordinary text/captions, bot messages, commands, anonymous authors and surface
membership before calling observe. Opt-in is not persisted across restart: history
and consent start empty. One History instance belongs to one bot instance.

## Adapter contract for observe

- `timestamp` is the original message `date` in seconds, never `edit_date`. Messages
  older than the moment of `enable` are never eligible, including when edited later,
  so nothing sent before the disclosure is retained.
- `revision` must be strictly increasing per message. Use the `update_id` of the
  update that carries the edit (or 1 for the first observation), not `edit_date`: its
  one-second resolution would drop a second edit in the same second and leave stale
  text to be narrated.
- Text is limited to 4096 characters (Telegram's own limit) and author labels must be
  free of line breaks, control and invisible characters.

## Retention

The buffer limits each surface to 100 messages / 24 hours, caps enabled surfaces at
100 and rejects stale duplicates, deleted entries, invalid authors and out-of-order
edits. Retention is enforced on access; a periodic sweep is still needed for idle
surface expiry before runtime use. Deletion notifications are best-effort; there is
no arbitrary history retrieval. A bounded tombstone overflow disables the surface;
the refusal is then `disabled_overflow` (not `not_enabled`) until an administrator
enables it again, so integration must tell the administrator why it stopped.

## Selection

A snapshot contains IDs/revisions, actor and surface, expires in ten minutes,
and cannot include later arrivals. Edits, expiry, eviction, deletion or opt-out
invalidate affected snapshots. A filter resolves observed usernames to stable
author IDs; ambiguity refuses. Picker selection reads forward; reply count reads
backward. Narrated text (including author labels) is subject to the generation
budget: 4,000 characters, which fits the speech service's 300 second cap (about
14-17 characters per second; the `screen` preset is 2,000). No logging or
persistent storage. In-flight generation cancellation and delivery-time
revalidation remain integration requirements.

Single-narrator readback is literal: a message whose text imitates an author cue
(`Alice: ...`) is spoken like one, and a filtered union range skips unselected
messages in between. Integration should keep author cues distinguishable from message
text and may state that gaps exist.

## Activation and observation

`/whisper` and `/whisper_off` are declared `is_ephemeral` in the command menu (`rake telegram:commands`).
Only a chat administrator can switch Whisper on, and only when the bot is itself an administrator:
the check uses `getChatMember` for the person who pressed the button, at press time, and a lookup
Telegram does not confirm is a refusal. The consent step shows the disclosure privately, and on
confirmation the bot first posts a **public** notice in the same chat or topic that message texts are
being kept; if that notice cannot be posted, nothing is enabled. `/whisper_off` clears the history first
and then announces it, best effort. State is process-local: a restart disables every chat.

Ordinary group messages reach `History#observe` through a prism-bot observer: text or caption from
human members, never commands, never ephemeral commands or button presses. The first sighting of a
message is revision 1 and an edit carries the id of its own update. Display names become spoken
author labels with control and invisible characters removed, falling back to the username and then to
"Учасник". A message sent before enabling is never kept. A plain `/whisper` typed into a group is
public, so the bot answers only with a hint and no group content.

## Picker

Where Whisper is on, an ephemeral `/whisper` opens a private list of the kept messages, newest first,
five per page, each as `n. <age> · <author>: <snippet>` (a snippet is at most 40 characters, with
control and invisible characters removed and whitespace collapsed). Arguments: `@author` (several
allowed; the union of their messages), a number 1-50 (only that many newest messages), and `екран`
(the 20-message / 2000-character preset). Anything else is refused with the usage text; nothing is
guessed. Opening the list takes the fixed snapshot from `History#snapshot`.

The list belongs to the person who opened it: a process-local session keyed by chat, topic and
person (at most 200, expiring with the 10-minute snapshot) holds the snapshot references, never
text. Page, choose and cancel are `wp:p:<page>`, `wp:s:<message id>` and `wp:x` callbacks; the data
is untrusted and anything but exactly those shapes is ignored. Pages and the result edit the same
private message. Choosing a message checks the range with `History#select` (the chosen message and
every newer one in the filtered snapshot, at most 50 messages and 4,000 characters, never silently
cut) and records only the anchor. An edit, expiry, deletion or opt-out makes the list stale and the
person is asked to run `/whisper` again. The reply-count form (`/whisper 10` as a reply) is not
available yet, because prism-bot does not expose the replied-to message. Synthesis and delivery are
separate changes: the range is read from the history again and revalidated when it is synthesized.


<!-- © 2026 aiaiaiai · aiaiaiai.org -->
