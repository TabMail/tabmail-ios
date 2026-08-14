# IOS-AI-005

- Register classification: `open`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-12)** — an AI result that WAS computed can be **silently discarded** before it
reaches the inbox row, when the message's header id is invalidated by a **sync-path UID remap** inside
`flushAIBatch`'s 300 ms throttle window. The row then shows stale AI state until the next full
`reloadMessages`. Registered rather than fixed: AI output is derived and recomputable, and the reload
re-composes the row from the database.

## Subsystem and search terms

`InboxViewModel.flushAIBatch`; `pendingAIBatch`; `scheduleAIFlushTick`; `startAIUpdateListener`;
throttle not debounce; `applyHeaderRekeys`; `.messageHeadersRekeyed`; `publishMoveFinish`;
`AccountManagerQueue`; UID remap; `[Sync] UID remap`; `SyncEngineFullSync`; `freshHeaders`;
`loadedMessages.firstIndex`; silent `continue`; stale action tag; `reloadMessages`; `MessageRowView`;
spinner; `IOS-AI-004` sibling; THE ADDRESS PROBLEM

## Full detail

**The mechanism, verified in the tree.** `flushAIBatch` resolves each pending id twice and drops on
either miss, with **no log and no re-arm**:

```swift
guard let idx = loadedMessages.firstIndex(where: { $0.id == messageId }),
      let header = freshHeaders[messageId] else { continue }
```

`pendingAIBatch` *is* re-keyed — `InboxViewModel.applyHeaderRekeys` updates it alongside `loadedIds`
and the snippet queues. But that handler is driven by `.messageHeadersRekeyed`, and **that notification
is posted from exactly ONE place in the tree: `AccountManagerQueue`'s `publishMoveFinish`, the
`COPYUID` drain path.** The **sync-path UID remap posts nothing.** So when a move's identity is
resolved by the sync remap rather than by the drain, `pendingAIBatch` keeps an id that no longer
matches any row, both guards miss, and the entry is dropped without a trace.

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

## Why registered rather than fixed

The state converges: `reloadMessages` re-composes every row from the database, and the AI output itself
is **derived, recomputable content** — not authored user data, not a queued user intention. So this is
outside THE MANTRA's blocking set on every axis: no dropped intention, no starving operation, no
wrong-message mutation, no brick, no secret exposure. Per the owner's 2026-08-12 ruling, a non-minimal
fix belongs in the register for a later session.

## The two candidate fixes, recorded so they are not re-derived

1. **Post `.messageHeadersRekeyed` from the sync-path remap too**, so `applyHeaderRekeys` re-keys
   `pendingAIBatch` on both paths. This is the structural fix and it also repairs `loadedIds` and the
   snippet queues for the same case. ⚠️ Check every existing observer before widening the poster — the
   notification currently carries drain-path semantics, and a second poster is exactly the
   "single-writer column is a guard" shape that has bitten this codebase before.
2. **Make the drop observable** — a debug-gated log on each `continue` arm, naming which of the two
   resolutions missed. This is the cheaper change and it is a **precondition for ever confirming
   occurrence**, since the gate is currently unobservable. A warn-only path that nothing can see is
   the failure mode this register has recorded before.

Do the second before claiming anything further about the first.

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
