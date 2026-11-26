# IOS-ASSET-003

- Register classification: `accepted`
- New post-freeze record (2026-11-24) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.
- Tracked by [ios#1410](https://github.com/TabMail/tabmail-ios/issues/1410) (P4).

## Status

📋 **ACCEPTED LIMITATION (2026-11-24, #1376).** Registered with the pending-delete list that replaced
the whole-store orphan sweep. The window is the one the sweep had; the list neither widens nor
narrows it. Sibling of IOS-ASSET-002 (the same move window seen by the scheme handler).

## The behaviour

1. **A move's re-key window.** When the action queue finishes a move, `MessageHeaderRekey.apply`
   deletes the message's old header row and inserts it under its new id in one transaction, and the
   v114 trigger queues the old id on `bodyAssetPendingDelete` in that transaction. The asset
   manifest (its own database) is re-keyed from the old id to the new one only after that commit,
   by `BodyAssetStore.rekeyContentKey(from:to:)` in `publishMoveFinish`
   (`AccountManagerOperationEffects`) and in `BackfillBodyQueue`'s `.migrated` path, after several
   other awaits. If the pending-delete worker reaches the old id inside that window, the old id
   names no header and the manifest still files the assets under it, so it deletes the moved
   message's cached inline images and attachments. A crash inside the window has the same result:
   the re-key never runs and the worker deletes them.
2. **The cross-database check.** The worker checks that a key names no header in the main
   database, then deletes its assets in the manifest database; the two are not one transaction
   (ADR-IOS-066 rule 3). If the key becomes a header again and new assets are published under it
   between the two steps, they are deleted the same way. The whole-store sweep had the same gap
   (it read the live keys, then deleted later).

## When it happens

Rare: the worker has to land in a window of well under a second after a move (or a key has to come
back to life inside one worker step), or the app has to stop inside the move window. The worker
runs only in the foreground maintenance pass.

## Recoverability

The deleted files are cached copies of server content; nothing is lost on the server and no other
message is affected.
- **Inline images.** The cached body stays, but its images name no manifest row, so the scheme
  handler refuses them (`noManifestRow`, which never triggers a refetch: asset ids are not secrets,
  ADR-IOS-076 decision 5). They come back when the cached body expires
  (`SyncConfig.bodyCacheTTLHours`) and is fetched again. Opening the message again does not bring
  them back sooner.
- **Attachments.** The attachment list finds no cached file and fetches it again when opened.

## Fix direction (not built)

Record the move's new id with the old one in the same transaction as the re-key, so the worker
re-keys the assets instead of deleting them, and the post-commit re-key calls can go. That would be
a second app-written record beside the trigger list, so it was not built with #1376.

## Subsystem and search terms

Body assets; pending delete; `bodyAssetPendingDelete`; `messageHeader_queueAssetDelete`;
`BodyAssetMaintenance`; pending-delete worker; `BodyAssetStore.rekeyContentKey`;
`MessageHeaderRekey.apply`; `publishMoveFinish`; `BackfillBodyQueue` `.migrated`; move window;
re-key race; cross-database check; missing inline images; `noManifestRow`; `bodyCacheTTLHours`;
IOS-ASSET-001; IOS-ASSET-002; ADR-IOS-066; ios#1410.
