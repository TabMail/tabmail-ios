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

## Post-`v1.6.38` records — routed detail, no byte-identical `v1.6.38` twin

These records were authored after `v1.6.38`, so the pinned compaction has no byte-identical twin for them. Their bodies live **outside** `Companion/Decisions/{Active,Superseded,Deferred}/`, which is the census surface that reconstructs `v1.6.38:DECISIONS.md` exactly; their provenance, source line ranges and per-fragment `sha256` live in [`Companion/Decisions/V3/manifest.tsv`](Companion/Decisions/V3/manifest.tsv).

- **[ADR-IOS-026B — the v3 supersession record](Companion/Decisions/V3/Superseded/adr-ios-026b-v3-superseded-by-068.md)** — *PendingOperation Uses Stable IDs (rfc822MessageId)*, **SUPERSEDED 2026-08-02 by ADR-IOS-068** and retained verbatim as evidence: `MessageHeader.stableId`, `IMAPProvider.resolveUID`'s Message-ID `SEARCH`, dual-match pending-op filtering, the UIDVALIDITY rationale. **Only its durable-mutation-authority layer is superseded** — fetch, normalize, dedup, stage, the AI cross-device cache probe, threading/`References`, and Outbox send de-duplication all SURVIVE; ADR-IOS-068's exempt list is normative. Authored under the colliding number `ADR-IOS-026`, so both search terms find it. The byte-identical `v1.6.38` twin, without the supersession banner, is [`Companion/Decisions/Superseded/adr-ios-026b.md`](Companion/Decisions/Superseded/adr-ios-026b.md).
- **[Compaction drift list](Companion/Decisions/V3/retained-inline-no-byte-identical-routed-twin.md)** — the retired *Retained inline — no byte-identical routed twin* preamble: check the routed twin before editing a post-`v1.6.38` amendment.

# v3 records (ADR-IOS-068 … 072)

> **Numbering note.** This file jumps from ADR-IOS-057 to ADR-IOS-068. That gap is deliberate and is
> itself a record: **ADR-IOS-058, 059, 060, 061, 062, 063, 064, 065, 066 and 067 were authored on a
> line that never shipped to a user device.** They are not missing and must not be re-created here.
> **ADR-IOS-070 is their disposition record** — read it before concluding that any of those numbers
> is available, unrecorded, or lost. `v2final` (`e28dd4edb`) holds their bodies and remains readable
> with `git show v2final:Companion/Decisions/…`; that branch is preserved precisely so this history
> stays searchable.

- **[ADR-IOS-068](Companion/Decisions/V3/Active/adr-ios-068.md)** — Active. **Durable message actions are keyed by the NATIVE PROVIDER ID** (IMAP/iCloud `(UIDVALIDITY, UID)`, Gmail and Graph `message.id`), and **the RFC 822 Message-ID is never consulted to select or authorize a mutation target on any provider**. Supersedes ADR-IOS-026B; folds in the unreleased ADR-IOS-059's *a folder role is never identity*; withdraws the identity half of the unreleased ADR-IOS-060. Carries **constraint C3** and its discharge checklist, the two admission checkpoints and the whole-op (never a subset) drop rule, `MessageHeader.observedUidValidity` (migration `v77`) stamped onto `PendingOperation.observedUidValidity` (migration `v69`) — never substitute the current `Folder.lastKnownUidValidity`; the alias / duplicate-RFC failure on BOTH legs (the reference fails closed and silently no-ops, shipped `v1.6.38` fails open and mutates every copy — `IOS-IMAP-002`); the **normative RFC exempt list — an omission from it is itself a bug** (`MessageExistenceProbe` / `currentUIDs` / `messageExistsInFolder` — **KEEP THE CONFORMANCE**, `appendToSentFolder` duplicate-APPEND guard, the pre-generated `sentMessageId`, draft-RFC ≠ sent-RFC, `MessageIdentity.aiCacheKey`, threading/`In-Reply-To`, `PendingOperation.containsAnyKey`), the **RETIRED** draft-UID-discovery row that was itself a D4 violation, and the retracted "nothing searches" claim — the guarantee is narrower: **no SEARCH result is ever a mutation target**. §7 states the **two keying schemes on purpose** (actions by provider id, content by RFC). Evidence `3843940cb` / `7c26989b9` / `cd2062bea`.
- **[ADR-IOS-069](Companion/Decisions/V3/Active/adr-ios-069.md)** — Active. **An id reset invalidates the affected queued ops — they are DROPPED, not rebound**: not re-resolved, not re-searched, not quarantined, not retried under the new numbering. This is the **FOURTH exit** from the queue, amending ADR-IOS-067's three, and it is the only exit that is a failure — **nothing else may use it**; a bounded retryable quarantine is not a discard and a transient failure is not an exit. Withdraws the rebinding/quarantine machinery of the unreleased ADR-IOS-061 (~600 lines) as a **compensating mechanism**. v3 compares against the op's **durable** `observedUidValidity`, not a selection minted in the same call, so **once dropped, dropped**. The carve-out never extends to Outbox sends, drafts, bodies, attachments or FTS content. `IOS-ACTION-002` / `IOS-EPOCH-001`; the accepted COPY-to-pre-STORE residual window and why the UIDPLUS gate is checked BEFORE the final epoch assertion.
- **[ADR-IOS-070](Companion/Decisions/V3/Active/adr-ios-070.md)** — Active **withdrawal record**, and the disposition record for the whole 058–067 numbering gap. The 58-commit post-`v1.6.38` intention/identity line (`07a4bb703` → `v2final` `e28dd4edb`) **never shipped to a user device**, so it is **WITHDRAWN, not superseded**: ADR-IOS-058 (intention journal), ADR-IOS-060's identity half (its FIFO half is re-derived from ADR-IOS-003/018), ADR-IOS-063, and the epoch clause of ADR-IOS-065. ⚠ **ADR-IOS-061 is withdrawn EXCEPT TWO SURVIVING CARVE-OUTS — the purge-and-resync reaction to a UIDVALIDITY change, and the invariant-test layer**; a reader who finds only 061 or only 070 will draw the wrong conclusion, so read both. ADR-IOS-059, 066 and 067 are **ported, not withdrawn** (into 068, 072 and 069). **ADR-IOS-057 is RE-ACTIVATED**, resolving its orphaned supersession. Applied migrations are never removed; v3's chain resumes at `v68`, contiguous. 🚨 **§5: `ADR-IOS-062` was NEVER an ADR** — it appears in no `DECISIONS.md` at either tag, has no detail file, exists only in an untracked DRAFT, and **the number is unused; do not cite it** (the principle people reach for when they cite it is **ADR-IOS-068** — native provider id is the durable action key).
- **[ADR-IOS-071](Companion/Decisions/V3/Active/adr-ios-071.md)** — Active. **No backward compatibility for the action queue**: no payload decoding, no shape migration, no legacy slot handling, no provider/runtime-mismatch fence. The one-time migration is a **blanket, predicate-free purge** — `DELETE FROM pendingOperation`, immutable migration **`v74_purgeLegacyPendingOperations`** — removing every legacy row regardless of type, status, decodability or shape, including `.saveDraft` and `.deleteDraft`. The **C6 boundary, do not over-apply this**: Outbox / pending sends, drafts and user-authored content (identity, body, recipients, attachments), and bodies / attachments / FTS content are **never** dropped — never-drop applies to them in full. No transitional RFC-only bypass; the admission gates and the native direct producers co-land as one candidate. Accepted one-time upgrade loss `IOS-ACTION-001`.
- **[ADR-IOS-072](Companion/Decisions/V3/Active/adr-ios-072.md)** — Active. **Content is addressed by the message it belongs to, never by the slot it occupies** — the port of the unreleased ADR-IOS-066 **as NEW work**, and the content side of ADR-IOS-068 §7's two keying schemes. `headerId` is a mutable address, so after a UIDVALIDITY turnover the new occupant of a UID inherits the old occupant's indexed subject, sender, body and embedding, and `INSERT OR IGNORE` makes it permanently uncorrectable. ⚠ **THE PRESERVE RULE, owner-mandated and quoted verbatim: "a NULL identity stamp means RE-FETCH, NEVER DESTROY — only a positive mismatch clears anything"** — the reference guarded this write with a read rule and **unrecoverably wiped the FTS body of every pre-upgrade row**. Also: a purge must fail closed when two folder relations disagree (the reference's unconditional delete is the **mirror image** of the bug it fixes); on a rekey collision the richer entry wins and **the self-rekey guard is load-bearing**; body-asset writes hold a two-phase `prepare`/`publish` lease that fails CLOSED; unreadable user content throws and stays visible; draft eviction orders by a strictly increasing per-save counter (migration `v79`), never a wall clock. Evidence `c4fedffcb` / `03565766f` / `b686431f5`.
