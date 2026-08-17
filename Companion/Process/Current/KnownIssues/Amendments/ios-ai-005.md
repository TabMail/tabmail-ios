# IOS-AI-005

- Register classification: `resolved`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-16, PR #42, merge `848babdae`).** Successful UID-window sync remaps now ride
`SyncMessagesResult.headerRekeys`; both production result consumers synchronously post the existing
`.messageHeadersRekeyed` notification on `MainActor`, and `InboxViewModel` re-keys a still-pending
`pendingAIBatch` entry with the visible snapshot while the view receiver keeps presentation bindings
coherent. Weak sync correlation is excluded from optimistic dismissal/swipe authority, and date-window
providers retain their existing durable/FTS reload path. The two former silent `flushAIBatch` misses
emit distinct debug-gated diagnostics. Two independent exact-diff reviews were CLEAN on signed+DCO
head `d94a501433`; the owner accepted the narrow derived-repaint residual below and approved the merge.
GitHub issue #3 closes with this disposition.

**Authoritative primary validation.** The exact review-fix source tree passed **20/20** focused tests on
the iOS 26.5 simulator with zero failures, skips, or expected failures. In the combined focused run,
rekey publication covered 6/6 executable lines, `InboxViewModel.applyHeaderRekeys` covered 20/20, its
notification-delivery closure covered 7/7, the view-owned authority transition covered 20/20, and
`flushAIBatch` covered 83/100.
A separate simulator app build succeeded with zero structured warnings or errors; its raw build log
contained exactly two instances of the permitted App Intents metadata diagnostic and no other warning
or error tokens. The exact test build contained three instances of that same permitted diagnostic.
**Original open status (2026-08-12), retained as history.** An AI result that WAS computed can be
**silently discarded** before it reaches the inbox row when a sync-path UID remap lands inside
`flushAIBatch`'s 300 ms throttle window. The row then shows stale AI state until the next full
`reloadMessages`; AI output is derived and recomputable, and that reload re-composes it from GRDB.

## Subsystem and search terms

`InboxViewModel.flushAIBatch`; `pendingAIBatch`; `scheduleAIFlushTick`; `startAIUpdateListener`;
throttle not debounce; `applyHeaderRekeys`; `.messageHeadersRekeyed`; `publishMoveFinish`;
`AccountManagerQueue`; UID remap; `[Sync] UID remap`; `SyncEngineFullSync`; `freshHeaders`;
`loadedMessages.firstIndex`; silent `continue`; stale action tag; `reloadMessages`; `MessageRowView`;
spinner; `IOS-AI-004` sibling; THE ADDRESS PROBLEM

## Full detail

**The original mechanism, verified in the pre-candidate tree.** `flushAIBatch` resolves each pending id twice and drops on
either miss, with **no log and no re-arm**:

```swift
guard let idx = loadedMessages.firstIndex(where: { $0.id == messageId }),
      let header = freshHeaders[messageId] else { continue }
```

`pendingAIBatch` *was* already re-keyed — `InboxViewModel.applyHeaderRekeys` updated it alongside
`loadedIds` and the snippet queues. But that handler was driven by `.messageHeadersRekeyed`, and in
the pre-candidate tree **that notification was posted from exactly ONE place:
`AccountManagerQueue`'s `publishMoveFinish`, the
`COPYUID` drain path.** The **sync-path UID remap posted nothing.** So when a move's identity was
resolved by the sync remap rather than by the drain, `pendingAIBatch` kept an id that no longer
matched any row, both guards missed, and the entry was dropped without a trace.

**Why the two paths diverge.** `publishMoveFinish` fires only when the wire named a destination
address (`COPYUID`). When it does not — no UIDPLUS, a withheld response code, or a timed-out first
attempt that later retries — the identity is instead reconciled by the sync's UID-remap healer. That
path is common, not exotic: both observable episodes in the 2026-08-12 device capture took it, one of
them after the first move attempt timed out.

**The drop is unobservable by design.** Neither `continue` logs. There is no counter, no warning, and
no re-arm, so the only symptom is a row whose AI state is stale — which is indistinguishable, to a
user and to a reader of the logs, from AI simply not having run yet.

⚠️ **This record does NOT claim the drop was observed.** In the device capture the AI write and the UID
remap fall inside the same ~1.3 s interval with a 300 ms throttle between them, and **the log cannot
resolve which side of the flush the remap landed on.** The mechanism is established from the code; the
occurrence is not established from the evidence. Do not upgrade this to "confirmed in the field"
without a capture that distinguishes the ordering — which requires instrumentation that does not
currently exist (see below).

## Disposition

The state converges: `reloadMessages` re-composes every row from the database, and the AI output itself
is **derived, recomputable content** — not authored user data, not a queued user intention. So this is
outside THE MANTRA's blocking set on every axis: no dropped intention, no starving operation, no
wrong-message mutation, no brick, no secret exposure. The merged notification-based repair is bounded
and proportionate; the rare accepted residual below does not justify a second identity subsystem.

## The two merged fixes

1. **Post `.messageHeadersRekeyed` from the sync-path remap too**, so `applyHeaderRekeys` re-keys
   a still-pending `pendingAIBatch` entry on both paths. This also repairs `loadedIds` and the snippet
   queues for the same case. ⚠️ Check every existing observer before widening the poster — the
   notification historically carried drain-path semantics, and a second poster is exactly the
   "single-writer column is a guard" shape that has bitten this codebase before. **Merged result:**
   the census found two observers (`InboxViewModel` for model state and `HeaderRekeyReceiver` for view
   bindings) and two production sync-result consumers; both consumers call one shared publisher. Only
   exact successful remaps from UID-window providers ride the new carrier. RFC corroboration is not
   widened into provider-address authority: `newObservedUidValidity` remains nil, the record is marked
   non-authoritative for optimistic action state, and no process-local address handoff is published.
2. **Make the drop observable** — a debug-gated log on each `continue` arm, naming which of the two
   resolutions missed. This is the cheaper change and it is a **precondition for ever confirming
   occurrence**, since the gate is currently unobservable. A warn-only path that nothing can see is
   the failure mode this register has recorded before. **Merged result:** the combined guard is split
   into loaded-snapshot and durable-header misses, each with a debug-gated `[AIBatchTrace]` reason.

The merged fix satisfies the observability prerequisite; it still makes no claim that the historical
device episode crossed the drop ordering.

**Accepted narrow residual (owner ruling, 2026-08-16).** If a batch has already copied and cleared
`pendingAIBatch` and is suspended in its GRDB read when the remap arrives, that local old-id copy cannot
be rewritten and the targeted repaint may still miss. An older in-flight reload can likewise repaint
once from a pre-remap snapshot. Both affect derived, persisted AI presentation only and converge on a
later reload/recompute; the owner explicitly rejected a second alias/generation system for these rare
windows as disproportionate to the impact.

## Performance and fallback audit

The merged fix adds no database query, schema, migration, index, retry, durable alias, or SwiftMail
change. Inside the existing bounded sync transaction it appends one value per successful UID remap;
publication occurs after commit and before slower FTS work. Inbox-owned `performSync()` already awaits
sync and then reloads, so that route self-heals immediately. The reachable gap is the foreground or
background scheduler's full-sync route, which can re-key behind a live inbox without that reload.
Relaunch, foreground reload, and later list reload remain convergence fallbacks, not protection for the
pending 300 ms update. Shipped `v1.6.38` contains the same double-guard drop and sync rekey without a
notification; its move-drain rekey receiver did not yet exist.

## What the row spinner does and does NOT tell you

Recorded here because it misled the investigation. `MessageRowView`'s spinner is
`message.isInInbox && anyAISourceEnabled` with no action tag yet — a **derived** indicator with **no
connection to any queue, job, or pending flag.** A visible spinner does **not** mean work is queued or
in flight, and its absence does not mean work completed. Any future diagnosis of "AI seems stuck" must
not treat it as queue state.

⚠️ **One reported state remains unexplained:** a row observed with **neither** a spinner **nor** an
action tag. The code makes `isInInbox && no tag` produce a spinner unconditionally, so that observation
requires either `isInInbox == false` in that row's snapshot or all AI sources disabled — and the log
records neither field per row. The leading benign reading is that the observer was looking at a
different row after a scroll movement, since a moved message sorts by date and lands mid-list rather
than at the end. Settling it needs the per-row instrumentation named above.

## Related

- `IOS-AI-004` — the *separate* gap where AI is never enqueued at all for a local move.
- `IOS-MOVE-002` — the same drain-versus-sync identity divergence, from the address side.
- THE ADDRESS PROBLEM (`Companion/Memory/Current/111`) — why a move changes the id that keys this.
