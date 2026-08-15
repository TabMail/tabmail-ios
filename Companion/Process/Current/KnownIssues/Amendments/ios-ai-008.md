# IOS-AI-008

- Register classification: `open`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — INTEGRATED FIX CANDIDATE (2026-08-15).** Post-drain sync
prerequisites can no longer discard an already-recorded entered-inbox event.

## Reachability and failure

The destination-folder loop placed `enqueueAIForMembersThatEnteredInbox` after two `guard ... else
{ continue }` statements. If the account's `workQueue` was unavailable, or if its destination
`Folder` row could not be read, the loop skipped both sync and enqueue. The `DrainContext` was then
discarded, stranding its recorded `InboxEntry` values. This was RFC-independent and recovered only
if the row happened to remain inside the configured automatic population; the recorded direct event
itself was process-local and could be lost.

## Fix and invariant

Queue and folder availability govern only whether destination sync is attempted. For every
well-formed internal `accountId|folderPath` key, the entered-inbox enqueue runs after that optional
sync block and outside its error handler. Independently, the move-retirement transaction has already
persisted `aiDirectPending`, so a missing queue/folder, cancellation, or relaunch cannot erase the
event. The existing immediate resolver still re-reads the current row and fails closed if RFC
identity cannot select it; no weaker identity rule was introduced.

The production control-flow boundary has no `continue` between parsing a valid internal key and
`enqueueAIForMembersThatEnteredInbox`; the durable marker is the crash/relaunch fallback rather than
a test-only queue seam. Resolver, wrong-message, marker, enqueue-target, and full-retirement rollback
invariants are covered by `MoveIntoInboxAIEnqueueTests`. The missing-queue/missing-folder arms remain
source-structural rather than being simulated through new production seams. `SyncConfig.maxRecentEmails`
is unchanged.
