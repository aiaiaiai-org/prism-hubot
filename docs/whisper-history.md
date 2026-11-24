# Whisper history domain

This slice is process-local and deliberately not wired to Telegram. An authenticated
administrator/disclosure flow must call enable; the verified webhook adapter must
filter ordinary text/captions, bot messages, commands, anonymous authors and surface
membership before calling observe. Opt-in is not persisted across restart: history
and consent start empty. One History instance belongs to one bot instance.

The buffer limits each surface to 100 messages / 24 hours, caps enabled surfaces at
100 and rejects stale duplicates, deleted entries, invalid authors and out-of-order
edits. Retention is enforced on access; a periodic sweep is still needed for idle
surface expiry before runtime use. Deletion notifications are best-effort; there is
no arbitrary history retrieval. A bounded tombstone overflow disables the surface.

A snapshot contains IDs/revisions, actor and surface, expires in ten minutes,
and cannot include later arrivals. Edits, expiry, eviction, deletion or opt-out
invalidate affected snapshots. A filter resolves observed usernames to stable
author IDs; ambiguity refuses. Picker selection reads forward; reply count reads
backward. Narrated text (including author labels) is subject to the generation
budget. No logging or persistent storage. In-flight generation cancellation and
delivery-time revalidation remain integration requirements.

No command, collection, delivery, or admin flow is activated by this PR.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
