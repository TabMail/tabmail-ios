# MIS-IOS-003 — I designed machinery to reconstruct an address the server already told us

**Class:** design-process
**Severity:** high
**First seen:** 2026-07 · **Recurrences:** 6 · **Status:** Active
**Related:** [MIS-IOS-004](MIS-IOS-004-conflated-unknown-with-authoritative-stale.md), root `MIS-003` (see `../MISTAKES.md`) · **Rule owner:** `tabmail-ios/CLAUDE.md` § THE ADDRESS PROBLEM

## The tell

I am designing a receipt, an alias table, a two-door identity scheme, or an outcome enum so that a
moved message can be named in its new folder. The design is growing and every branch is about
*recovering* an identity.

**Second tell, added 2026-08-04 — the quieter one.** I am reading a provider's move call and the
response is bound to `_`. Nothing is growing, nothing looks like identity machinery, and that is
exactly why nobody looks: **the mistake at its origin is a single discarded return value.** The
elaborate reconstruction machinery of instances 1–4 is what this grows into three subsystems later.

## Instance 6 (2026-09-05) — the id was applied to the header and NOT to the queue

The fix for instance 5 landed, and it was correct as far as it went: `ExchangeProvider` decodes the
new `id` and `MessageHeaderRekey.finishMove` re-keys the `MessageHeader` with it. **Two other holders
of the old address were never asked about.**

1. **Every `PendingOperation` already queued that named the moved message.** `PendingOperation.messageIds`
   is a second table storing the same address, and nothing rewrote it. So the header knew where the
   message went and the user's next queued gesture did not — it reached the wire naming the id the
   move had just destroyed, Graph answered `404`, and the single-message conflict arm deleted the
   operation. The `IOS-QUEUE-008` amendment states this outright — *"nothing rewrites a later
   `PendingOperation.messageIds`"* — and used it as the reason Outlook could not be put on
   account-qualified drain lanes, i.e. the gap was WRITTEN DOWN as a constraint and read for a day as
   a property of the world rather than as this mistake, one table over.
2. **The header row itself, once it was no longer where the operation put it.** The re-key fetched by
   primary key at `op.destinationPath`, so an undo that had already moved the row back declined the
   re-key and the row kept a dead id. The wire's answer was in hand and was discarded because the
   LOOKUP, not the address, was wrong.

**The quiet form again, and the axis is the same failure as last time.** Instance 5 outlived the IMAP
fix because the enumeration axis was the mechanism (`COPYUID`) rather than the property. Instance 6
outlived the Graph fix because the axis was the **table** (`messageHeader`) rather than the property:
*who is holding the address the wire just invalidated?* The answer was never one row. A grep for
`finishMove` finds the header; nothing about the shape of that name suggests asking the queue.

**The generalisation worth keeping.** When a wire response invalidates an address, enumerate the
HOLDERS of that address before declaring the fix complete — every table, every in-flight capture,
every snapshot a later write will save back. Two of the changes in `IOS-GRAPH-005` are only about
holders: the requeue sites that wrote a whole captured struct back (`PendingOperation.markQueued`
now writes columns), and the lane loop that executed a captured struct (it now re-reads by primary
key). Neither is a new mechanism; both are the same question asked of a value that was already stale
in memory.

Fixed in `IOS-GRAPH-005` / ADR-IOS-081 (GitHub `#114`): the re-addressing happens inside the same
transaction that retires the move, so the header and the queue can never disagree about where the
message went.

## Instance 5 (2026-08-04) — the same discard, in the Graph id space, failing OPEN

`ExchangeProvider.moveMessage` is `let _ = try await request(path: "/messages/\(encodedId)/move", …)`.
Microsoft Graph's `/move` returns the moved message **with its new `id`**, and it is bound to `_` —
byte-for-byte the mistake `COPYUID`'s destination half made in the IMAP arm, which `59423bb7d` fixed.
No `Prefer: IdType="ImmutableId"` exists anywhere in the tree (zero hits), so Graph ids churn on
every folder move by design, and nothing re-learns them: `EmailProvider.move` returns `Void`, the
non-IMAP arm of `executeOperation` returns `provenDestinations: []`, and `canonicalizeLocalRows`
matches on `messageId == messageId && folderId == folderId`, so a churned id is unmatchable by
construction.

**Why it outlived the IMAP fix:** the enumeration axis was the MECHANISM named in the finding
(`COPYUID`) rather than the property that makes a site wrong (*a move changes the address and we
discarded what the wire told us*). A `COPYUID` grep cannot reach Graph. Recorded on the review side
as root `MIS-006` instance 5.

**Why it is worse here than in IMAP:** the IMAP admission arm refuses a row whose
`observedUidValidity` the optimistic move nil'd, so a dead address never reaches the wire — the
defect is real but fails **CLOSED**. The non-IMAP arm has no epoch gate
(`messages.filter { !$0.messageId.isEmpty }`, `nil` epoch), so the dead id is admitted and the
resulting 404 is read as authoritative. Same root cause, opposite failure direction, registered
**BLOCKING** as `IOS-GRAPH-002`. **A second guard that makes this defect benign in one arm is not a
guard the other arm has** — and it is what let the class read as closed.

Gmail does **not** share the shape: `messages.modify` add/remove label never changes the resource id,
so a Gmail 404 genuinely means gone.

## What actually happened

A `PendingOperation` names its members by their address in the **source** folder, and on IMAP an
address is `(folder, UID, UIDVALIDITY)`. **A move changes that address.** The server hands us the new
one in the `COPYUID` response — and `copyProvenSourceUIDs` reads `pair.destination.value` only to
validate it, then returns **source** UIDs. The destination address is never persisted.

Everything downstream is a symptom of that one absence: undo of an already-drained move cannot name
the message; a later gesture addresses the `\Deleted` source residue instead of the destination copy,
so the user's flag/read lands on a copy they cannot see; and sync has to repair the row afterwards on
**weaker** evidence (RFC 822 matching) than the wire already proved.

**Four consecutive audit rounds** argued about *which evidence authorises retiring an operation* when
the real defect was decision **granularity** — per-operation where per-member belonged.

## Why it is not obvious

The information loss happened earlier, in a function that looks like it is doing validation. By the
time you reach the undo path, the address genuinely is gone, so reconstructing it is genuinely
necessary — for the code as written. The question nobody asks is why it was discarded.

## The rule

Before designing any identity-recovery mechanism, ask whether the answer is to **finish the move
locally** — re-key the row to the destination UID and epoch at drain time, using the `COPYUID`
already in hand.

## Mechanical check

```bash
rg -n 'copyProvenSourceUIDs|COPYUID|destination\.value' --type swift
```

**Undo is JUST A REVERSE MOVE — it was never a rollback.** Undo *before* the drain already works
(the annihilate branch deletes the queued op). Only undo *after* the drain needs to name the message.
Sync already performs that identical re-key later on weaker evidence, so doing it earlier is
**reuse, not new machinery**. The RFC 822 `SEARCH` mechanism shipped in `v1.6.38` is **banned**
(ADR-IOS-068/D4, registered `IOS-IMAP-002`) — it returned every copy sharing the Message-ID and
mutated all of them.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-003](Companion/Mistakes/Active/MIS-IOS-003-reconstructed-an-address-the-wire-already-gave-us.md)** — designed identity machinery to rebuild the destination address `COPYUID` already returned; 4 audit rounds argued evidence when the defect was granularity. Undo is JUST a reverse move. Instance 5: the **quiet** form of the same tell — not growing machinery but a **discarded return value**: `ExchangeProvider.moveMessage` binds Graph's `/move` response to `_` though it carries the new `id`, and no `Prefer: IdType="ImmutableId"` exists in the tree, so Graph ids churn on every move and are never re-learned. It outlived the IMAP fix because the census enumerated the MECHANISM (`COPYUID`) instead of the property (*a move changes the address and we discarded what the wire told us*), and because IMAP's epoch gate makes the same defect fail CLOSED there while the non-IMAP arm has no gate and fails OPEN → `IOS-GRAPH-002` (BLOCKING). Gmail is exempt: `messages.modify` never changes the resource id. **A second guard that makes a defect benign in one arm is not a guard the other arm has.** (×5)
```

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-003](Companion/Mistakes/Active/MIS-IOS-003-reconstructed-an-address-the-wire-already-gave-us.md)** — designed identity machinery to rebuild the destination address `COPYUID` already returned; 4 audit rounds argued evidence when the defect was granularity. Undo is JUST a reverse move. Instance 5 is the **quiet** form — a **discarded return value**: `ExchangeProvider.moveMessage` binds Graph's `/move` response to `_` though it carries the new `id`, and no `Prefer: IdType="ImmutableId"` exists in the tree (`IOS-GRAPH-002`, BLOCKING; Gmail exempt). **A second guard that makes a defect benign in one arm is not a guard the other arm has.** (×5)
```
