# IOS-CATCHUP-002

- Register classification: `accepted`
- New post-freeze record (2026-11-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-13, #750).** Registered with the Outlook older-mail check
(ADR-IOS-107, ADR-IOS-111). The apply is shared, so the same holds for Gmail's and IMAP's checks:
this is Gmail parity, not an Outlook-only gap.

## The behaviour

The older-mail check proves a removal before it asks for one: the server says the message is gone
(404 or 410), or that it now lives in another folder. The apply
(`SyncEngine.applyCatchUpTransaction`, through `deleteConfirmedGhostHeaders`) still declines that
removal while the user's own action shields the message:

- a user operation on the message is still queued, or
- one completed less than `SyncConfig.recentlyCompletedTTLSeconds` (30 s) ago.

The rest of the result applies and the folder's catch-up state moves on, so the declined removal is
not tried again until the folder's next listing (see `IOS-CATCHUP-001` for what starts one).

## Recoverability

This usually heals at once: the user's own move or delete re-keys the row or removes it. When the
user's action leaves the row where it is, the row can stay visible until the next listing. An
example is a flag change on a message another client has just deleted.

- Opening the message removes it: the body fetch answers 404, and the row is deleted as confirmed
  gone.
- Nothing is lost: the declined step is a removal of a message the server no longer holds in this
  folder.

## Subsystem and search terms

Older-mail check; catch-up; Outlook; Gmail; IMAP; removal declined; shield; pending operation;
recently completed; `recentlyCompletedTTLSeconds`; `deleteConfirmedGhostHeaders`;
`applyCatchUpTransaction`; removal proof; ghost; not retried until the next listing; Gmail parity;
ADR-IOS-107; ADR-IOS-111; ADR-IOS-049; #750; IOS-CATCHUP-001
