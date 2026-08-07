# TabMail iOS - Claude Code Rules

> **STOP. Before answering, I must read ALL companion files listed below — both global and project-specific. I must also update them when I discover something new. This is mandatory for every task, every time — no exceptions. You MUST always state in your response that you have read the companion files, so you are reminded of this obligation in every answer.**

## Companion Files (READ BEFORE EVERY TASK)

Before starting any task in this project, read these files and update them when you learn something new:

**Global (parent directory):**
- **`../CLAUDE.md`** — Global rules that apply to all subprojects.
- **`../PROJECT_STRUCTURE.md`** — Monorepo layout, tech stack, component relationships.
- **`../PROJECT_MEMORY.md`** — Cross-cutting knowledge and workflows.
- **`../DECISIONS.md`** — Cross-cutting architectural decisions.
- **`../MISTAKES.md`** — Cross-cutting mistakes an agent has actually made here, with the *tell* that precedes each. Detail in `../Companion/Mistakes/`.

**This project:**
- **`PROJECT_STRUCTURE.md`** — Directory tree, entry points, sub-component map.
- **`PROJECT_MEMORY.md`** — iOS-specific knowledge, patterns, quirks.
- **`DECISIONS.md`** — iOS-specific architectural decisions.
- **`MISTAKES.md`** — iOS-specific mistakes (migrations, IMAP sync windows, the action queue, build/test ops). Detail in `Companion/Mistakes/`.

**You MUST read all companion files before every task. Update them when you discover something new.**

**Preserved pre-compaction startup protocols, byte-for-byte:** [preamble](Companion/Process/History/000-pre-compaction-preamble.md) · [index-plus-search routing protocol](Companion/Process/History/001-pre-compaction-routing.md) · [original full-ingestion protocol at `0bcc851`](Companion/Process/History/002-original-full-ingestion-protocol-at-0bcc851.md).

---

## Development Rules

**Keywords:** SwiftUI + GRDB (`AppDatabase.swift` owns migrations and the `DatabasePool`); all code in Swift; **XcodeGen** — `project.yml` is the source of truth and `TabMail.xcodeproj/project.pbxproj` + shared schemes are gitignored, so run **`./Scripts/xcodegen.sh`** (never a bare `xcodegen generate`) after clone or any `project.yml` change, because the wrapper exports `DEVELOPMENT_TEAM` from the gitignored signing config and without it every target — especially the NSE `TabMailNotificationService` — gets a literal `"${DEVELOPMENT_TEAM}"`, an invalid profile the device rejects, and silently dead smart push; OAuth client IDs and API keys live in the gitignored signing/secrets config loaded via `project.yml` configFiles → `Info.plist` → runtime; IMAP/SMTP only through the pinned SwiftMail fork, no other library; modularize past ~500 lines; reuse before reimplementing; and the **sole build-warning exception** — the exact benign `Metadata extraction skipped. No AppIntents.framework dependency found.` diagnostic from `ExtractAppIntentsMetadata`, which must still be counted and reported on every build gate and must NEVER be widened to a different diagnostic, different wording, another target's metadata warnings, or a target that *does* link AppIntents.framework.

> Full current text, byte-for-byte: [Companion/Rules/Active/development-rules-current.md](Companion/Rules/Active/development-rules-current.md). Pre-compaction snapshot of this section at `0bcc851`: [Companion/Rules/Active/development-rules.md](Companion/Rules/Active/development-rules.md).

---

## Core Philosophy: Never Drop User Intention

**This is the single most important principle in the entire codebase. Every system — actions, sends, tags — is built on it.**

User intention is sacred. When a user archives a message, sends an email, or changes a tag, that intention MUST survive any failure — crashes, disconnections, app kills, device reboots. The system achieves this through two complementary queues:

- **PendingOperation** (ADR-IOS-018) — for actions: archive, delete, move, read, flag, tag
- **OutboxMessage** (ADR-IOS-019) — for sends: compose and send email

Both follow the same contract:

1. **Persist before acknowledge.** The user's action is written to GRDB *before* the UI acknowledges success (dismiss, animate away, show confirmation). If persistence fails, the UI shows an error and does NOT dismiss. The database row IS the user's intention — if it exists, we will execute it.
2. **Optimistic UI, deferred execution.** Local state updates immediately (swipe-to-zap, compose dismiss). Remote execution (IMAP command, SMTP send) happens asynchronously via drain loops. The user never waits for a network round-trip.
3. **Survive everything.** Queue entries persist across: app backgrounding, app termination, crashes, device reboots, prolonged offline periods. On next launch/foreground/reconnect, the queue drains automatically.
4. **Remote state wins on conflict.** When sync discovers that the server state contradicts a queued action (e.g., message already deleted by another client), the queued op is silently dropped — server is the source of truth. But the user's *next* action always takes priority over stale server state.
5. **Treat remote actions as user actions.** IMAP tag updates from other TabMail instances (TB addon) are equivalent to local user actions. When consolidating, the most recent action wins — a remote tag change that arrives after a local queue entry overrides it. The queue is not privileged over remote state; both represent user intention from different devices.
6. **Never silently discard.** Failed sends stay visible in Outbox. Durable message actions retry transient failures without a retry cap. Automatic cleanup only happens for provably completed or provably stale operations. The user always has agency to retry or dismiss.

   **A queued operation may leave the queue for exactly FOUR reasons — and no others:** (1) **provider success**; (2) **a provider-authoritative stale/no-op result** — the provider told us the work is already done or no longer applicable; *"we could not determine the answer" is NOT this*: a thrown read, an unresolvable identity, a failed durable write and an **unknown** epoch are all **retryable**, never authoritative, and conflating the two is the single most repeated defect in this codebase's history; (3) **annihilation by a newer inverse user action**, only when the earlier operation was **never attempted**, the members match **exactly**, and the new action is a true inverse; (4) **invalidation by an id reset in its own address space** — a **proven** UIDVALIDITY turnover or provider stable-id reset drops every queued op that named an address in that space, because the drain compares an op against its **durable** `PendingOperation.observedUidValidity`, so once the epoch provably moves every retry of that op fails identically and forever rather than executing under numbering it never observed (**C3**: no action may ever mutate the wrong message; failing closed is always acceptable — `KNOWN_ISSUES.md` `IOS-EPOCH-001` / `IOS-ACTION-002`).

   **Exit 4 does not widen clause 2.** Exit 4 requires a **proven** epoch change — a *positive* fact. Clause 2's *unknown* epoch is an **absence of evidence** and stays retryable forever. The two are disjoint. Exit 4 is the only exit that is a failure, it is deliberately narrow, and **nothing else may use it**. A bounded, visible, retryable quarantine is **not** a discard, and a transient failure is **not** an exit.

   **Normative statement of this invariant: [`Companion/Rules/Active/never-drop-user-intention.md`](Companion/Rules/Active/never-drop-user-intention.md), including its current routing note.** This section is a pointer to it; where they differ, that file wins.

**When in doubt: persist the intention, retry later, show the user what happened.**

See ADR-IOS-001 (optimistic UI), ADR-IOS-003 (crash recovery), ADR-IOS-018 (action queue), ADR-IOS-019 (outbox), ADR-IOS-067 (the three exits) and ADR-IOS-069 (the fourth).

---

## THE MANTRA — read this before designing any fix

> **Owner, 2026-08-03:** *"Implement the core first, iron out the edges later. Simplicity and
> robustness trumps complications for minor rare edge cases. Edge cases still must be recoverable at
> one point via syncing etc — if so, fail closed and let it be."*

**The test is RECOVERABILITY, and it is mechanically checkable. Apply it before writing any mechanism:**

1. If this edge fails closed, does the system reach a correct state later — by a sync pass, a retry,
   or **one ordinary user gesture**?
2. **Yes ⇒ fail closed. Register it in `KNOWN_ISSUES.md` with its reachability and attribution class.
   Move on.** Do not build the mechanism. No new column, receipt, protocol change, or migration.
3. **No ⇒ it is not an edge, it is a defect**, and the non-recoverable set is exactly: C3 wrong-message
   mutation or misattribution (already happened — nothing recovers it); a dropped user intention,
   including the **wedge corollary** (an op that starves forever never recovers via sync); a brick
   (launch crash, migration failure, DB corruption); secret exposure.

**Why fail-closed is usually safe HERE specifically: for MAIL, TabMail never permanently deletes.**
`.delete` is a move to Trash. No bare `server.expunge()` exists in production — every expunge is
UID-scoped. The most load-bearing irreversible operation is **expunging a source copy after a proven
`COPY`**: it removes a duplicate, never a message, which makes the `COPYUID`-gated purge the guard
where being wrong cannot be undone. **Never widen its evidence.** A source copy left
`\Deleted`-but-present is an accepted, recoverable cost; expunging without proof is a wrong-message
deletion.

> **Stated negatively, because this absolute was wrong for two years and walked reviewers past two
> live hazards.** "Never permanently deletes" is true of MAIL, **not of DRAFTS OR CALENDAR EVENTS**,
> and the `COPYUID`-gated purge is **not** the only irreversible wire operation. There are **six**:
> (1) the `COPYUID`-gated source expunge; (2) `IMAPProvider.deleteDraftStrong`; (3) `saveDraft`'s
> old-copy replacement; (4) Gmail's `DELETE /drafts/{id}`, which Google documents as permanent rather
> than a trash; (5) `CalDAVProvider.deleteEvent` — WebDAV `DELETE` on the event's `.ics` resource,
> for which RFC 4918/4791 define **no** trash, undelete or restore (added 2026-08-05; iCloud's
> whole-calendar snapshot rollback is not a per-item recovery and does not exempt it). The draft
> family **destroys a draft outright** rather than moving it to Trash.
> Further scope: (2) and (3) are irreversible only under UIDPLUS — without it `expungeScopedToTargets`
> issues nothing; Gmail's `.gmailContainedMessage` arm trashes rather than destroys; and
> `ExchangeProvider.deleteDraft`, `ExchangeCalendarProvider.deleteEvent` and
> `GoogleCalendarProvider.deleteEvent` are excluded on **positive** documented per-item recovery
> (Graph Recoverable Items; Google Calendar's 30-day event trash), not on the absence of evidence.
> **(6) is not a DELETE at all: `CalDAVProvider.splitSeries`' cap `PUT`** replaces the master `.ics`
> with an `UNTIL=`-capped `RRULE`, destroying every occurrence after the split point, under a
> best-effort compensating rollback rather than a transaction.
> **⚠ Membership is defined by a PROPERTY — content that existed on the server no longer does, with
> no documented per-item recovery the call reaches — NOT by the verb `DELETE`. Do not restate this
> integer without re-running its predicate.** The greps are a **LOWER BOUND**, not the definition:
> five `--multiline` searches over `TabMail/ Shared/ TabMailNotificationService/` —
> `method\s*:\s*"DELETE"`, `httpMethod\s*=\s*"DELETE"`, `expunge\(`, plus the REPLACEMENT axis
> `httpMethod\s*=\s*"PUT"` and `method\s*:\s*"PUT"` — because **both** HTTP spellings occur, and the
> count was "four" for a day precisely because the earlier census saw only the first (`MIS-007`).
> **It is wrong the moment** a further spelling appears (a computed/enum HTTP verb, or deletion
> tunnelled through `POST` like Gmail `batchDelete` or Graph `permanentDelete`), a non-HTTP/non-IMAP
> destructive surface is added, an excluded call loses its documented recovery, or
> `GoogleCalendarProvider` gains a *this-and-following* series delete.
> **Consequence for design:** a fail-closed argument that leans on "nothing is ever destroyed" is
> valid for mail and invalid for drafts and CalDAV events — for those paths, say why the specific
> loss is acceptable.
> Detail and evidence: [`Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md`](Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md)
> (filename preserved; its count is now six).

**Check "rare" before invoking this.** An edge that is actually the common path is not an edge.
"Undo of an already-drained move" *sounds* rare, but the drain fires immediately after the gesture, so
for an online user it may be the majority case. Frequency first, then the mantra.

---

## THE ADDRESS PROBLEM — SOLVED in v1.7.0; keep the invariant, not the alarm

**Read this whenever a task touches the action queue, moves, undo, or IMAP identity.** The durable
invariant, which has not changed: a `PendingOperation` addresses its members in the **source**
folder, on IMAP an address is `(folder, UID, UIDVALIDITY)`, and therefore **a move changes the
address**. Anything recorded against the source after a move has landed either can never be admitted
again (a dropped intention) or names whatever now occupies that UID (**C3** wrong-message mutation).
That is why a composed read-then-move records the read **strictly before** the move, inside the same
queued closure.

**The problem itself is fixed — do not re-derive it, and do not design around it as if it were still
open.** `copyProvenSourceUIDs` now returns `destinationProviderId` / `destinationUidValidity`, and
`MessageHeaderRekey.finishMove` re-keys the row to the destination UID and epoch at drain time from
the `COPYUID` already in hand. Undo is an ordinary reverse move (`AccountManager.undoMove`), not a
rollback and not a Message-ID `SEARCH`; the two surviving `searchByMessageId` callers (`currentUIDs`,
`appendToSentFolder`) are both **non-mutating**, so the banned D4 direction — a SEARCH selecting a
mutation target (ADR-IOS-068, `IOS-IMAP-002`) — no longer exists in the tree.

**The lesson worth keeping:** four audit rounds argued about *which evidence retires an operation*
when the real defect was decision **granularity** — the wire had already proved the destination
address and the code threw it away. Before designing a receipt, alias table, two-door identity scheme
or outcome enum, ask first whether the wire already handed you the answer.

> Full text, byte-for-byte: [Companion/Memory/Current/111-the-address-problem-root-cause-behind-most-action-queue-complexity.md](Companion/Memory/Current/111-the-address-problem-root-cause-behind-most-action-queue-complexity.md).

---

## Data Integrity Rules — ABSOLUTE

1. **NEVER mark unfetched content as fetched** — If a body/attachment/metadata fetch fails or returns empty, the record MUST stay in "not fetched" state (e.g. `hasBody=0`). NEVER write placeholder/sentinel values (`body=" "`, empty strings, etc.) to trick the system into thinking content was fetched. The ONLY exception is a **verified permanent server error** (HTTP 404/410 — content confirmed gone). Marking unfetched content as fetched **hides bugs and drops user messages**.
2. **Retry mechanisms must not mask failures** — Skip-offset and stall mechanisms exist to avoid infinite loops on permanently failing messages, but they must NEVER discard or mark content as complete. The message stays retryable.
3. **If headers exist, bodies should eventually be fetchable** — If an IMAP FETCH returns no data for a UID that we have a header for, that's a bug to investigate (connection died, UID renumbered, etc.), NOT a case to paper over.
4. **NEVER use a DATE window/cursor for IMAP sync — UID and message-date are DECORRELATED (ADR-IOS-042).** This caused real, multi-month Archive DATA LOSS that required a forced re-sync of affected users (commit `4145d2a`, migration `v59`). IMAP `fetchMessages(limit:)` returns the **highest UIDs**, and a UID is **archive-time**, not message-date: archiving one OLD-dated email gives it a fresh HIGH UID. So a date-based stale-detection "overlap window" drags its floor back to that old date and sweeps in **months of mid-range Archive mail the fetch never returned → deletes them** (searchable-but-unopenable orphans; multi-month gaps). The RULE: any SYNC query that decides **what to fetch, keep, delete, or where the cursor/floor sits** for an IMAP folder MUST window by **UID** (`CAST(messageId AS INTEGER)` — `messageId` is the UID), NEVER by `date`. The single source of truth is `SyncEngine.selectStaleHeaders` gated on `provider.staleWindowMode` (`.uid` for IMAP, `.date` for Gmail/Exchange) — do not bypass it or add a parallel date-based sync path. **DISPLAY ordering is exempt** (the inbox/folder list orders by `date` for human reading, and the `messageHeader_folderId[_isRead]_date` composite indexes accelerate THAT — display only). The distinction is: *display* may use date; *sync/stale/cursor decisions* on IMAP must use UID.
5. **A registered migration is IMMUTABLE the moment ANY database has run it — including your own simulator. "Uncommitted" ≠ "unapplied".** GRDB records applied state by the migration's NAME, per database. So a migration that is still uncommitted has nonetheless already run on every dev simulator/device that launched the branch, and from that point BOTH of these are broken:
   - **Appending to an applied migration's body** — the new statements NEVER execute on any DB that already ran it. The column silently does not exist while the code assumes it does.
   - **Renaming it to cover the additions** — GRDB reads the new name as a brand-new migration and re-runs the WHOLE body, which fails on the columns that already exist (`duplicate column name: …`). `AppDatabase` init throws, `shared` stays nil, and `AppDatabase.rawPool`'s force-unwrap **crashes the app at launch before any UI appears**.

   Both were done to one migration on the abandoned post-`v1.6.38` line (2026-07-25) and produced exactly that launch crash. The RULE: once a migration has been run anywhere, freeze its name AND its body; every subsequent schema change gets its own new `vNN`. A fresh install (run vNN then vNN+1) and an existing DB (skip vNN, run vNN+1) must converge on the same schema — state that convergence in a comment when you split.
   **Diff review CANNOT catch this** — the defect lives in the divergence between the diff and already-applied DB state. Verify against reality instead: `sqlite3 "<simulator>/Library/Application Support/TabMail/tabmail.sqlite" "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 5;"` and `PRAGMA table_info(<table>);`.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/data-integrity.md](Companion/Rules/Active/data-integrity.md).

---

## Audit, Review, and Agent-Supervision Rules

> Roles are model-agnostic (global `../CLAUDE.md` § *Common Cross-Model Workflow*): whichever model owns the main session coordinates; the other is the independent read-only vetter.
>
> **A1–A13 in full, byte-for-byte: [Companion/Process/Current/audit-review-and-agent-supervision-rules.md](Companion/Process/Current/audit-review-and-agent-supervision-rules.md) — read it before planning, vetting, reviewing, delegating, or supervising.** Predecessor workflow snapshot at `0bcc851`: [Companion/Process/Current/audit-workflow.md](Companion/Process/Current/audit-workflow.md).

- **A1 — SEARCH THE PREVIOUS RELEASE FIRST:** `git show <release-tag>:<path>` on the code that OWNS the problem; author only if shipped is inapplicable or nonexistent. Every plan opens with "SHIPPED BEHAVIOUR" quoting the owning function's SEQUENCE; the vet re-checks it independently. Shipped is a floor, not a ceiling.
- **A2 — a SPIRALLING design (3+ vet rounds still returning blockers) ⇒ both models stop and re-read the last shipped release.** Complexity past shipped code carries a burden of proof.
- **A3 — COMPENSATING-MECHANISM deviation, caught at design time:** a mechanism restoring or re-deriving state a **sibling path** destroyed eagerly ⇒ the bug is the sibling's TIMING, not the missing mechanism.
- **A4 — the exact-diff review runs on the EXACT COMMIT CANDIDATE**, re-run after every fix round; one signed commit per green logical round. Fix rounds are where NEW risk enters.
- **A5 — commit bodies need EXECUTIVE SUMMARIES** (global `../CLAUDE.md` Git rule 5); review isolated commits or ranges, never a mixed working-tree pile.
- **A6 — DATABASE-PERFORMANCE audit lens (mandatory)** on any query/transaction/schema/index change: query census, bounded cardinality, `EXPLAIN QUERY PLAN` on the current schema, N+1/full-scan/hot-path risk, write hold time and QoS/UI contention, justified migrations and indexes.
- **A7 — ask "INSTANCE OR CLASS?"** and enumerate the class mechanically; a defect confirmed at one call site is a lead, not a scope.
- **A8 — HARD CAP: FIVE plan-vet rounds** (parallel reviewers on one frozen candidate count as ONE round); then freeze the plan and implement with red-first invariant tests.
- **A9 — the main session SUPERVISES; it does NOT implement.** Spec, delegate, verify. Exceptions: governance files, and reading code to VERIFY. Implementation subagents run a correctness-capable model at high reasoning. Verifying, not trusting.
- **A10 — ONE confined job per agent; NEVER resume one across review rounds** (192k → 932k tokens, then WEDGED; a fresh narrow agent did the same job in 76k). Continuity lives in the BRIEF: "if you find a bug, STOP and report — do not fix".
- **A11 — STALL DISCIPLINE: check agents EVERY turn** (transcript mtime, a live build process, the last build marker). ACTIVE with no tool calls = wedged, not finished; inversion sweep on any suspected stall; every brief carries a self-stall clause and a DONE / IN PROGRESS / NOT STARTED statement.
- **A12 — not converging ⇒ the REVIEWER AUTHORS the artifact and the COORDINATOR VERIFIES it, then swap back.** Audit-FIX on a confirmed file:line finding is the standing exception; grep every symbol the patch names, and the other model still reviews the result.
- **A13 — SECRETS, ABSOLUTE: NEVER point an external reviewer, agent, or tool at secret-bearing files** — the gitignored iOS signing config, `*.env*`, `*.dev.vars*`, private keys. This is the global `../CLAUDE.md` PRIME DIRECTIVE and it overrides every rule above. `tabmail-ios` is a **public** repo, so app-source egress for review is acceptable; the signing config is not app source.

## Resilience Rules

**Mandatory for all code in this project.** Keywords: NEVER block the main thread (GRDB's `DatabasePool` is concurrent-reader/serialized-writer and WAL keeps reads non-blocking, so no background `DispatchQueue` dance — just don't do expensive computation inside a main-actor write transaction); assume connections drop at any time, so persist history IDs and sync cursors ONLY on verified completion, never optimistically; assume every action can fail mid-operation, so make it idempotent with completion checks and self-healing on next launch or sync; optimistic UI with hardened background sync; use `Mutex` (`import Synchronization`, SE-0433) instead of `nonisolated(unsafe)` or `NSLock`, with `@unchecked Sendable` only on the Mutex-protected inner value or a type wrapping an inherently thread-safe API (e.g. CoreML's `MLModel`).

> Full rule, byte-for-byte: [Companion/Rules/Active/resilience.md](Companion/Rules/Active/resilience.md).

---

## Outbox Reliability Rules

**A dropped send or double-send is a product-ending bug. These rules are non-negotiable.**

1. **Never drop a message** — `queueSend()` throws. The caller (ComposeView) MUST show the error and NOT dismiss. The compose view is the user's last chance.
2. **Never `try?` on outbox state transitions** — Every DB write that changes status (queued→sending, sending→failed, success→delete) uses `do/catch` with 3 retries. Silent swallowing = message loss or double-send.
3. **`sentAt` before delete** — After `provider.send()` succeeds, stamp `sentAt` FIRST, then delete. Crash between send and delete? `reconcileOutbox` sees `sentAt != nil` → deletes (not re-queues). This is the double-send firewall.
4. **Prefer double-send over drop** — Two-generals problem is inherent. When in doubt, re-queue and retry. Duplicate email >> lost email.
5. **No silent data corruption** — `loadAttachments()` throws if ANY file is unreadable. Never send an email with missing attachments. Mark as failed instead.
6. **File I/O outside DB transactions** — Attachment disk ops outside `dbPool.write`. File failure inside a transaction rolls back the DB too.
7. **No auto-discard, ever** — Outbox messages are NEVER automatically deleted. Failed messages stay visible. User always has agency.
8. **Only drain `.queued`** — `.failed` messages require explicit user Retry. Prevents infinite retry loops and spam.
9. **Auto-retry then escalate** — retryCount < 3 keeps as `queued` (auto-retry). retryCount >= 3 marks `failed` (user action). Manual Retry resets retryCount to 0.
10. **Discard guard** — Cannot discard a `sending` message. The email may have already left the server.

See **ADR-IOS-019** in `DECISIONS.md` for full architectural context.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/outbox-reliability.md](Companion/Rules/Active/outbox-reliability.md).

---

## AI Processing Rules

**MANDATORY: All AI processing (summary, action, reply) must exactly replicate the Thunderbird addon's architecture (ADR-IOS-008).**

- The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the **authoritative reference implementations**.
- Before implementing or modifying any AI flow, **read the TB reference code first** to ensure 1:1 parity.
- Key patterns that MUST be replicated: persistent processing queue, event-driven enqueue, drain loop with watchdog timer, per-message semaphores, global LLM concurrency limit, caching with TTL, first-compute-wins, three-call action voting.
- Do NOT invent new AI processing patterns. Adapt TB's patterns to Swift/iOS idioms, but preserve the same architecture.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/ai-processing.md](Companion/Rules/Active/ai-processing.md).

---

## SwiftUI Mutation Safety Rules

1. **NEVER remove items from an `@Observable` array synchronously during `onAppear`/`onDisappear`** when that array feeds the same `ForEach`. SwiftUI is mid-layout and will crash. Defer removals to the next run loop: `Task { @MainActor in ... }`.
2. **Appending is safe** from lifecycle callbacks — new items don't invalidate existing layout.
3. **User action handlers** (button, swipe, gesture) are safe for both append and remove.
4. **When evicting from paginated arrays**, keep evicted IDs in the dedup set to prevent re-fetch loops. Reset the set only on full reload.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/swiftui-mutation-safety.md](Companion/Rules/Active/swiftui-mutation-safety.md).

---

## User Interaction Freeze Rule

**While the user is interacting (swiping, tapping, any animation in-flight), NO background update may mutate `@Observable` state that feeds the visible view — a fundamental UX rule, no exceptions.** Keywords: defer `backgroundDataDidChange`, AI updates, snippet loading and sync completions; bracket every swipe action handler, button tap and gesture callback with `InboxViewModel.beginInteraction()` / `endInteraction()`; `endInteraction()` starts a 200ms cooldown, after which deferred updates flush in ONE batch (pending reloads outrank individual snapshot refreshes); snippet loading applies its batch in a single synchronous loop — one `@Observable` mutation, one re-render, not N. Rationale: the user acts on the *visualized* state.

> Full rule, byte-for-byte: [Companion/Rules/Active/user-interaction-freeze.md](Companion/Rules/Active/user-interaction-freeze.md).

---

## Keyboard Dismiss Rule

**Tapping anywhere outside the keyboard MUST dismiss the keyboard. This is a fundamental UX design rule — no exceptions.**

- Every screen with text input MUST apply `.dismissKeyboardOnTap()` (defined in `KeyboardDismiss.swift`) on its root container.
- ScrollViews with text input should also use `.scrollDismissesKeyboard(.interactively)`.
- The keyboard reappears naturally when the user taps a text field — no special handling needed.
- Do NOT add manual keyboard dismiss buttons (toolbar chevrons, floating buttons, etc.). The tap-outside gesture handles everything.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/keyboard-dismiss.md](Companion/Rules/Active/keyboard-dismiss.md).

---

## Other notes

1. Multiple agents might be running on the code base, so build may fail due to places irrelevant to your edits.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Process/Current/other-notes.md](Companion/Process/Current/other-notes.md).
