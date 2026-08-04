## ADR-IOS-072: Content Is Addressed by the Message It Belongs To, Never by the Slot It Occupies

**Date:** 2026-08-02

**Status:** Active. The port of the unreleased ADR-IOS-066 **as new work** — the base does not have
this property.

**Context.** `headerId` is a **mutable address**, not an identity. On the base, both the FTS index
and the body-asset cache key by it **with no identity check at all**. When a UIDVALIDITY turnover
renumbers a mailbox, the new occupant of UID 42 gets a byte-identical `headerId` — so the previous
occupant's indexed subject, sender, body and embedding answer searches for a message that is not
there. `indexHeaders` uses `INSERT OR IGNORE` with a skip-if-present arm, so a stale record can
**never** be corrected: search returns the NEW message carrying the OLD message's subject and
sender, permanently.

This is the content-side counterpart of ADR-IOS-068. Actions key by provider id because that
distinguishes two copies; content keys by RFC because two copies *are* the same content. **Two
keying schemes on purpose** — see ADR-IOS-068 §7.

**Decision.**

1. **A content record carries an identity stamp for the message it belongs to**, and a write that
   disagrees with the stored stamp is resolved by an explicit disposition — adopt-and-clear,
   adopt-and-preserve, or refuse-older-generation — rather than by silently skipping or silently
   overwriting.

2. > ### ⚠ THE PRESERVE RULE — owner-mandated, quoted verbatim; do not paraphrase it
   >
   > **a NULL identity stamp means RE-FETCH, NEVER DESTROY — only a positive mismatch clears anything**
   >
   > *(Deliberately on ONE line, unwrapped, so `rg 'a NULL identity stamp means RE-FETCH, NEVER DESTROY — only a positive mismatch clears anything'` finds it here, in the implementation item, and in the red proof. Do not re-wrap it.)*

   Concretely: an unversioned record, a NULL stored identity, and a fall-through all resolve to
   **preserve-and-adopt**. Clearing is permitted **only** when *both* sides are non-nil *and*
   differ — both RFCs present and different, or both epochs present and different. A missing stamp
   is missing evidence, and missing evidence is never a licence to delete user content.

   **Why this sentence is quoted rather than restated.** The reference guarded this **write** with a
   **read** rule and thereby **unrecoverably wiped the FTS body of every pre-upgrade row** — every
   such row had a NULL stamp, the read rule read NULL as "does not match", and the guard deleted
   what it existed to protect. The rule appears in the implementation item, in this ADR, and in a
   dedicated red proof, in the same words, on purpose.

3. **A purge must fail closed when two folder relations disagree.** Orphaned search ids left by an
   earlier partially-failed purge are swept **narrowly**, only where no surviving metadata row
   claims that rowid. The reference's unconditional delete produces the **mirror image** of the bug
   it fixes: `message_meta.folderId` can legitimately disagree with the content key — a legacy row
   awaiting a folder-id backfill, or the two-await window between a rekey and its folder-id
   update — and deleting the id alone there strands a searchable metadata row with no id, which the
   next index of that key turns into a second rowid whose stale twin keeps answering searches.

4. **On a rekey collision, the richer entry wins.** Body presence, then vector presence, then body
   length. A skeletal header-only row may not replace one that already carries an indexed body and
   embedding. **The self-rekey guard shipped alongside it is load-bearing, not cosmetic**: without
   it the richness compare evaluates a row against itself, finds neither side richer, takes the else
   arm, and deletes that entry's body, metadata and embedding outright.

5. **Body-asset writes hold a two-phase lease.** `prepare` → `publish`, with discard-on-failure. The
   lease INSERT precedes any filesystem touch, so the protected window strictly **contains** the
   whole materialisation window, and **every** physical deleter routes through the lease-aware
   helpers — a lease nothing consults protects nothing. Two disjoint notions of "in use" are guarded
   independently: a published row alone refuses the unlink, and a live lease alone refuses it.
   Expiring a lease removes only the lease-side protection and can never remove the row-side one.
   A writer that outlives its lease **fails CLOSED rather than losing data**: `publish` re-proves
   lease ownership before touching the manifest, so an expired writer records **nothing** — no row
   is ever created pointing at unlinked bytes, no `hasBody` flip happens off a nil, and the caller
   re-fetches. *"Never mark unfetched content as fetched"* holds by construction.

6. **Unreadable user content fails closed and stays visible.** An attachment load that cannot read a
   file **throws**; compose surfaces the error, disables Send and does not dismiss; the send path
   marks the message failed rather than sending a subset. Draft eviction consults an open-editor
   registry and orders by a strictly increasing per-save counter (migration `v79`) rather than by a
   wall clock, so a backward clock can no longer make a just-saved draft the victim.

**Rationale.** Addressing content by a slot is correct exactly until the slot is reused, and the one
event this app must survive — a UIDVALIDITY turnover — reuses every slot at once. Keying by the
message the content belongs to makes the stale-record case *expressible*, which is the precondition
for handling it at all. The preserve rule exists because the obvious implementation of that guard
destroys data on the very first upgrade, and it did.

**Consequences.**

- A NULL-stamped pre-upgrade row **keeps its body** and is re-fetched, not wiped. This is the single
  most important observable property of this record and has its own red proof.
- `prepare` always re-materialises, because v3 keeps `blobId == the published row's id` and the
  address therefore does not name the content. The reference's content-addressed `blobId` /
  `logicalId` / `contentDigest` scheme was deliberately **subtracted**: it is inseparable from the
  same commit's message-identity work, and porting its addressing half alone is the
  half-port-that-drops-the-guard shape. Keeping the existing address also preserves the
  `tabmail-asset://` URLs already baked into cached HTML.
- An unknown or purged header directory is no longer removed **recursively** — it is reclaimed only
  when empty and unleased, so a directory of orphaned bytes takes one extra sweep cycle to
  disappear. That is the safe direction.
- The reachability check and the unlink run inside **one** database write, which serialises them
  against another process's lease INSERT (NSE vs main app). This deliberately deviates from "file
  I/O outside DB transactions" — **that atomicity is the fix** — and the rule's rationale is
  neutralised because both filesystem calls cannot throw.
- `message_meta.folderId = ''` legacy rows remain invisible to the folder purge, and SQLite `LIKE`
  is case-insensitive so a header-id prefix can match a case-variant sibling folder. Both are
  inherited from the reference, neither is widened here, and the narrowing above confines the blast
  radius to orphan ids where the reference's unconditional form could take a live sibling's.

**Tests / evidence.** `c4fedffcb` — 6 tests including the narrowing's tripwire, which is **RED
against a verbatim reference port**, plus both sides of the richness compare; the pre-existing
collision test was checked for blessing the bug and re-commented to record that it pins the **tie**
case, not "always drop the old". `03565766f` — 7 tests with a live orphan control in the same run so
the protection cannot pass vacuously. `b686431f5` — 13 new tests plus **2 rewritten ones that
BLESSED the old drop-silently behaviour**, with an unregistered control in every eviction test.

**Relates:** ADR-IOS-068 §7 (the two keying schemes), ADR-IOS-050 (`bodyComplete` is the FTS-indexed
truth), ADR-IOS-047, ADR-IOS-070 (066's disposition), global `CLAUDE.md` rule 11 (never truncate
user content), migration `v79`.
