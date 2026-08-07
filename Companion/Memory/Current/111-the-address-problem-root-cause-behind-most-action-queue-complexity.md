# THE ADDRESS PROBLEM — the root cause behind most action-queue complexity

**Status: SUPERSEDED / HISTORICAL as of v1.7.0 (2026-08-07). The problem described below is FIXED.**
**`CLAUDE.md` now wins over this file — the precedence stated in the original header is REVERSED.**

Routed out of `CLAUDE.md` (working tree, 2026-08-05 companion-compact pass), source lines 115–149,
byte-for-byte — nothing below is reworded, merged, or truncated. It is kept because the reasoning is
still the best account of *why* the design landed where it did, and because compaction never deletes
superseded material. **Do not read it as live state.**

What changed, and where to verify it in the tree (cited by SYMBOL — line citations go stale):

- *"The destination address is never persisted anywhere"* — **no longer true.**
  `IMAPProvider.copyProvenSourceUIDs` now returns `destinationProviderId` /
  `destinationUidValidity`, and `MessageHeaderRekey.finishMove` re-keys the row to the destination
  UID and epoch at drain time from the `COPYUID` already in hand. This is exactly the "finish the
  move locally" answer the last paragraph below argues for; it was implemented.
- *"Undo … cannot name the message in its new folder, so it refuses"* / *"Nothing replaced it"* —
  **no longer true.** `AccountManager.undoMove` performs an ordinary reverse move against the
  recorded durable identity.
- The banned D4 direction — an RFC 822 Message-ID `SEARCH` selecting a **mutation** target
  (ADR-IOS-068, `IOS-IMAP-002`) — is gone from the tree. The two surviving `searchByMessageId`
  callers (`currentUIDs`, `appendToSentFolder`) are both **non-mutating**.

**What survives as a live invariant** (and is stated in `CLAUDE.md`, which is normative): a move
changes the address, so anything recorded against the source *after* a move has landed either can
never be admitted again (a dropped intention) or names whatever now occupies that UID (**C3**).
A composed read-then-move therefore records the read strictly before the move, in the same queued
closure.

---

## THE ADDRESS PROBLEM — the root cause behind most action-queue complexity

**Read this whenever a task touches the action queue, moves, undo, or IMAP identity. Most designs that
spiral in this area are reconstructing an address the system was already told and discarded.**

**The fact:** a `PendingOperation` names its members by their address in the **source** folder, and on
IMAP an address is `(folder, UID, UIDVALIDITY)`. **A move changes that address.** The server hands us
the new one in the `COPYUID` response — and `copyProvenSourceUIDs` reads `pair.destination.value` only
to validate it, then returns **source** UIDs. The destination address is never persisted anywhere.

**Everything downstream is a symptom of that one absence:**
- Undo of an already-drained move cannot name the message in its new folder, so it refuses.
- A later gesture on that message addresses the `\Deleted` source residue instead of the destination
  copy, so the user's flag/read lands on the copy they cannot see.
- Sync has to repair the row afterwards on **weaker** evidence (RFC 822 matching in
  `canonicalizeLocalRows` / the UID-remap path) than the wire already proved.

**Undo is JUST A REVERSE MOVE. It was never a rollback.** That design has not changed. Undo *before*
the drain already works — the annihilate branch deletes the queued op. Undo *after* the drain needs to
name the message, and that is the only gap. Shipped `v1.6.38` named it by RFC 822 Message-ID `SEARCH`;
that mechanism is banned (ADR-IOS-068/D4) and registered as `IOS-IMAP-002` — it returned every copy
sharing the Message-ID and mutated all of them. Nothing replaced it.

**So: before designing a receipt, an alias table, a two-door identity scheme or an outcome enum, ask
whether the answer is simply to finish the move locally** — re-key the row to the destination UID and
epoch at drain time, using the `COPYUID` already in hand. Sync performs that identical re-key later on
weaker evidence, so doing it earlier is **reuse, not new machinery**.

**The failure mode this section exists to prevent:** four consecutive audit rounds argued about *which
evidence authorizes retiring an operation* when the real defect was decision **granularity**
(per-operation where per-member belonged), and several designs were drafted to *reconstruct* an address
that was available on the wire all along.

---

