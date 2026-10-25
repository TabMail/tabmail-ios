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

**Current amendment:** ordinary message-action provider failures have a bounded fifth runtime exit; the [normative rule](Companion/Rules/Active/never-drop-user-intention.md) defines the exact cap, exclusions and commit-before-effects requirement. The earlier enumeration below is historical.

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
| ADR-IOS-029 | Active; rule 5 TIMING amended 2026-08-05, requirement unchanged | Database Index Management — Purpose-Built Indexes, Drop What's Superseded. `ANALYZE` moved OFF migration bodies to `SyncEngine.runRefreshPlannerStatisticsIfStale`, re-armed by `PRAGMA schema_version`, run from background WAL maintenance | [read in full](Companion/Decisions/Active/adr-ios-029.md) |
| ADR-IOS-030 | Active compose FIFO; delivery amended by 053 | Agent Compose Tool FIFO Queue | [read in full](Companion/Decisions/Active/adr-ios-030.md) |
| ADR-IOS-031 | Active | Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`) | [read in full](Companion/Decisions/Active/adr-ios-031.md) |
| ADR-IOS-032 | Partially superseded by 034; Swift stack retained, session-document model replaced; amended 2026-10-21: empty merge with keyword matches answers keyword-only (#240, native-fts #28); amended 2026-10-22: vector search only within the dates and the field via sqlite-vec `rowid IN` (#242, native-fts #26); amended 2026-10-23: memory merge ties newer first (#265, ADR-IOS-094); amended 2026-10-24: every keyword match is a result, minScore gates meaning-only candidates, empty-merge fallback deleted (#304, native-fts #51) | Memory Search Reuses iOS Swift Hybrid FTS Stack (No Rust FFI) | [read in full](Companion/Decisions/Active/adr-ios-032.md) |
| ADR-IOS-034 | Active | Memory Index Moves to Per-Turn Granularity (Supersedes v2 Session-Document Model) | [read in full](Companion/Decisions/Active/adr-ios-034.md) |
| ADR-IOS-036 | Active | Action Tags Are Local-Only (Supersedes ADR-IOS-004) | [read in full](Companion/Decisions/Active/adr-ios-036.md) |
| ADR-IOS-037 | Active | NSE/Main-App AI Ownership Lease (Cross-Process Coordination) | [read in full](Companion/Decisions/Active/adr-ios-037.md) |
| ADR-IOS-038 | Active | Demo Mode — Custom JWT + Local Mock Provider + Pre-Baked AI Cache | [read in full](Companion/Decisions/Active/adr-ios-038.md) |
| ADR-IOS-039 | Active | Idempotent HTML Render Fit + Scroll-Phase Height Freeze | [read in full](Companion/Decisions/Active/adr-ios-039.md) |
| ADR-IOS-040 | Active; point 4 (intro-offer trial gating: `checkTrialEligibility`, PlanCard trial badge) deleted 2026-08-19 with issue #55 — ASC offers removed, server signup trial is the only trial | Zero (BYOK) Plan in the IAP Plan Picker — Three-Tier, Display-Only Naming | [read in full](Companion/Decisions/Active/adr-ios-040.md) |
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

These ADR bodies exist only on the mature pre-v3 line, so they are not in `v1.6.38:DECISIONS.md`; preserved byte-for-byte with provenance in [`Companion/Decisions/ported-manifest.tsv`](Companion/Decisions/ported-manifest.tsv) and excluded from the reconstruction census.

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

Authored after `v1.6.38`, so they have no byte-identical twin: their bodies live outside `Companion/Decisions/{Active,Superseded,Deferred}/` (the census surface that reconstructs `v1.6.38:DECISIONS.md`), with provenance and `sha256` in [`Companion/Decisions/V3/manifest.tsv`](Companion/Decisions/V3/manifest.tsv). Earlier wording of these lines, byte-for-byte: [`pre-compaction-index-lines.md`](Companion/Decisions/V3/pre-compaction-index-lines.md), [`…-078-079.md`](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md), [`…-2026-09-06.md`](Companion/Decisions/V3/pre-compaction-index-lines-2026-09-06.md), [`…-2026-10-24.md`](Companion/Decisions/V3/pre-compaction-index-lines-2026-10-24.md).

- **[ADR-IOS-026B — the v3 supersession record](Companion/Decisions/V3/Superseded/adr-ios-026b-v3-superseded-by-068.md)** — *PendingOperation Uses Stable IDs (rfc822MessageId)*, SUPERSEDED 2026-08-02 by ADR-IOS-068 in its durable-mutation-authority layer only (068's exempt list is normative); colliding number `ADR-IOS-026`.
- **[Compaction drift list](Companion/Decisions/V3/retained-inline-no-byte-identical-routed-twin.md)** — retired preamble: check the routed twin before editing a post-`v1.6.38` amendment.

# v3 records (ADR-IOS-068 … 076)

> **Numbering note.** The jump from ADR-IOS-057 to ADR-IOS-068 is deliberate: **ADR-IOS-058…067 were
> authored on a line that never shipped to a user device.** They are not missing and must not be
> re-created. **ADR-IOS-070 is their disposition record** — read it before concluding any of those
> numbers is available. `v2final` (`e28dd4edb`) holds their bodies (`git show v2final:Companion/Decisions/…`).

- **[ADR-IOS-068](Companion/Decisions/V3/Active/adr-ios-068.md)** — Active. Durable message actions use the native provider id; Message-ID is correlation only (the action/content authority split and its exemptions).
- **[ADR-IOS-069](Companion/Decisions/V3/Active/adr-ios-069.md)** — Active. A provider address-space reset drops only affected queued actions; it never rebinds them heuristically.
- **[ADR-IOS-070](Companion/Decisions/V3/Active/adr-ios-070.md)** — Active disposition record for ADR-IOS-058…067: keeps 061's reset reaction and tests, ports 059/066/067, reactivates 057; 062 was never an ADR.
- **[ADR-IOS-071](Companion/Decisions/V3/Active/adr-ios-071.md)** — Active. No action-queue backward compatibility: the purge is a standing app-release boundary (`retirePreviousReleaseActionQueue`, `v89`), not a fifth exit.
- **[ADR-IOS-072](Companion/Decisions/V3/Active/adr-ios-072.md)** — Active. Content belongs to message identity, not a slot: a NULL identity stamp means re-fetch, never destroy; mismatch and two-phase publish gates own cleanup.
- **[ADR-IOS-073](Companion/Decisions/V3/Active/adr-ios-073.md)** — Active. Atomic `UID MOVE` is a distinct no-fallback route; `UIDPLUS` governs evidence, not eligibility; missing evidence never authorizes guessing or replay.
- **[ADR-IOS-074](Companion/Decisions/V3/Active/adr-ios-074.md)** — Active. Every attachment ingress joins one snapshot/failure boundary, and compose-agent edits are mutually exclusive with Save, Send, Close and Discard.
- **[ADR-IOS-075](Companion/Decisions/V3/Active/adr-ios-075.md)** — Active. Body processing reports success or confirmed-empty only when the corresponding cache transaction committed; write aborts stay retryable.
- **[ADR-IOS-076](Companion/Decisions/V3/Active/adr-ios-076.md)** — Active, PARTIALLY IMPLEMENTED. The message document is untrusted at the WebKit boundary: no content JavaScript, CSP, `RenderNavigationPolicy`, `BodyAssetSchemeHandler`.
- **[ADR-IOS-077](Companion/Decisions/V3/Active/adr-ios-077.md)** — Active. Hostile attachment filenames are REJECTED, not reduced (`AttachmentFilename.isSafeFileComponent`, `IOS-ATTACH-001`).
- **[ADR-IOS-078](Companion/Decisions/V3/Active/adr-ios-078.md)** — Active. Newest-100 bounds sync-origin AI processing only; existing summaries always display; action tags Inbox-only (`recentInboxWindowContains`).
- **[ADR-IOS-079](Companion/Decisions/V3/Active/adr-ios-079.md)** — Active. Scheduled tasks and `taskCache` deleted from iOS, live on Thunderbird; `[Task]` prose and `disabledReminders` `t:` hashes retained.
- **[ADR-IOS-081](Companion/Decisions/V3/Active/adr-ios-081.md)** — Active. Account-scoped ≠ immutable: Outlook ids are account-qualified and `MessageHeaderRekey.finishMove` re-addresses queued ops (`readdressQueuedOperations`).
- **[ADR-IOS-082](Companion/Decisions/V3/Active/adr-ios-082.md)** — Active. The action queue drains through a GLOBAL SINGLE-OPERATION FIFO EXECUTOR by durable `queuePosition` (`claimFrontierOperation`, `v90`).
- **[ADR-IOS-083](Companion/Decisions/V3/Active/adr-ios-083.md)** — Drafts sources may reach Trash, never Archive/Move; draft deletion and legacy repair stay separate (#133/#135/#136).
- **[ADR-IOS-084](Companion/Decisions/V3/Active/adr-ios-084.md)** — Active. Gmail `internalDate` is not arrival time: display `date` = first `Received:` header; `providerDate` (`v91`) keeps `internalDate` for sync.
- **[ADR-IOS-085](Companion/Decisions/V3/Active/adr-ios-085.md)** — Active. Chat-pill dictation = TabMail Voice's backend speech-to-text + cleanup (`POST /dictation/transcribe`, `DictationController`), not `SFSpeechRecognizer`.
- **[ADR-IOS-086](Companion/Decisions/V3/Active/adr-ios-086.md)** — Active. Dictation dictionary: user words (`DictationDictionary`, LRU) plus context terms up to `vocabularyMaxTerms`, in priority order.
- **[ADR-IOS-087](Companion/Decisions/V3/Active/adr-ios-087.md)** — Active. Long dictations in chunks (Voice ADR-DESK-049): `DictationChunker` forced cuts with overlap, `chunkCutsAtPauses` off, `DictationChunkJoin`.
- **[ADR-IOS-088](Companion/Decisions/V3/Active/adr-ios-088.md)** — Active. PDF attachment text (`attachment_read_pdf`) is read by bundled pdf.js in a hidden `WKWebView` (`PDFTextHost`), not PDFKit; TB parity.
- **[ADR-IOS-089](Companion/Decisions/V3/Active/adr-ios-089.md)** — Active. Device Sync state belongs to one TabMail account (`DeviceSyncService.ownerUserIdKey`, `claimLocalState`); another account resets it.
- **[ADR-IOS-090](Companion/Decisions/V3/Active/adr-ios-090.md)** — Active. `web_read` reads a page as a user agent, without robots.txt (`checkRobotsTxt` deleted); root ADR-033, TB ADR-026.
- **[ADR-IOS-091](Companion/Decisions/V3/Active/adr-ios-091.md)** — Active. Drafts written by other mail apps are adopted on open (#217, last save wins, no lease): `ServerDraftComposeLoader`, `ExternalDraftAdoption`, `adopted:<uuid>`; opens are prepared before the compose shows, no blank frame (#309, `DraftOpenPreparation`, busy row mark).
- **[ADR-IOS-092](Companion/Decisions/V3/Active/adr-ios-092.md)** — Active. Compose recipient fields are address lists, never free text: `RecipientEntry` chips, SwiftMail's address-list parser, every Reply-To, Bcc.
- **[ADR-IOS-093](Companion/Decisions/V3/Active/adr-ios-093.md)** — Active. Search query text reaches FTS5 as text (#246, ADR-NF-011): `SearchQueryParser.buildFTSMatch` quotes every word; fixes `fts5: syntax error`. Amended 2026-10-24 (#301, ADR-NF-019): a kept `NOT` answers by keyword only (`queryExcludes`); the vector filter splits at each `OR`.
- **[ADR-IOS-094](Companion/Decisions/V3/Active/adr-ios-094.md)** — Active. A search sorts before its limit (#265, ADR-NF-017): `SearchSort`, `HybridMerge.mergeResults` ties, `SearchConfig.dateSortPool`. Amended 2026-10-24: the backend reads `TABMAIL_PROTOCOL_VERSION` (now 1.10.0), not the marketing version.
- **[ADR-IOS-095](Companion/Decisions/V3/Active/adr-ios-095.md)** — Active. Every search fetches 100, in pages of 20 where it pages (#264, TB parity): `email_search` `maxResults`, `memorySearchPageSize`.
- **[ADR-IOS-096](Companion/Decisions/V3/Active/adr-ios-096.md)** — Active. Discard drops only unsaved edits (#254): `DiscardScope`, `discardDisposition` keeps a server draft; the cleared-draft Delete deletes it.
