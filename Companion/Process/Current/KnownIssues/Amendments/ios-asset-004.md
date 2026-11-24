# IOS-ASSET-004

- Register classification: `accepted`
- New post-freeze record (2026-11-24) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-24, #1376).** Harmless leftover: cached copies the user cannot see,
which do not grow with use. Registered rather than mechanised.

## The behaviour

The notification extension writes a pushed message's inline images under the message's STAGED
content key. The merge queues that key on `bodyAssetPendingDelete` wherever it lets a staging row go
(`NSEDataBridge.queueStagedAssetKey(s)`), so the pending-delete worker re-keys or deletes those
assets. Three cases leave the staged key unqueued, so its manifest rows and files stay:

1. **An extension killed between publishing a message's inline images and recording the
   message.** The staging row is still the placeholder (`populated = 0`), which carries no folder
   path, so the merge's reap of old placeholders cannot derive the key.
2. **The extension's own identity replacement** (IOS-NSE-005): `NSEStagingDB` deletes a staging row
   whose identity positively differs from a new push for the same id and inserts the new one; the
   replaced message's key is not queued. The extension cannot write the main database.
3. **A late extension run** (a process resumed minutes later) that renders a message again after
   the merge already let its staging row go, where the staged key never became a header (the
   message merged under another id, or was discarded).

The whole-store sweep this list replaced would have reclaimed these.

A fourth leftover, in the main app, has the same shape and is accepted with them:

4. **A process killed inside `BodyAssetStore.publish`, between the `rename` that moves a staged file
   into the store and the manifest COMMIT.** The rollback restores the write's lease row, which ages
   out, but no manifest row names the moved file. `recoverAbandonedPreparations` cleans only
   `staging/`, and the periodic whole-store prune no longer runs, so only `pruneOrphanFiles` (after a
   UIDVALIDITY purge) or the local index wipe removes it.

## When it happens

Rare: each needs the extension (or, for case 4, the app) to stop or resume at a narrow point, or a
second render of a message already merged.

## Recoverability

Nothing to recover: no message, body or attachment the user can reach is affected. The leftover is
the user's own cached copy of server content, never shown and not growing with use. "Nuke database"
and the image cache wipe in Settings remove it.

## Subsystem and search terms

Body assets; notification extension; NSE; staged content key; `NSEDataBridge.stagedContentKey`;
`queueStagedAssetKey`; `queueStagedAssetKeys`; orphan reap; `populated = 0`; placeholder;
IOS-NSE-005; `stagedIdentityPositivelyDiffers`; zombie resume; leftover assets; `publish`; `rename`;
killed before COMMIT; store file with no row; `recoverAbandonedPreparations`;
`bodyAssetPendingDelete`; IOS-ASSET-001; IOS-ASSET-003.
