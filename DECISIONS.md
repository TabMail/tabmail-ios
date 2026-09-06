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
| ADR-IOS-029 | Active; rule 5 TIMING amended 2026-08-05, requirement unchanged | Database Index Management — Purpose-Built Indexes, Drop What's Superseded. `ANALYZE` moved OFF migration bodies to `SyncEngine.runRefreshPlannerStatisticsIfStale`, re-armed by `PRAGMA schema_version`, run from background WAL maintenance | [read in full](Companion/Decisions/Active/adr-ios-029.md) |
| ADR-IOS-030 | Active compose FIFO; delivery amended by 053 | Agent Compose Tool FIFO Queue | [read in full](Companion/Decisions/Active/adr-ios-030.md) |
| ADR-IOS-031 | Active | Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`) | [read in full](Companion/Decisions/Active/adr-ios-031.md) |
| ADR-IOS-032 | Partially superseded by 034; Swift stack retained, session-document model replaced | Memory Search Reuses iOS Swift Hybrid FTS Stack (No Rust FFI) | [read in full](Companion/Decisions/Active/adr-ios-032.md) |
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

# v3 records (ADR-IOS-068 … 076)

> **Numbering note.** This file jumps from ADR-IOS-057 to ADR-IOS-068. That gap is deliberate and is
> itself a record: **ADR-IOS-058, 059, 060, 061, 062, 063, 064, 065, 066 and 067 were authored on a
> line that never shipped to a user device.** They are not missing and must not be re-created here.
> **ADR-IOS-070 is their disposition record** — read it before concluding that any of those numbers
> is available, unrecorded, or lost. `v2final` (`e28dd4edb`) holds their bodies and remains readable
> with `git show v2final:Companion/Decisions/…`; that branch is preserved precisely so this history
> stays searchable.

- **[ADR-IOS-068](Companion/Decisions/V3/Active/adr-ios-068.md)** — Active. Durable message actions use the native provider id; Message-ID remains correlation only. Defines the action/content authority split and its exemptions.
- **[ADR-IOS-069](Companion/Decisions/V3/Active/adr-ios-069.md)** — Active. A provider address-space reset drops only affected queued actions; it never rebinds them heuristically.
- **[ADR-IOS-070](Companion/Decisions/V3/Active/adr-ios-070.md)** — Active withdrawal/disposition record for ADR-IOS-058…067. Preserves ADR-IOS-061's reset reaction + invariant tests, ports 059/066/067, reactivates 057, and records that 062 was never an ADR.
- **[ADR-IOS-071](Companion/Decisions/V3/Active/adr-ios-071.md)** — Active. No backward compatibility for the action queue: migration v74 purged it predicate-free, and **as of the 2026-09-06 owner-approved amendment the purge is a STANDING APP-RELEASE BOUNDARY, not one-time** — `AppDatabase.retirePreviousReleaseActionQueue` deletes every `pendingOperation` row without decoding it, marks every account full-sync-due and records the release in `appReleaseStamp` (migration `v89`), in ONE transaction inside `AppDatabase.init` before the pool is published; an unchanged release does not purge. Lifecycle carve-out, not a fifth exit (`never-drop-user-intention.md`); cost registered as `IOS-ACTION-003`. Authored drafts/outbox/content remain never-drop.
- **[ADR-IOS-072](Companion/Decisions/V3/Active/adr-ios-072.md)** — Active. Content belongs to message identity, not a mutable slot. A NULL identity stamp means re-fetch, never destroy; positive mismatch and two-phase publish gates own cleanup.
- **[ADR-IOS-073](Companion/Decisions/V3/Active/adr-ios-073.md)** — Active. Atomic `UID MOVE` is a distinct no-fallback route; `UIDPLUS` governs evidence, not eligibility. Missing evidence never authorizes guessing, replay, or stale undo.
- **[ADR-IOS-074](Companion/Decisions/V3/Active/adr-ios-074.md)** — Active. Every attachment ingress joins one snapshot/failure boundary, and compose-agent edits are mutually exclusive with Save, Send, Close and Discard.
- **[ADR-IOS-075](Companion/Decisions/V3/Active/adr-ios-075.md)** — Active. Body processing reports success or confirmed-empty only when the corresponding cache transaction committed; write aborts stay retryable.
- **[ADR-IOS-076](Companion/Decisions/V3/Active/adr-ios-076.md)** — Active. ⚠️ **PARTIALLY IMPLEMENTED.** The message document is untrusted content, enforced at the WebKit boundary: `allowsContentJavaScript = false` + the 12-directive `<meta>` CSP in `EmailHTMLWrapper.contentSecurityPolicy`; a per-load main-frame navigation permit keyed to an unguessable nonce (`RenderNavigationPolicy`, `RenderDocumentURL`, default-deny `decidePolicyFor`, `metaRefreshIsRefusedByTheProductionCoordinator`); an `http`/`https` allowlist before `UIApplication.shared.open` (`RenderLinkPolicy`); Swift-side bridge validation (`RenderBridgeInput`); `.eml` path traversal (`tabmail-asset`, `BodyAssetSchemeHandler`); deferred-image withholding for `hiddenByViewMode`; and a diagnostic-only `imageLoadFailure` census with no banner. ⚠️ **FOUR owner REVERSALS are registered exceptions, not defects** — `dataDetectorTypes` (`IOS-UI-002`), `allowsLinkPreview` (`IOS-UI-003`), the per-view `nonPersistent()` store (`IOS-PRIVACY-001`, T5 OPEN — one cookie jar across every sender), `font-src 'none'` → `https:` (`IOS-PRIVACY-002`); see also `IOS-PRIVACY-003`. P1d (asset-ownership/view-identity binding) is still spec only, and P1c does not stop same-document `location.hash`/`history.pushState`. `WKWebView` exposes no exact `<img>` ATS error or supported per-resource timeout, so no security-specific notice or timing heuristic is shipped. **Do not cite this ADR as evidence that an unshipped decision is closed — re-derive status from `git log`, not from its status paragraph.** Pre-compaction bullet, byte-for-byte: [pre-compaction-index-lines.md](Companion/Decisions/V3/pre-compaction-index-lines.md).
- **[ADR-IOS-077](Companion/Decisions/V3/Active/adr-ios-077.md)** — Active. Hostile attachment filenames are **REJECTED, not reduced** (`c35cfdca2`, net −476): one shared `AttachmentFilename.isSafeFileComponent` predicate, throw before `createDirectory` on save and refuse before the fetch on download, generic `"Unsupported file name"` for all six rules. Reducer + co-edit twin DELETED — all five confirmed defects lived in the *transformation*, none in the classification. ⚠️ **Rejecting at save does NOT make the loaders safe** — `metaBase`/`afterIndexPrefix` stay load-bearing; type-spoof is bounded, not closed; the combining test is `ccc != 0` on NFD, **not** category `Mn`/`Mc`/`Me`. ⚠️ **Consequence 5 retracts the MIGRATION GUARANTEE — there was never a reducer to migrate FROM** (`v1.7.6`/`v1.7.7`/`v1.7.8` write the name verbatim, so legacy on-disk names are RAW sender-authored; stranded set = refused ∩ writable-by-v1.7.8, 3 narrow shapes). `IOS-ATTACH-001` — forward-only by owner verdict: **no migration, rename-on-load or grandfathering path.** Pre-compaction bullet, byte-for-byte: [pre-compaction-index-lines.md](Companion/Decisions/V3/pre-compaction-index-lines.md).
- **[ADR-IOS-078](Companion/Decisions/V3/Active/adr-ios-078.md)** — Active. Newest-100 bounds sync-origin AI processing only; existing summaries always display, while action tags remain Inbox-only. `ActiveAIQueue.recentInboxWindowContains`, `AIJob.windowExempt`, `MIS-IOS-018`, #68. [Prior catalog wording](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md#source-line-150--adr-ios-078)
- **[ADR-IOS-079](Companion/Decisions/V3/Active/adr-ios-079.md)** — Active. Scheduled tasks and `taskCache` are deleted from iOS, remain live on Thunderbird; `[Task]` prose and `disabledReminders` `t:` hashes are retained. [Prior catalog wording](Companion/Decisions/V3/pre-compaction-index-lines-078-079.md#source-line-151--adr-ios-079)
- **[ADR-IOS-081](Companion/Decisions/V3/Active/adr-ios-081.md)** — Active. **Account-scoped ≠ immutable**, and the drain needs the first while a moved address needs the second: `immutableIdAccountIds` → `accountScopedIdAccountIds` admits `.outlook` to account-qualified lanes, and `MessageHeaderRekey.finishMove` re-addresses every non-cancelled same-account queued op naming a proven source id in the SAME transaction that retires the move (`readdressQueuedOperations`). On an account-scoped provider the re-key FOLLOWS THE ROW by `(accountId, messageId)`; G3's folder clause stays byte-identical on IMAP, where it is the C3 guard. Requeues write columns (`PendingOperation.markQueued`), the lane loop re-reads by primary key with NO `?? op` fallback, and `accountScopedIds:` is non-defaulted at EVERY call site (no count — the compiler enumerates them; the "thirteen" this line used to state went stale in a day). Amends ADR-IOS-018 + ADR-IOS-068 §6; supersedes `IOS-QUEUE-008`'s Outlook exclusion (met, not waived — the lane change and the handoff are ONE fix and must never be split). Accepted: the crash window between Graph's 2xx and the retirement commit (owner 2026-09-04; #117 / #116). ⚠️ **AMENDED by ADR-IOS-082** — its "no schema, migration or drain-ordering change" consequence is HISTORICAL (that follow-up landed: `queuePosition`, migration v90, `queuePosition ASC`), and every "lane"/"lane loop" here now means a related CHAIN (`buildLanes` → `buildRelatedChains`), dispatched one operation at a time. `IOS-GRAPH-005`, #114, `MIS-IOS-003` instance 6.
- **[ADR-IOS-082](Companion/Decisions/V3/Active/adr-ios-082.md)** — Active. **The action queue is drained by a GLOBAL SINGLE-OPERATION FIFO EXECUTOR** ordered by a durable `queuePosition` (migration **v90**, `NOT NULL CHECK(queuePosition > 0)`, **no DEFAULT** so an omitting writer FAILS instead of admitting at the head, indexed), allocated after the current maximum in the SAME transaction that admits the row — `PendingOperation` is a `MutablePersistableRecord` for that reason, and `createdAt` is demoted to AGE ONLY, so equal stamps and a backward clock step cannot reorder anything. One owner claims the live front row (`claimFrontierOperation`), executes and commits before claiming again; **the protected-frontier law** stops the walk at an `inFlight` row. Lane DISPATCH is retired, the lane RELATION survives as `buildRelatedChains`/`addressKey` and now scopes a DEFERRAL: a failed attempt moves the whole related chain to the TAIL (`deferRelatedChainToTail`, one attempt per drain), an unclaimable frontier is skipped IN MEMORY (no position change, no retry charge), and unrelated mail on every account keeps draining. One member per attempt is ORDINARY traffic (`MIS-IOS-022`), so a narrowing is STRICT PROGRESS — `.proceed` plus tail movement, N members in ONE drain — guarded by the strict-progress check that routes a report narrowing NOTHING to the ordinary retryable disposition. 🚨 **THE `.proceed` INVARIANT: no arm may return `.proceed` unless the claimed row is provably GONE, provably NARROWED, or provably OWNED by `pendingRequeues`/`pendingRetirements`** — a `try? await retryWrite { deleteOne }` followed by `.proceed` leaves the row `inFlight` and wedges every account's drain for the life of the process (the wedge corollary → a DROPPED intention); the fix is `do`/`catch` + `requeueOrRetain` + `.stopDrain`, and the census is a falsifiable COUNT — SEVEN `.proceed` sites before the fix (3 provably resolved + the 3 arms + the outcome-box default), SIX after, all provably resolved. Deletes `pendingRetirementSuffixes` and `laneDiagnosticSummary`. This is the follow-up ADR-IOS-081 routed to the owner.
