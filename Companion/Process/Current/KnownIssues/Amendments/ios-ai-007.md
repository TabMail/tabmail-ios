# IOS-AI-007

- Register classification: `resolved`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-15) — proven members of a partial-success move now enter the same post-drain
AI event as a whole-operation success.**

## Reachability and failure

`retirePartiallyCompletedOp` is the standing path for any provider that proves a strict subset of a
bundled move. It re-keyed and retired `provenMembers`, preserved `remaining`, and scheduled the
destination sync, but never called `recordMembersThatEnteredInbox`. A proven RFC-bearing member moved
into an inbox therefore missed ADR-IOS-008 decision 3 solely because another member in its bundle
was unproven. Automatic repopulation remained a fallback, subject to the recent-window limit.

## Fix and invariant

After the narrowing transaction commits and its address handoff is published, the frozen
proven-member operation is passed to `recordMembersThatEnteredInbox` when it is a cross-folder move.
The call is inside the successful narrowing arm: an unproven member is never recorded, and a failed
narrowing that requeues the original bundle emits no false completion event.

`QueueCoreInvariantTests.narrowedRetirementCarriesTheDestinationAddressTheServerNamed` now moves a
partially proven member into INBOX and pins both system properties in one fixture: the row carries
the destination address the server proved, and exactly that proven member appears in the drain's
entered-inbox event while the unproven member remains queued.

The `IOS-AI-004` RFC-less resolution guard remains unchanged.
