# 114 — Both UIDVALIDITY re-drive owners iterated `syncableFolders`, so a custom non-favourite folder had NO re-drive at all

**Discovered 2026-08-07**, while designing the v1.7.1 one-shot epoch rebuild. Complement to
[112 — `uidValidityResetPendingAt` stays armed on purpose](112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md):
112 records that every abort leg leaves the flag SET so the folder is retryable. This records the
premise 112 silently depends on — **that some owner re-drives it** — and the folder class for which
that premise was false.

## The fact

Before v1.7.1 there were exactly **two** re-drive owners for `Folder.uidValidityResetPendingAt`:

- `SyncEngine.fullSync`'s per-folder loop, and
- `SyncEngine.imapDeltaSync`'s per-folder loop.

**Both iterate the SAME `syncableFolders` predicate:** `primaryRoles ∪ secondaryRoles ∪ isFavorite`,
plus `!path.isEmpty`. A **custom, non-favourited** folder is in neither set. `fullSync`'s own comment
says so outright — *"Custom non-favorited folders sync on-demand when the user navigates to them."*
— and `SyncEngineDeltaSync`'s round-8 note names the class by name.

Every other consumer of the flag REFUSES rather than re-drives, which is correct in isolation and
fatal in combination:

- `SyncEngine.runSyncMessages` — the in-transaction quarantine term returns an empty merge result;
- `SyncEngine.isFolderWalkComplete` — `guard folder.uidValidityResetPendingAt == nil else { return false }`;
- `AccountManager.drainPendingQueue` — parks the folder's durable ops;
- `AccountManagerActions` — refuses new gestures;
- `ActiveAIQueue` arm 5, `MessageContentStore`, `NSEDataBridge` — all treat it as identity-unstable.

So an armed custom non-favourite folder was **quarantined forever, with its mail already purged**:
nothing re-drove it, the merge pass skipped it, and the crawl refused it. That state was reachable
before v1.7.1 — `verifyAndBootstrapPrePopulatedFolderEpoch`'s `.handedToReaction` leg arms and then
runs the reaction immediately, and every abort leg of that run leaves the flag set.

## Why it mattered enough to change the design

The v1.7.1 fix for the 1.7.0 nil-epoch defect is to arm the reaction on every IMAP/iCloud folder. On
the reference device that corpus is:

| | folders | headers | folder epoch set |
|---|---|---|---|
| IMAP, `syncableFolders` | 15 | 25,347 | 15 |
| IMAP, **custom non-favourite** | **26** | **145,754 (85%)** | **0** |
| iCloud | 9 | 289 | 9 |
| gmail / outlook | 28 | — | 0 (correct — no UIDVALIDITY) |

The 26 are `Archive-2021` (48,856 rows), `Archive-2020` (14,578), … — the whole year-sharded archive.
Arming them without a third owner would have bricked 85% of the mailbox; scoping the migration to
`syncableFolders` instead would have repaired only 15%.

## The fix

`SyncEngine.syncFolderMessages` — the on-demand navigation door, whose only filter is
`!folder.path.isEmpty` — now branches into `runUidValidityResetReaction` for a quarantined folder and
returns, re-reading the flag rather than trusting the caller's `Folder` snapshot. It is the **third**
owner and the only one that reaches this folder class. No recursion: step 6's resync runs only after
step 5 cleared the flag, and the reaction is single-flight regardless.

## The generalizable lesson

**A durable retry flag is only as good as the enumeration of who re-drives it.** Both existing owners
looked like independent coverage — different files, different sync modes, different triggers — but
they shared one folder-selection predicate, so they failed over exactly the same set. When counting
re-drive owners, count the **predicates**, not the call sites. This is `MIS-007` (a census inherits
its search shape) applied to liveness rather than to safety: greping `runUidValidityResetReaction`
finds two callers and looks like redundancy; reading what each iterates finds one.

Related: [112](112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md),
`Folder.uidValidityResetPendingAt`'s own doc comment (which enumerates "two consumers" and does not
mention that both share a filter).
