# Every sync mechanism rides the existing pipe (owner 2026-11-23)

Owner, verbatim: "We basically have this provider abstraction and the dumb pipe for the sync, which is supposed to
just work for this workload. We exactly have the priorities set up for this." And, on the older-mail check: "this was
already well thought of and designed, so we should have this design note."

## The model: two layers

1. **The pipe, `ProviderWorkQueue` (one per account).** Every provider request goes through it, in three tiers:
   `.userAction` (the user is waiting), `.headerFetch` (every sync read: passes, listings, catch-up, walk) and
   `.bodyFetch` (bodies, attachments, search indexing, AI). A free slot goes to the highest tier waiting.
2. **The account turn, `oneSyncAtATime` (ADR-IOS-104).** One sync pass per account writes sync state at a time. A
   new-mail trigger (push, IDLE, poll, pull to refresh, return to the app) never waits: it sets the follow-up flag,
   and its read runs as soon as the running work ends.

## The rules

- **Build every sync mechanism from these two layers.** Add no scheduler, timer, queue, gate, turn or second path.
- **The new-mail paths stay narrow.** Never widen the poll, IDLE, push, pull or return passes to carry bulk work.
- **Bulk and background reads run in chunks in the existing catch-up runner** (`runCatchUpRun`). This covers older
  mail, first checks, folders nobody opens, and a folder's full check after a user action. The older-mail check is
  the model: a chunk takes the turn for one slice (2 s today, a capped number of requests), hands it on, and waits
  outside the turn before the next. New mail goes next, right after the running chunk, so it waits at most one
  chunk.
- **Low priority comes from chunking, not from the queue tier.** Sync reads use `.headerFetch`. Never use
  `.bodyFetch` for work that holds the turn. A chunk takes the turn first and then waits for a slot, so at the
  lowest tier it would hold the turn behind every queued download, and new mail would wait behind the downloads
  too.
- **Anything this cannot carry needs the owner's decision.** The design states why the pipe cannot carry it, and the
  owner decides before any code.

Related: [`sync-timing-promises.md`](../../../../Companion/Rules/Active/sync-timing-promises.md) (root), the design
block at the top of `SyncEngineOneSyncAtATime.swift`, ADR-IOS-009 (one gate), ADR-IOS-104 (one sync at a time).
