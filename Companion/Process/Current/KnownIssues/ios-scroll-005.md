# IOS-SCROLL-005

> Routed from `KNOWN_ISSUES.md` line 1134 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `b8b5de934ff141e6d4a6aa3444dee0db73e4cfc8bf82f05e5b933960a374c7ab`

## Status

✅ **CLOSED AS A DECISION (2026-08-06, round-14 F10a)** — the inbox keyset cursor's primary key in triage mode is `tagSortOrder`, and `InboxViewModel.applyManualTag` writes the new `actionTag` onto the on-screen snapshot **without** mirroring `tagSortOrder`, so for the window between the durable commit and the reload the cursor can name a bucket the database row no longer occupies; mirroring it at the gesture is the **mirror image** and is deliberately not done

## Subsystem and search terms

Inbox; pagination; keyset cursor; stale snapshot value; `InboxViewModel.applyManualTag`; `loadedMessages`; `MessageSnapshot.tagSortOrder`; `InboxOrdering.areInIncreasingOrder`; `loadedMessages.max`; `InboxPageCursor(row:)`; `AccountManagerAI.applyManualTag`; `MessageHeader.setActionTag`; `.inboxDataDidChange`; `reloadMessages` Pass 1; `hasMoreMessages`; short page; triage mode; `excludeIds` after `LIMIT`; `IOS-SCROLL-002` sibling; `IOS-SCROLL-004` sibling; `MIS-026`

## Full detail

**What is there.** `InboxViewModel.applyManualTag` (the context-menu tag gesture) does `loadedMessages[idx].actionTag = tag` and nothing else; the durable writer `AccountManagerAI.applyManualTag` calls `MessageHeader.setActionTag`, which sets `tagSortOrder = tag?.sortOrder ?? 99` as well. Since round 13 the pagination cursor is `loadedMessages.max` under `InboxOrdering` fed into `InboxPageCursor(row:)`, which reads `tagSortOrder` — so a snapshot whose `tagSortOrder` disagrees with its row produces a cursor in the wrong bucket. In **triage** mode that costs at most one short page: the re-tagged row is re-admitted by the keyset predicate, burns a SQL `LIMIT` slot and is dropped afterwards by `excludeIds`, and `hasMoreMessages = nextPage.count >= SyncConfig.inboxPageSize` can therefore read false with mail still unfetched. `.normal` mode is unaffected — neither its comparator nor its SQL predicate reads `tagSortOrder`.

**The window is bounded on both ends, and the currently-held side is the SHORTER one.** Before the durable write the snapshot key and the durable key AGREE (both still carry the old bucket), so the cursor is correct. They disagree only from `AccountManagerAI.applyManualTag`'s `dbPool.write` commit until the reload that the same function posts one line later.

**Counterfactual discharged — the obvious repair is worse (`MIS-026`).** Mirroring `tagSortOrder` at the gesture would put the snapshot AHEAD of the database for the ENTIRE pre-commit window, which is strictly longer (it spans `ensureDurable`, an account read, the self-sent guard and the write) and wrong in the more damaging direction: a cursor DEEPER than the true position skips rows outright instead of re-admitting one. Stale-behind costs a duplicate that `excludeIds` removes; stale-ahead costs mail that is never fetched.

**Self-heal, with no user gesture.** The durable write posts `.inboxDataDidChange` itself; `reloadMessages` Pass 1 assigns the fresh row (`loadedMessages[i] = assigned`, carrying the reader's `tagSortOrder`) whenever it differs, and its last statement recomputes `hasMoreMessages = loadedMessages.count >= targetWindowSize`. So the false `false` is cleared by the very notification the write that caused it emits.

**Why it is registered and not fixed.** THE MANTRA's test is recoverability, and this recovers without any user gesture at all. Shipped `v1.6.38` could not reach it — its cursor read only `date`, which never changes for a row — so this is a residual of `3b31fdb4d` putting a MUTABLE field into the ordering key, the same root cause `IOS-SCROLL-004`'s round-13 U14 section records and repairs at the cursor. `IOS-SCROLL-002` registers *stale ordering of fresh values*; this is the other half, *stale values in a correct ordering*, and is recorded as its own row so neither cell has to carry both.
