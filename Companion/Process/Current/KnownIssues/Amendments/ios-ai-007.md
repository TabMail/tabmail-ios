# IOS-AI-007

- Register classification: `open`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — INTEGRATED FIX CANDIDATE (2026-08-15).** Proven members
of a partial-success move enter the same durable direct-AI event as a whole-operation success.

## Reachability and failure

`retirePartiallyCompletedOp` is the standing path for any provider that proves a strict subset of a
bundled move. It re-keyed and retired `provenMembers`, preserved `remaining`, and scheduled the
destination sync, but never called `recordMembersThatEnteredInbox`. A proven RFC-bearing member moved
into an inbox therefore missed ADR-IOS-008 decision 3 solely because another member in its bundle
was unproven. The automatic newest-N population could not substitute for the missing direct event
when the row was older than that configured population.

## Fix and invariant

Inside the same transaction that re-keys proven members and narrows the queued operation, the
candidate marks only provider-proved rows that durably landed in Inbox. After commit, those same
entries are passed to `recordMembersThatEnteredInbox` for the immediate post-drain enqueue. An
unproven member is never marked or recorded, and a failed narrowing that requeues the original
bundle commits neither signal.

`QueueCoreInvariantTests.narrowedRetirementCarriesTheDestinationAddressTheServerNamed` moves a
partially proven member into INBOX and pins all three system properties in one fixture: the row
carries the destination address the server proved, its direct marker commits at that address, and
exactly that proven member appears in the drain event while the unproven member remains queued.
`narrowingMarkerFailureRollsBackTheWholeTransaction` aborts after the narrowed operation row is
updated and proves the preceding provider-address re-key, marker, and operation narrowing roll back
together, after which the original bundle is durably requeued by the pre-existing partial-success
recovery behavior.

The `IOS-AI-004` RFC-less resolution guard and `SyncConfig.maxRecentEmails` remain unchanged.
