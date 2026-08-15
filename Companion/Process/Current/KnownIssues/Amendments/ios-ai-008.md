# IOS-AI-008

- Register classification: `resolved`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-15) — post-drain sync prerequisites can no longer discard an already-recorded
entered-inbox event.**

## Reachability and failure

The destination-folder loop placed `enqueueAIForMembersThatEnteredInbox` after two `guard ... else
{ continue }` statements. If the account's `workQueue` was unavailable, or if its destination
`Folder` row could not be read, the loop skipped both sync and enqueue. The `DrainContext` was then
discarded, stranding its recorded `InboxEntry` values. This was RFC-independent and recovered only
through ordinary repopulation, subject to the recent-window limit.

## Fix and invariant

Queue and folder availability now govern only whether destination sync is attempted. For every
well-formed internal `accountId|folderPath` key, the entered-inbox enqueue runs after that optional
sync block and outside its error handler. The existing resolver still re-reads the current durable
row and fails closed if the recorded RFC identity cannot select it; no weaker identity rule was
introduced.

The proof is the production control-flow boundary itself: there is no `continue` between parsing a
valid internal key and `enqueueAIForMembersThatEnteredInbox`. Adding an asynchronous test seam solely
to simulate a missing actor-owned queue would add more machinery than this branch removes; the
resolver and enqueue-target invariants remain covered by `MoveIntoInboxAIEnqueueTests`.
