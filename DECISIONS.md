# TabMail iOS - Architectural Decisions

> **Check this file before proposing alternatives.** For cross-cutting decisions, see `../DECISIONS.md`.

---

## Foundational Principle: Never Drop User Intention

The following ADRs (001, 003, 018, 019) form a unified system built on one principle: **user intention must never be lost.** When a user performs an action — archive, delete, send, tag — that intention is persisted to the database before the UI acknowledges success. Remote execution is deferred and retried until complete or provably unnecessary.

**Key invariants across all queue-based systems:**

- **Persist → Acknowledge → Execute** — database write happens before UI dismissal/animation. If persist fails, the user sees an error and retains their data (compose stays open, action is not animated).
- **Remote state wins on conflict** — when sync reveals the server already reflects the desired state (message deleted by another client, tag set by TB addon), the queued operation is silently dropped. The server is the source of truth.
- **Treat all instances equally** — IMAP keyword changes from another TabMail instance (e.g., TB addon setting `tm_archive`) are treated as equivalent to local user actions. When consolidating, the most recent writer wins regardless of which device originated the action. The queue is not privileged over remote state.
- **Never silently discard user work** — failed operations remain visible for user action (retry/dismiss). Automatic cleanup only applies to provably-completed operations.

**A queued operation may leave the queue for exactly FOUR reasons — and no others** (ADR-IOS-067 as amended by ADR-IOS-069, commit `3843940cb`):

1. **Provider success.**
2. **A provider-authoritative stale/no-op result** — the provider told us the work is already done or no longer applicable. *"We could not determine the answer" is NOT this.* A thrown read, an unresolvable identity, a failed durable write and an **unknown** epoch are all **retryable**, never authoritative.
3. **Annihilation by a newer inverse user action** — only when the earlier operation was **never attempted**, the members match **exactly**, and the new action is a true inverse.
4. **Invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover, or a provider stable-id reset, drops every queued op that named an address in the affected space: not rebound, not re-resolved, not re-searched, not quarantined, not retried under the new numbering. v3 compares an op against its **durable** `PendingOperation.observedUidValidity`, not a selection minted inside the same call, so once the folder's epoch provably moves **every retry of that op fails identically and forever** — dropped rather than executed under numbering it never observed. Governing principle **C3: no action may ever mutate the wrong message; failing closed is always acceptable.** Registered as `IOS-EPOCH-001` / `IOS-ACTION-002` in `KNOWN_ISSUES.md`.

**Exit 4 does not widen clause 2.** Exit 4 requires a **proven** epoch change — a *positive* fact, an epoch the server actually reported that disagrees with the one the op durably recorded. Clause 2's *unknown* epoch is its opposite — an **absence of evidence** — and stays retryable forever. The two are disjoint. Exit 4 is the only exit that is a failure, it is deliberately narrow, and **nothing else may use it**. A bounded, visible, retryable quarantine is **not** a discard, and a transient failure is **not** an exit. The carve-out does not extend past queue state: Outbox sends, user-authored drafts, bodies, attachments and FTS content are never dropped under it.

**Normative statement of this invariant: `Companion/Rules/Active/never-drop-user-intention.md`, including its current routing note.** This section, `CLAUDE.md` § *Core Philosophy: Never Drop User Intention*, `Companion/Decisions/foundational-principle.md` (the superseded pre-hardening `v1.6.38` wording, preserved in place) and `Companion/Decisions/Active/adr-ios-067.md` are pointers to it. Where any of them differs, that file wins.

---

## ADR catalog

**This file is a router, not an archive.** Every ADR body is preserved in full under
[`Companion/Decisions/`](Companion/Decisions/manifest.tsv); the manifest carries a `sha256` per ADR.
The decision title is also the keyword set for routing. Status notes call out partial amendments that a
directory name alone cannot express. Read the exact preserved wording in
[`Foundational principle`](Companion/Decisions/foundational-principle.md) whenever the task touches
queues, optimistic UI, retries, reconciliation, Undo, Outbox, drafts, or notifications.
`Superseded` and `Deferred` entries are evidence and constraints, not current implementation authority.

| ADR | Status | Decision / keywords | Detail |
|---|---|---|---|
| ADR-IOS-001 | Active | Optimistic UI with Hardened Sync | [read in full](Companion/Decisions/Active/adr-ios-001.md) |
| ADR-IOS-002 | Active | User Activity Prioritization | [read in full](Companion/Decisions/Active/adr-ios-002.md) |
| ADR-IOS-003 | Active | Pending Operation Queue for Crash Recovery | [read in full](Companion/Decisions/Active/adr-ios-003.md) |
| ADR-IOS-004 | Superseded | ~~First Compute Wins for Cross-Instance Action Tags~~ (SUPERSEDED by ADR-IOS-036) | [read in full](Companion/Decisions/Superseded/adr-ios-004.md) |
| ADR-IOS-005 | Active | Progressive Background Backfill | [read in full](Companion/Decisions/Active/adr-ios-005.md) |
| ADR-IOS-006 | Active | Storage-Budget Retention with Progressive Crawling | [read in full](Companion/Decisions/Active/adr-ios-006.md) |
| ADR-IOS-007 | Active | Hybrid FTS5 + Vector Search (Local) | [read in full](Companion/Decisions/Active/adr-ios-007.md) |
| ADR-IOS-008 | Active | AI Processing Must Replicate TB Addon Architecture | [read in full](Companion/Decisions/Active/adr-ios-008.md) |
| ADR-IOS-009 | Active | Two-Tier Delta + Full Sync | [read in full](Companion/Decisions/Active/adr-ios-009.md) |
| ADR-IOS-010 | Active | Device Always-On Sync with AI Cache Probe | [read in full](Companion/Decisions/Active/adr-ios-010.md) |
| ADR-IOS-011 | Active | ActionTag Raw Values Are Plain Names | [read in full](Companion/Decisions/Active/adr-ios-011.md) |
| ADR-IOS-012 | Superseded | ~~Inbox Excluded from Stale Detection~~ (SUPERSEDED) | [read in full](Companion/Decisions/Superseded/adr-ios-012.md) |
| ADR-IOS-013 | Active | Direct Priority Path for Opened Emails | [read in full](Companion/Decisions/Active/adr-ios-013.md) |
| ADR-IOS-014 | Active | IMAP Connection Pool (supersedes serial lock) | [read in full](Companion/Decisions/Active/adr-ios-014.md) |
| ADR-IOS-015 | Active | Three-Tier Background Execution for AI Processing | [read in full](Companion/Decisions/Active/adr-ios-015.md) |
| ADR-IOS-016 | Superseded | ~~PersistenceGateway — Coalesced SwiftData Saves~~ (SUPERSEDED) | [read in full](Companion/Decisions/Superseded/adr-ios-016.md) |
| ADR-IOS-017 | Superseded | ~~Remove Folder→MessageHeader @Relationship~~ (SUPERSEDED) | [read in full](Companion/Decisions/Superseded/adr-ios-017.md) |
| ADR-IOS-018 | Active core; queue mechanics amended by 060 | Persistent Offline Action Queue | [read in full](Companion/Decisions/Active/adr-ios-018.md) |
| ADR-IOS-019 | Active | Outbox — Persistent Offline Send Queue | [read in full](Companion/Decisions/Active/adr-ios-019.md) |
| ADR-IOS-020 | Active | Swift 6 BGTask Handler Isolation Pattern | [read in full](Companion/Decisions/Active/adr-ios-020.md) |
| ADR-IOS-021 | Active | Backfill Power Optimization | [read in full](Companion/Decisions/Active/adr-ios-021.md) |
| ADR-IOS-022 | Active | Agent Chat with Persistent History | [read in full](Companion/Decisions/Active/adr-ios-022.md) |
| ADR-IOS-023 | Active | Mobile-Native Chat UX (Exception to TB Parity) | [read in full](Companion/Decisions/Active/adr-ios-023.md) |
| ADR-IOS-024 | Active confirmation contract; delivery amended by 053 | Destructive Tool Confirmation with ToolDeclinedError | [read in full](Companion/Decisions/Active/adr-ios-024.md) |
| ADR-IOS-025 | Active | Backfill Crawl Progress Must Not Use Date-Based Anchors From Unrelated Queries | [read in full](Companion/Decisions/Active/adr-ios-025.md) |
| ADR-IOS-026 | Active | Proactive Local Notifications (Replicating TB's Nudge System) | [read in full](Companion/Decisions/Active/adr-ios-026.md) |
| ADR-IOS-027 | Active | Ever-Rolling FIFO Queues — Leave Only on Confirmed Success or Confirmed Stale | [read in full](Companion/Decisions/Active/adr-ios-027.md) |
| ADR-IOS-026B | Superseded on v3 by the native-provider-id keying rule (D4); preserved for history | PendingOperation Uses Stable IDs (rfc822MessageId) | [read in full](Companion/Decisions/Superseded/adr-ios-026b.md) |
| ADR-IOS-028 | Active | Background Execution Budget — Lightweight Refresh, Heavy Processing | [read in full](Companion/Decisions/Active/adr-ios-028.md) |
| ADR-IOS-029 | Active | Database Index Management — Purpose-Built Indexes, Drop What's Superseded | [read in full](Companion/Decisions/Active/adr-ios-029.md) |
| ADR-IOS-030 | Active compose FIFO; delivery amended by 053 | Agent Compose Tool FIFO Queue | [read in full](Companion/Decisions/Active/adr-ios-030.md) |
| ADR-IOS-031 | Active | Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`) | [read in full](Companion/Decisions/Active/adr-ios-031.md) |
| ADR-IOS-032 | Partially superseded by 034; Swift stack retained, session-document model replaced | Memory Search Reuses iOS Swift Hybrid FTS Stack (No Rust FFI) | [read in full](Companion/Decisions/Active/adr-ios-032.md) |
| ADR-IOS-034 | Active | Memory Index Moves to Per-Turn Granularity (Supersedes v2 Session-Document Model) | [read in full](Companion/Decisions/Active/adr-ios-034.md) |
| ADR-IOS-036 | Active | Action Tags Are Local-Only (Supersedes ADR-IOS-004) | [read in full](Companion/Decisions/Active/adr-ios-036.md) |
| ADR-IOS-037 | Active | NSE/Main-App AI Ownership Lease (Cross-Process Coordination) | [read in full](Companion/Decisions/Active/adr-ios-037.md) |
| ADR-IOS-038 | Active | Demo Mode — Custom JWT + Local Mock Provider + Pre-Baked AI Cache | [read in full](Companion/Decisions/Active/adr-ios-038.md) |
| ADR-IOS-039 | Active | Idempotent HTML Render Fit + Scroll-Phase Height Freeze | [read in full](Companion/Decisions/Active/adr-ios-039.md) |
| ADR-IOS-040 | Active | Zero (BYOK) Plan in the IAP Plan Picker — Three-Tier, Display-Only Naming | [read in full](Companion/Decisions/Active/adr-ios-040.md) |
| ADR-IOS-041 | Active | GRDB Database Suspension — 0xdead10cc Defense | [read in full](Companion/Decisions/Active/adr-ios-041.md) |
| ADR-IOS-042 | Active | Stale-Detection Overlap Window Is Measured in the Fetch's Ordering Dimension (UID for IMAP, date for Gmail/Exchange) | [read in full](Companion/Decisions/Active/adr-ios-042.md) |
| ADR-IOS-043 | Active | Outgoing Thread Binding — One Header Builder, Gmail Carries `threadId` | [read in full](Companion/Decisions/Active/adr-ios-043.md) |
| ADR-IOS-044 | Active | Inbox Usage-Throttle Banner — Driven by Cached `/whoami`, Tier-Branched CTA | [read in full](Companion/Decisions/Active/adr-ios-044.md) |
| ADR-IOS-045 | Active | Attachment QuickLook Is Presented Imperatively (Detached From the SwiftUI Tree) | [read in full](Companion/Decisions/Active/adr-ios-045.md) |
| ADR-IOS-046 | Active | Background Drain Loops Are Abandon-on-Suspend — Never Hold a Lease to "Look Cooperative" | [read in full](Companion/Decisions/Active/adr-ios-046.md) |
| ADR-IOS-047 | Active | Two-Phase NSE Merge — Header+Snippet Visibility Is Decoupled From the Body-Blob Write | [read in full](Companion/Decisions/Active/adr-ios-047.md) |
| ADR-IOS-049 | Active instant-insert path; display compensation amended by 055 | Instant Inbox Insert — Render NSE-Staged Mail In-Memory, Before the Durable Merge Write | [read in full](Companion/Decisions/Active/adr-ios-049.md) |
| ADR-IOS-050 | Active | `bodyComplete` Is the FTS-Indexed Truth — Display-Cache Eviction Never Touches It | [read in full](Companion/Decisions/Active/adr-ios-050.md) |
| ADR-IOS-051 | Active | Evidence-Triggered IMAP External-Deletion Reconcile (VANISHED + Count-Mismatch UID Walk) | [read in full](Companion/Decisions/Active/adr-ios-051.md) |
| ADR-IOS-052 | Active | Presentation-Time ICS Sanitizer for Incoming Invites | [read in full](Companion/Decisions/Active/adr-ios-052.md) |
| ADR-IOS-053 | Active | Owned, Level-Triggered Delivery for FSM Tool UI Requests (Supersedes the delivery mechanism of ADR-IOS-024 and ADR-IOS-030) | [read in full](Companion/Decisions/Active/adr-ios-053.md) |
| ADR-IOS-054 | Active | Programmatic Message Opens Use a Real `navigationDestination(item:)` Push — Never the Inbox `List(selection:)` Binding | [read in full](Companion/Decisions/Active/adr-ios-054.md) |
| ADR-IOS-055 | Active | Single Merged Read-Model for the Inbox List — One Pure Composer over Durable ∪ Pinned ∪ Staged | [read in full](Companion/Decisions/Active/adr-ios-055.md) |
| ADR-IOS-056 | Active | Active Body/AI Flushes Are Normal-Tier; the Drain Budget Is a Background-Envelope Watchdog Only | [read in full](Companion/Decisions/Active/adr-ios-056.md) |
| ADR-IOS-057 | Superseded queue mechanics; replaced by 060 | The Action Queue Is an Intent Register, Not an Event Log — Latest-Intent Coalescing per Message Id | [read in full](Companion/Decisions/Superseded/adr-ios-057.md) |

## Forward-ported decisions absent from the shipped source

These ADR bodies exist only on the mature pre-v3 line and are therefore not in `v1.6.38:DECISIONS.md`. The bodies are preserved byte-for-byte with their provenance in [`Companion/Decisions/ported-manifest.tsv`](Companion/Decisions/ported-manifest.tsv). They are excluded from the source-document reconstruction manifest and census.

| ADR | Status | Decision / keywords | Detail |
|---|---|---|---|
| ADR-IOS-058 | Active retained invariants; partially superseded by 060 | The Intention Journal — Dumb Append, Derived Overlay, Fold at Drain (Supersedes the ADR-IOS-057 Register) | [read in full](Companion/Decisions/Active/adr-ios-058.md) |
| ADR-IOS-059 | Superseded | A Folder Role Is Never Identity — Undo Resolves by a Recorded Tuple and Drops on Any Mismatch | [read in full](Companion/Decisions/Superseded/adr-ios-059.md) |
| ADR-IOS-060 | Active | Durable Message Actions Are One Dumb Global FIFO | [read in full](Companion/Decisions/Active/adr-ios-060.md) |
| ADR-IOS-061 | Active | UIDVALIDITY Reset Closure — Detect Everywhere, Refuse at the Provider, Purge-and-Resync the Folder | [read in full](Companion/Decisions/Active/adr-ios-061.md) |
| ADR-IOS-063 | Deferred follow-up; recorded but not implemented | Account-Removal Orphan-Frontier Hardening — DEFERRED Out of F2b L4 (Fix-Pack FIX 5) | [read in full](Companion/Decisions/Deferred/adr-ios-063.md) |
| ADR-IOS-064 | Active withdrawal record | The F2b L-series is withdrawn — inert code is removed, applied migrations are not | [read in full](Companion/Decisions/Active/adr-ios-064.md) |
| ADR-IOS-065 | Active | Undo-Send close decision — restore the shipped prompt without rotating the epoch | [read in full](Companion/Decisions/Active/adr-ios-065.md) |
| ADR-IOS-066 | Active | Content is addressed by the message it belongs to, never by the slot it occupies | [read in full](Companion/Decisions/Active/adr-ios-066.md) |
| ADR-IOS-067 | Active | A queued intention leaves the queue for exactly three reasons, and a failure is never one of them | [read in full](Companion/Decisions/Active/adr-ios-067.md) |

## Numbering and non-ADR material

- Unused/reserved numeric slots: 033, 035, and 048. Slot 048 was intentionally skipped after a reverted prototype; its history is preserved in the 049 detail.
- `v1.6.38:DECISIONS.md` defines `ADR-IOS-026` twice. The second definition (`PendingOperation Uses Stable IDs (rfc822MessageId)`) routes as **ADR-IOS-026B**, preserving the reference renumbering and the v3 working-tree heading.
- [`New-decision template`](Companion/Decisions/Templates/new-decision-template.md) is preserved source material and is excluded from the ADR census.

---

## Retained inline — no byte-identical routed twin

Everything below is kept **verbatim** because its `Companion/Decisions/` twin is not byte-identical
(post-`v1.6.38` amendments live only here) or because it has no routed twin at all. These blocks
are the compaction drift list: check the routed twin before editing one.


## ADR-IOS-026B: PendingOperation Uses Stable IDs (rfc822MessageId) — SUPERSEDED by ADR-IOS-068

> **SUPERSEDED 2026-08-02 by ADR-IOS-068.** Retained verbatim below as evidence and history; it is
> no longer implementation authority. This record was authored under the number `ADR-IOS-026`,
> colliding with *"Proactive Local Notifications"* above; it is referred to elsewhere in this repo
> and in the reference line as **ADR-IOS-026B**, and the heading now carries both so either search
> term finds it. **Only its durable-mutation-authority layer is superseded.** Every other RFC use
> it names — fetch, normalize, dedup, stage, the AI cross-device cache probe, threading/references,
> Outbox send de-duplication — SURVIVES; see ADR-IOS-068's exempt list, which is normative.

**Context:** PendingOperation.messageIds stored numeric IMAP UIDs. If the server changes UIDVALIDITY (mailbox compaction, migration, backup restore), all UIDs are reassigned. Queued operations would reference stale UIDs — either failing silently or targeting wrong messages.

**Decision:** PendingOperation.messageIds now stores `rfc822MessageId` (RFC 2822 Message-ID header) for IMAP messages instead of numeric UIDs. The `MessageHeader.stableId` computed property returns `rfc822MessageId` when the messageId is numeric (IMAP UID) and rfc822MessageId is available, otherwise returns messageId. Gmail/Exchange use non-numeric stable provider IDs, so `stableId` returns messageId unchanged for those.

**Implementation:**
- `MessageHeader.stableId` — computed property: if `UInt32(messageId) != nil` and `rfc822MessageId` is non-empty, returns `rfc822MessageId`; otherwise returns `messageId`
- All PendingOperation queue sites use `stableId` instead of `messageId`
- `queueTagWrite` accepts optional `rfc822MessageId` parameter for the same logic
- `IMAPProvider.resolveUID()` already handles non-numeric IDs via IMAP `SEARCH` by Message-ID header — no provider changes needed
- `SyncEngineFullSync` pending-op matching checks both `info.messageId` and `info.rfc822MessageId` against pending sets (dual-match)
- Undo cancellation matching also checks both numeric and stable IDs

**Rationale:** UIDVALIDITY changes are rare but catastrophic for queued operations. RFC 2822 Message-ID is immutable and server-independent. The undo path already used `rfc822MessageId` for IMAP move-back operations — this extends the same pattern to all operations.

**Consequences:**
- PendingOps for IMAP messages without rfc822MessageId still fall back to numeric UID (some drafts, system notifications)
- Drain-time UID resolution does an extra IMAP SEARCH for non-numeric IDs — negligible cost since pending ops are low-volume
- Dual-matching in sync adds minimal overhead (one extra set lookup per message)

---

---

# v3 records (ADR-IOS-068 … 072)

> **Numbering note.** This file jumps from ADR-IOS-057 to ADR-IOS-068. That gap is deliberate and is
> itself a record: **ADR-IOS-058, 059, 060, 061, 062, 063, 064, 065, 066 and 067 were authored on a
> line that never shipped to a user device.** They are not missing and must not be re-created here.
> **ADR-IOS-070 is their disposition record** — read it before concluding that any of those numbers
> is available, unrecorded, or lost. `v2final` (`e28dd4edb`) holds their bodies and remains readable
> with `git show v2final:Companion/Decisions/…`; that branch is preserved precisely so this history
> stays searchable.

## ADR-IOS-068: Durable Message Actions Are Keyed by the Native Provider Id (Supersedes ADR-IOS-026B)

**Date:** 2026-08-02

**Status:** Active. **Supersedes ADR-IOS-026B** (the `stableId` / RFC-822 durable-action-identity
scheme). Withdraws the identity half of the unreleased ADR-IOS-060 (see ADR-IOS-070). Folds in the
principle of the unreleased ADR-IOS-059. Owner constraint D4, frozen 2026-07-30.

**Context — the failure.** A user with **aliases** receives one message more than once, so two local
rows carry the same RFC 822 Message-ID. Every durable action keyed by that RFC becomes ambiguous.
The concrete observed regression was one Gmail message delivered to two aliases in the same account.
Two server resources can share one RFC Message-ID; **RFC is corroborating metadata, never mutation
authority.**

Both existing designs are wrong on that input, in opposite directions, and each leg is independently
sufficient to justify this record.

**Leg 1 — the post-`v1.6.38` line fails CLOSED, and it is a defect CLASS, not one code path.**

- *Swipe / durable queue.* The reference's UID resolver returns `.ambiguous` on a multi-hit, the
  consumer `guard case .exact(let uid) = … else { continue }` **skips the member**, and the batch
  then hits `guard !messages.isEmpty else { return }` — **returning success with nothing done.** The
  op is deleted as a success, the gesture is lost, and the next sync visibly reverts it.
- *Notification actions.* `resolveDurableInboxHeader`'s RFC arm is **account-global, not
  folder-scoped**, and takes `prefix(2)`; two hits ⇒ `.ambiguous` ⇒ the handler returns without
  acting. **Every notification action button on that message silently does nothing, forever.**
- *AI writes.* `AIWriteTarget.capture` returns `nil` when the row is RFC-less and has no UIDVALIDITY
  baseline, so **the whole AI job no-ops** — a second live "permanently un-analysable" path.

A design that removed RFC authority from the queue alone would leave the second and third broken.
This ADR therefore governs **every** durable identity site, not the queue.

**Leg 2 — the shipped `v1.6.38` fails OPEN: one swipe mutates every copy.** `MessageHeader.stableId`
returns the RFC whenever `messageId` is numeric and an RFC is present; `IMAPProvider.resolveUID`
falls through to `searchByMessageId` and returns **the entire `UIDSet` with no cardinality check**;
its consumer stores flags on that whole set. On IMAP, one swipe on a duplicated-RFC message mutates
**every copy** — and has done so since before `v1.6.38`. That defect is recorded as `IOS-IMAP-002`
under *Fixed by D4* in `KNOWN_ISSUES.md`.

**Decision.**

1. **Identity.** A durable action op records **the native provider identifier of the message the
   user gestured on, in the mailbox it was gestured in, and nothing else.**

   | Provider | v3 durable action key |
   |---|---|
   | IMAP / iCloud | **`(UIDVALIDITY, UID)`** |
   | Gmail | `message.id` |
   | Graph / Outlook | `message.id` |

   A UID is a mailbox-local integer the server may reassign, so it is meaningful **only** inside the
   UIDVALIDITY generation it was observed in. The op carries one **source** epoch stamp; anything
   that additionally dereferences a *destination* UID must record and assert a **destination** epoch
   as well.

2. **The RFC 822 Message-ID is never consulted to select or authorize a mutation target on any
   provider.** Prior art, quoted from the shipped register: ***"RFC cardinality is never mutation
   authority."*** ADR-IOS-026B's leap from "we fetch, normalize, dedup and stage by RFC" to "RFC is
   therefore durable **mutation authority**" is the defect; that leap alone is superseded.

3. **C3 — the hard invariant.** *A provider issues a mutating command only against the exact
   provider identifier recorded when the user's gesture was admitted, and only while it has
   positively proven that this identifier still denotes the same message it denoted at admission;
   when that proof is unavailable, ambiguous, or contradicted, the operation is abandoned without
   mutating anything.* **Failing closed is always acceptable. Mutating the wrong message is not.**
   Its discharge checklist is normative: epoch assertion after *every* SELECT of a mailbox whose
   UIDs the op names; existence proof by `UID FETCH` before the first mutation; response-integrity
   checks; mutating UIDSets built **only** from UIDs that passed those checks, so **no SEARCH result
   is ever a mutation target**; no argument-less `EXPUNGE` on any action path, ever; and no
   unasserted gap — between the last epoch assertion and the mutating command the only permitted
   awaits are non-mutating commands on the same uninterrupted selection.

4. **The IMAP leg's spec, lifted from the shipped `IOS-DRAFT-008` (already D4-shaped).** Strong
   `(UIDVALIDITY, UID)` operations verify the live epoch before mutation. The source epoch is
   **captured with the source row**, not reconstructed later: `MessageHeader.observedUidValidity`
   (migration `v77`) and its `MessageSnapshot` copy carry the UIDVALIDITY under which that exact UID
   was fetched or authoritatively adopted, and it is stamped onto
   `PendingOperation.observedUidValidity` (migration `v69`) at admission. Unproven ingress records
   nil; zero is unknown and also becomes nil. **Never substitute the current
   `Folder.lastKnownUidValidity` for a missing row/snapshot epoch** — that blesses an old-epoch UID
   after the mailbox has advanced.

5. **Two checkpoints, and the drop rule.** *Checkpoint A* runs inside the queue's claim/delete
   transaction, scoped to the op's exact `accountId + folderPath`, before any provider I/O: every
   member must be a positive native UID, the op epoch nonzero, the stored Folder epoch nonzero and
   equal, and no reset pending. *Checkpoint B* passes the admitted epoch explicitly through the
   concrete IMAP action APIs and compares it after the wrapper SELECT and every inner source
   re-SELECT. A failure at either **deletes the whole op** — never a passing subset — and if that
   delete write fails, the original op is requeued unchanged. Checkpoint A is **type-scoped to the
   13 action types**: `executeSingleOp` receives every op type and draft ops' `messageIds` are not
   header ids at all, so an unscoped checkpoint would misclassify them.

6. **A folder role is never identity** (the surviving principle of the unreleased ADR-IOS-059).
   Undo resolves by the **recorded tuple** — account, mailbox, native id, epoch — and **drops on any
   mismatch.** A role such as "Archive" or "the inbox" is a label on a mailbox, not a name for a
   message, and may never be substituted for a recorded address.

7. **Two keying schemes, on purpose.** Durable **actions** key by provider id, because that is what
   distinguishes two copies of one message. **Content** — FTS rows, body assets, the AI cross-device
   cache probe — keys by RFC, because two copies of one message *are* the same content. This is not
   an inconsistency and must not be "unified" by a later tidy-up; see ADR-IOS-072 for the content
   side.

**What RFC is still used for — normative exempt list. Do NOT sweep these.** An unlisted RFC site is
by construction a removal candidate, so an **omission from this list is itself a bug**.

| Surface | Why it keeps RFC |
|---|---|
| **`MessageExistenceProbe` / `currentUIDs` / `messageExistsInFolder`** ★★★ | Two consumers: the queue **and, destructively, the backfill body queue**. `confirmGoneAtThreshold` opens `guard let prober = provider as? any MessageExistenceProbe else { return .gone }`, and `.gone` deletes the user's local header. **Removing the conformance does not disable a check — it converts every IMAP backfill miss at threshold into "delete the user's local header and body"**, and destroys the UID-remap re-key that project memory records as the 2026-06-09 FTS body-loss root cause. **KEEP THE CONFORMANCE.** |
| Sent-folder duplicate-APPEND guard (`appendToSentFolder` → `searchByMessageId`) | The only thing preventing a duplicate Sent copy when an append is retried after a partial finalize. Double-send prevention is non-negotiable. |
| Pre-generated `sentMessageId` on the Outbox claim path | It is both the wire Message-ID and that dedup key. |
| Draft RFC ≠ sent RFC in Outbox server-draft cleanup | Conflating them orphans the server draft. |
| ~~IMAP draft UID **discovery**~~ **RETIRED — this row was itself a D4 violation.** | It read: *"RFC is the search key used to learn the UID after a non-UIDPLUS APPEND; the UID remains the identity."* That is exactly the forbidden relationship, dressed as discovery: the learned UID became a **mutation address** that `DraftStore` persisted and `deleteDraftStrong` later `STORE \Deleted`-ed and, on UIDPLUS, **irreversibly UID-EXPUNGEd**. Exact-match and cardinality guards prove one message carries the Message-ID — never that it is the message we appended. Removed in "Refuse a draft address derived from a Message-ID SEARCH"; absence of `APPENDUID` now yields `.unaddressable`. **Do not restore this row.** |
| AI cross-device cache probe (`MessageIdentity.aiCacheKey`) | ADR-IOS-026B / ADR-IOS-010; shared with the Thunderbird addon. A provider id is device-local. |
| Threading / `References` / `In-Reply-To` | RFC 5322 threading is *defined* on Message-ID. |
| The two-key sync filter (`PendingOperation.containsAnyKey`) | Explicitly preserved by D4's scope boundary. Do not tidy. |

**Rationale.**

- **On the IMAP leg this is a forward design, not a revert. State this plainly whenever the change
  is described.** On Gmail and Graph, and on the notification lookup path, D4 restores what
  `v1.6.38` already did. On the IMAP action queue the shipped release is **the less safe of the two
  designs**: the reference fails closed where the base fails open. D4 is the first design correct on
  that leg, because **it never produces a multi-match set at all** — there is no cardinality to
  check, because the action queue's own path never searches.

  ⚠️ **This bullet previously ended "because nothing searches", full stop. That was false and is
  retracted.** `searchByMessageId` retains two live call sites, and a third — `saveDraft`'s
  no-`APPENDUID` arm — was live when this sentence was written and did convert a SEARCH hit into a
  draft mutation address (`IOS-IMAP-002`'s retraction; fixed separately). **The property D4 actually
  guarantees is narrower and is the one that matters: no SEARCH result is ever a mutation target.**
  State it that way, never as "nothing searches" — the blanket phrasing is what let the draft arm sit
  inside a frozen ADR that forbids it. The two survivors are both non-mutation reads:
  `appendToSentFolder` uses cardinality only, as an existence probe, and never converts a hit into an
  address; `currentUIDs` / `messageExistsInFolder` feed the backfill body queue's re-key, which is a
  **local** header address for a body fetch, not a wire mutation target — its multi-hit resolution is
  registered as an open lead (`IOS-BACKFILL-002`).
- UID keying is viable now only because C2/C4/C5 (ADR-IOS-069) removed the durability-across-reset
  requirement that forced RFC keying in the first place. It **deletes** code rather than adding it.
- Graph ids are stable for a message *in place*, but Graph **reallocates the id on move**. That is
  expected and resolves to a stale no-op — it is not a reassignment of one id to a *different*
  message, which is the hazard this ADR guards. Do not write "never reassigned".

**Consequences.**

- `MessageHeader.stableId` is no longer durable-action authority. `uidResolutionRetryCount` becomes
  dead: the column stays, the logic goes.
- A duplicated-RFC message is now actionable on every provider, and a swipe on one copy mutates only
  that copy.
- The move path owns its sequence rather than delegating: `IMAPProvider.move` no longer calls
  `server.move`, and issues COPY → STORE `\Deleted` → (UIDPLUS only) scoped `UID EXPUNGE` itself,
  asserting the admitted epoch at **five** boundaries (`3843940cb`). A non-UIDPLUS server fails
  closed at copy-plus-soft-delete with **no expunge of any kind**.
- Provider error classification stops depending on a discarded HTTP body: `HTTPRequestResult
  .errorBody`, `HTTPError.networkErrorWithBody` and `AuthedHTTP.requestPreservingBadRequestBody`
  (`cd2062bea`) are the substrate the Gmail/Graph structural-400 classifiers read, so a
  structurally-invalid-id 400 can be retired as a stale no-op instead of retried forever.
- Notification taps are scoped to their account and their exact composite address, and a thrown
  durable read is no longer treated as absence (`7c26989b9`). A nil-`accountId` tap previously
  matched **any** account sharing the UID and durably marked that message read.

**Tests / evidence.** `3843940cb` (IMAP move wire contract, 8 tests extending the `FakeIMAPServer`
wrong-message wire oracle rather than a bespoke hook, both non-vacuity partners strict);
`7c26989b9` (11 two-sided notification tests; one test that BLESSED the nil-account hazard deleted,
five repaired); `cd2062bea` (12 + 22 HTTP tests). Every one of those commits landed inside a
combined clean build plus full suite at 8,080 passed / 0 failures / 0 production warnings.

**Relates:** ADR-IOS-026B (superseded), ADR-IOS-042 (the same "window in the fetch's own ordering
dimension" principle applied to sync), ADR-IOS-003 / ADR-IOS-018 (the queue charter this keys),
ADR-IOS-069 (what happens when the id resets), ADR-IOS-070 (the withdrawal record), ADR-IOS-071 (no
backward compatibility), ADR-IOS-072 (the content side of the two keying schemes), `KNOWN_ISSUES.md`
(`IOS-IMAP-002` under *Fixed by D4*), `PLAN_IOS_REFACTOR_V3/PLAN_V3_S3_design.md` §3.1–§3.6.

---

## ADR-IOS-069: An Id Reset Invalidates the Affected Queued Ops — They Are Dropped, Not Rebound

**Date:** 2026-08-02

**Status:** Active. **Amends ADR-IOS-067's exit enumeration with a fourth exit.** Withdraws the
rebinding/quarantine machinery of the unreleased ADR-IOS-061 (see ADR-IOS-070). Owner constraints
C2, C4 and C5, frozen 2026-07-30.

**Context.** "Never drop user intention" (the foundational principle at the head of this file) has
governed every queue in this app since ADR-IOS-003. The unreleased line took it literally across an
identity boundary and grew an epoch ledger, a quarantine, a refusal contract and a rebinding
protocol so that a queued op could survive a UIDVALIDITY change — roughly 600 lines whose entire
purpose was to re-point an intention at a message whose address had been reissued. That is a
**compensating mechanism**: every edge case of the reset became an edge case of the restoration.

The owner's ruling: ***"much better than a fragile and complicated codebase."***

**Decision.**

1. **A UIDVALIDITY change, or a provider stable-id reset, INVALIDATES every queued op that named an
   address in the affected space.** Those ops are **dropped** — *not* rebound, *not* re-resolved,
   *not* re-searched, *not* quarantined, *not* retried under the new numbering.
2. **This is a fourth exit from the queue**, and it is the only one that is a failure. Restating the
   full enumeration: a queued intention leaves the queue for exactly these reasons —
   1. provider-confirmed success;
   2. a provider-authoritative stale/no-op result (absence, a thrown read, an unresolved identity, a
      failed write and an unknown epoch are **retryable**, never authoritative);
   3. annihilation by a newer exact inverse user action, only when the earlier operation is
      unattempted and the members match exactly;
   4. **invalidation by an id reset in its own address space** — this record.
   Exit 4 is deliberately narrow. **Nothing else may use it.** A bounded, visible, retryable
   quarantine is not a discard, and a transient failure is still not an exit.
3. **"Never drop user intention" holds in full on the ordinary path** — offline, retry, app kill,
   provider error, transient read failure. Only the id-reset boundary is carved out.
4. **The carve-out does not extend past queue state.** Outbox sends, user-authored drafts, bodies,
   attachments and FTS content are never dropped under this ADR. Double-send prevention is
   unchanged, non-negotiable and independent of identity keying.
5. **The signal on refusal is a log, and nothing else.** Drop the refused **whole** operation, never
   a split subset and never unrelated queued work. If the deletion write itself fails, requeue that
   original operation unchanged and stop.
6. **Once dropped, dropped.** v3 compares against the op's **durable** `observedUidValidity`, not
   against a selection minted inside the same call. The reference's refusal silently re-armed on
   retry; v3's does not — **once the folder's epoch moves, every retry of that op fails identically
   and forever.** The intention is dropped rather than executed under numbering it never observed.

**Rationale.** The user's cost is one repeated gesture. The alternative's cost is a rebinding
protocol on the exact path where every wrong-message defect in this app has lived. Sync reconciles
the visible state; the user redoes the action. An intention executed under numbering it never
observed is not the user's intention — it is a mutation of whatever message now holds that address,
which is precisely what C3 forbids.

**Consequences.**

- A UIDVALIDITY turnover during a burst of queued gestures loses those gestures. This is
  user-visible and is recorded as `IOS-ACTION-002` **precisely because it is a deliberate departure
  from never-drop**.
- The rare-but-real window is bounded: `3843940cb`'s accepted residual is a turnover landing between
  the COPY and the pre-STORE assertion, which leaves the copy at the destination and the original at
  the source. Sync reconciles it, and it is strictly safer than completing the delete.
- The UIDPLUS gate in the move sequence is checked **before** the final assertion, deliberately:
  asserting first would let an epoch change refuse an already-complete op, and a refusal after a
  successful COPY retries into a duplicate at the destination.

**Tests / evidence.** `3843940cb` — the epoch-assertion suite, with the durable-epoch comparison
(rather than a call-local `Selection`) as the property under test.

**Relates:** ADR-IOS-068 (what the recorded identity is), ADR-IOS-067 (the three exits this amends),
ADR-IOS-027 / ADR-IOS-018 / ADR-IOS-003 (the FIFO charter), ADR-IOS-070, `KNOWN_ISSUES.md`
(`IOS-ACTION-002`, `IOS-EPOCH-001`).

---

## ADR-IOS-070: Withdrawal Record — the Post-`v1.6.38` Intention/Identity Line Is Withdrawn, Not Superseded

**Date:** 2026-08-02

**Status:** Active withdrawal record. Precedent: ADR-IOS-064 — *"inert code is removed, applied
migrations are not."*

**Context.** Between `v1.6.38` (`07a4bb703`) and `v2final` (`e28dd4edb`) a 58-commit line built an
RFC-822 / hybrid identity model with an epoch ledger, quarantine, rebinding and a global intention
journal. **That line never shipped to a user device** — `project.yml` at its head is byte-identical
to `v1.6.38:project.yml`. v3 branches from `v1.6.38` and carries the bugfixes forward; it does not
branch from that line and revert.

A record that describes a build no user ever ran cannot be *superseded*, because superseded implies
"this was the behavior, and now it is not". It must be **withdrawn**.

**Decision.**

1. **Withdrawn, not superseded:**
   - **ADR-IOS-058** — the intention journal. Salvage only its never-drop / typed-receipt wording,
     which lives on in ADR-IOS-069's exit enumeration.
   - **ADR-IOS-060** — its FIFO half is **re-derived from ADR-IOS-003 / ADR-IOS-018**, which did
     ship and remain the base records for v3's queue; its identity half is withdrawn by
     ADR-IOS-068.
   - **ADR-IOS-061** — the epoch ledger, quarantine, refusal contract and rebinding are withdrawn.
     **Two carve-outs survive:** the purge-and-resync reaction to a UIDVALIDITY change, and the
     invariant-test layer.
   - **ADR-IOS-063** — defers a change to code that will not exist.
   - **The epoch clause of ADR-IOS-065.** The restored Undo-Send close prompt is satisfied by the
     base and survives; the epoch rotation does not.
2. **ADR-IOS-059 is not withdrawn — its principle is ported.** *A folder role is never identity;
   Undo resolves by a recorded tuple and drops on any mismatch* is base-independent and exactly
   D4-shaped. It is folded into ADR-IOS-068 §6.
3. **ADR-IOS-066 is ported as NEW WORK, not carried.** The base does not have the property it
   asserts. See ADR-IOS-072.
4. **ADR-IOS-067 is ported and amended**, with the fourth exit added by ADR-IOS-069.
5. **ADR-IOS-062 was never an ADR.** It appears in no `DECISIONS.md` at either tag and has no
   detail file; it exists only in an untracked draft headed **DRAFT**. The number is unused.
6. **ADR-IOS-057 is RE-ACTIVATED, resolving its orphaned supersession.** 057 **shipped**. It was
   superseded by ADR-IOS-058 — which never shipped — leaving 057 *superseded by nothing*. The
   decisive fact: **ADR-IOS-049 and ADR-IOS-055/056/057/058's read-model family are already in
   `v1.6.38`**; `InboxListComposer.swift` and `ThreadGroupBuilder.swift` are listed at that tag and
   their diffs across the reference range are cosmetic. v3 already has 057's behavior, shipped and
   running. **Do not leave ADR-IOS-057 marked `Superseded`** — as of this record it is **Active**.
7. **Applied migrations are never removed** (ADR-IOS-064's precedent). Migration identifiers are
   immutable once any database has run them. v3's chain resumes at **`v68`, contiguous, no gap**,
   which is safe only because the owner deleted every GRDB database carrying the unreleased
   `v68`–`v91` identifiers on 2026-07-30, so no device holds them in its applied-migration ledger.
   That predicate is recorded in the migration file itself; no runtime detection exists.
8. **Nothing is deleted.** `v2final` (`e28dd4edb`) and `backup/origin-main-pre-v3-20260730` are
   preserved refs, created before any v3 work began. Every withdrawn ADR body remains readable
   there and is the reference implementation this train ports from — its **code** was never the
   problem; its **keying** was.

**Rationale.** Recording the withdrawal explicitly is what prevents a future reader from
"restoring" a record that describes a build that never ran, and what prevents the ADR-IOS-057
inversion — the repo asserting that live shipped behavior is superseded by a withdrawn record —
from recurring. The numbering gap in this file is a pointer to this record, not an accident.

**Consequences.**

- Roughly 4,300 production lines from the reference line are simply never written. That is not work
  removed; it is work never undertaken.
- Anyone grepping for ADR-IOS-058/060/061/063 in code will find nothing, by design. Anyone reading
  those numbers in an old plan file must read this record first.
- ADR-IOS-057's re-activation is close to mechanical: no behavior changes, because the behavior is
  already the base's.

**Relates:** ADR-IOS-057 (re-activated by this record), ADR-IOS-059 / 066 / 067 (ported, not
withdrawn — see 068, 072, 069), ADR-IOS-064 (precedent), ADR-IOS-068, ADR-IOS-071.

---

## ADR-IOS-071: No Backward Compatibility for the Action Queue

**Date:** 2026-08-02

**Status:** Active. Owner constraints C1 and C6, frozen 2026-07-30; the blanket purge is
owner-authorized.

**Context.** Changing the durable action key (ADR-IOS-068) makes every pre-existing
`pendingOperation` row's payload uninterpretable under the new identity rule. The reference line's
answer was to retain and migrate those rows, because that line's policy was survival across identity
churn. v3's policy is not.

Owner: ***"no compat required. even fixes to action queue can simply drop old ops in 1.6.38 since
ops are short lived and not catastrophic when dropped."***

**Decision.**

1. **Nothing migrates old queue rows into a new shape.** There is no payload decoding, no shape
   migration, no legacy slot handling, no provider/runtime-mismatch fence and no pre-F1
   compatibility path.
2. **The one-time migration is a blanket, predicate-free purge** — `DELETE FROM pendingOperation`,
   landed as immutable migration **`v74_purgeLegacyPendingOperations`**. It removes every legacy row
   regardless of type, status, decodability or shape: queued, `inFlight`, cancelled, unknown,
   malformed, `.saveDraft` and `.deleteDraft`.
3. **`PendingOperation` owns no authored bytes.** It has no cascade into `Draft`, `Outbox`,
   `MessageBody` or attachment storage. Draft identity, body, recipients and attachments, and Outbox
   sends, live separately and remain byte-identical across the purge.
4. **The C6 boundary — do not over-apply this.**

   | Drop freely | Never drop — never-drop applies IN FULL |
   |---|---|
   | Every `PendingOperation` row, including `.saveDraft` / `.deleteDraft` | **Outbox / pending sends** — a dropped send means the user's mail silently never goes out |
   | | **Drafts / user-authored content** — identity, body, recipients and attachments |
   | | **Bodies, attachments, FTS content** — these are not queue state |

5. **No transitional RFC-only bypass.** A compatibility bypass for legacy RFC-shaped ops was
   proposed and **rejected**: C1/C6 require no legacy compatibility and C3 permits failing closed.
   During development an intermediate gate may drop every legacy RFC-shaped op; for release the
   admission gates and the native direct producers **co-land as one exact candidate** and neither
   half may ship alone.

**Rationale.** Action ops are short-lived and individually cheap to redo. Retaining them across an
identity change buys nothing and costs a decoder for shapes the new code cannot honour — a decoder
that is, by construction, the least-tested code in the queue. A one-statement purge has no failure
mode that a shape migration does not also have.

**Consequences.**

- **Accepted one-time upgrade loss**, recorded as `IOS-ACTION-001`: any op queued by a pre-v3 build
  and not yet drained at upgrade is gone. Sync reconciles the visible state.
- Dropping a `.saveDraft` loses only the **automatic server-push intention**. Sync does not recreate
  or upload it; the user explicitly saves again, which admits a fresh, safe operation. The local
  `Draft` row keeps the content.
- Dropping a `.deleteDraft` may leave a stale server draft that sync shows again. That is safer than
  retaining an obsolete destructive address; the user redoes the delete.
- Startup still independently runs Outbox reconciliation after the now-empty message queue, so
  queued / sending / sent-append recovery is unchanged.

**Relates:** ADR-IOS-068, ADR-IOS-069, ADR-IOS-070 (migration immutability precedent),
`KNOWN_ISSUES.md` (`IOS-ACTION-001`), migration `v74_purgeLegacyPendingOperations`.

---

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
