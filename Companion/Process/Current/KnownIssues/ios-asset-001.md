# IOS-ASSET-001

> Routed from `KNOWN_ISSUES.md` line 1129 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `fixed`
- Original row SHA-256: `264c0d53034135984a3951b2d24d60ed928630749d8054ce1fa70e2d1073a44c`

## Status

✅ **FIXED (2026-08-06, round-12 T7)** — the drain-time re-key moved a message's header, FTS row and undo entry to its proven destination address but left its cached body assets at the old key, where the next orphan sweep deleted them

## Subsystem and search terms

Body assets; `BodyAssetStore.rekeyContentKey`; `deleteAllAssets(forContentKey:)`; `AccountManagerQueue.publishRekeys`; `MessageHeaderRekey.finishMove`; `BodyAssetMaintenance.pruneOrphans`; `MessageContentStore.recoverMovedContentKey`; `attachmentAssetId`; `tabmail-asset://`; `bodyCacheTTLHours`; collided re-key; content misattribution; `IOS-SEARCH-002` sibling

## Full detail

**What was wrong.** `publishRekeys` mirrored an applied re-key into exactly two non-GRDB stores — the undo stack and the FTS index. `MessageHeaderRekey.apply`'s doc called `bodyAsset` *deliberately out of scope … swept by its own headerId-prefix maintenance path*, and that was true at `v1.6.38` where the drain never re-keyed. It stopped being true when the drain began finishing moves locally: that sweep's only recovery leg, `MessageContentStore.recoverMovedContentKey`, is gated on Gmail-or-Outlook **and** matches on an **unchanged** `providerMessageId`, while `finishMove` re-keys precisely because the tail CHANGED — IMAP is excluded by the gate, Outlook passes the gate and misses the lookup. So after archiving or moving a message with cached inline images or attachments, the next `pruneOrphans` deleted the blobs while the carried-over `messageBody` row at the NEW key still referenced them.

**Why it was fixed rather than registered under THE MANTRA.** It self-heals at `SyncConfig.bodyCacheTTLHours`, so it passes the recoverability test — but it **regresses an ordinary primary path relative to `v1.6.38`** (archive a message you just read), which is a different test.

**What now holds.** `publishRekeys` mirrors into the manifest too, reusing the SAME `applied` / `collidedOldHeaderIds` split the FTS mirror uses: applied records take `rekeyContentKey(from:to:)`, collided old ids take `deleteAllAssets(forContentKey:)`.

**Counterfactual discharged — the collision split is load-bearing for a STRONGER reason here than for FTS.** Mirroring a collided re-key blindly would file two messages' attachments under one content key, and `attachmentAssetId(contentKey:section:identityStamp:)` looks up by `headerId`, so a later lookup could return the OTHER message's bytes — a content misattribution, C3-adjacent. Deleting the loser's cache costs a re-download.

**Verification.** Two new `ContentOwnershipSweepTests` beside the existing anchor, which was **extended and not replaced**: `drainTimeRekeyCarriesAssetsToTheNewAddress()` and `collidedRekeyNeverMergesAssetsOntoTheSurvivor()` (red pre-fix: the manifest still held the old key and the new key's attachment lookup returned nil). The pre-existing `movedMessagesAssetsAreRekeyed()` — the id-STABLE Gmail shape — stayed green throughout and is not a blessing test.
