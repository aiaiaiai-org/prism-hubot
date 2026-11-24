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

No command, collection, delivery, or admin flow is activated by this PR.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
