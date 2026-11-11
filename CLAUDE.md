# TabMail iOS - Claude Code Rules

> **STOP. Before answering, I must follow the root `../CLAUDE.md` § Companion Routing: load the ALWAYS-LOADED set in full, then `rg -ni` the SEARCH-ONLY indexes and `Companion/` trees for the task's terms and read every hit in full. I must update the routed document when I discover durable knowledge. This is mandatory for every task, every time — no exceptions.**

## Companion Files

**Loading rule lives in the root `../CLAUDE.md` § Companion Routing (owner 2026-09-09).** ALWAYS LOADED in full: `../CLAUDE.md`, `../PROJECT_STRUCTURE.md`, this file, and this project's `PROJECT_STRUCTURE.md`. SEARCH-ONLY (`rg -ni`, read every hit in full, never read whole): the `PROJECT_MEMORY.md` and `DECISIONS.md` indexes at root and here, and every `Companion/` tree. Update the routed detail plus its index line when you learn something durable.

**Global (parent directory):**
- **`../CLAUDE.md`** — Global rules that apply to all subprojects.
- **`../PROJECT_STRUCTURE.md`** — Monorepo layout, tech stack, component relationships.
- **`../PROJECT_MEMORY.md`** — Cross-cutting knowledge and workflows.
- **`../DECISIONS.md`** — Cross-cutting architectural decisions.

**This project:**
- **`PROJECT_STRUCTURE.md`** — Directory tree, entry points, sub-component map.
- **`PROJECT_MEMORY.md`** — iOS-specific knowledge, patterns, quirks.
- **`DECISIONS.md`** — iOS-specific architectural decisions.
- The mistakes log is archived at `Companion/Archive/` (`MISTAKES.md`, `Mistakes/`): not loaded, searched only by hand. A mistake worth preventing becomes a hook, a test, or a one-line rule.

**⚠️ `KNOWN_ISSUES.md` is a generated dashboard, NOT the register.** Search `Companion/Process/Current/KnownIssues/`; never infer completeness or hand-edit it. [Full routing rule](Companion/Process/Current/known-issues-dashboard-routing-rule.md).

**Search the indexes before every task; read every hit in full. Update them when you discover something new.**

**Preserved pre-compaction startup protocols, byte-for-byte:** [preamble](Companion/Process/History/000-pre-compaction-preamble.md) · [index-plus-search routing protocol](Companion/Process/History/001-pre-compaction-routing.md) · [original full-ingestion protocol at `0bcc851`](Companion/Process/History/002-original-full-ingestion-protocol-at-0bcc851.md).

---

## Development Rules

**Keywords:** SwiftUI + GRDB (`AppDatabase.swift` owns migrations and the `DatabasePool`); all code in Swift; **XcodeGen** — `project.yml` is the source of truth and `TabMail.xcodeproj/project.pbxproj` + shared schemes are gitignored, so run **`./Scripts/xcodegen.sh`** (never a bare `xcodegen generate`) after clone or any `project.yml` change, because the wrapper exports `DEVELOPMENT_TEAM` from the gitignored signing config and without it every target — especially the NSE `TabMailNotificationService` — gets a literal `"${DEVELOPMENT_TEAM}"`, an invalid profile the device rejects, and silently dead smart push; OAuth client IDs and API keys live in the gitignored signing/secrets config loaded via `project.yml` configFiles → `Info.plist` → runtime; IMAP/SMTP only through the pinned SwiftMail fork, no other library; modularize past ~500 lines; reuse before reimplementing; and the **sole build-warning exception** — the exact benign `Metadata extraction skipped. No AppIntents.framework dependency found.` diagnostic from `ExtractAppIntentsMetadata` (Xcode 27 words it `Metadata extraction skipped, no AppIntents.framework dependency found`; owner 2026-10-02, both wordings and no other), which must still be counted and reported on every build gate and must NEVER be widened to a different diagnostic, different wording, another target's metadata warnings, or a target that *does* link AppIntents.framework.

> Full current text, byte-for-byte: [Companion/Rules/Active/development-rules-current.md](Companion/Rules/Active/development-rules-current.md). Pre-compaction snapshot of this section at `0bcc851`: [Companion/Rules/Active/development-rules.md](Companion/Rules/Active/development-rules.md).

---

## Core Philosophy: Never Drop User Intention

**Current amendment:** ordinary message-action provider failures have a bounded fifth runtime exit; the normative rule `Companion/Rules/Active/never-drop-user-intention.md` (linked in item 1 below) defines the exact cap, exclusions and commit-before-effects requirement. The earlier enumeration below is historical.

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

> **"Never permanently deletes" is true of MAIL, not of DRAFTS OR CALENDAR EVENTS.** There are **eight**
> irreversible wire operations: (1) the `COPYUID`-gated source expunge; (2) `IMAPProvider.deleteDraftStrong`;
> (3) `saveDraft`'s old-copy replacement; (4) Gmail `DELETE /drafts/{id}`; (5) `CalDAVProvider.deleteEvent`;
> (6) `CalDAVProvider.splitSeries`' cap `PUT`; (7) `ExchangeProvider.replaceDraftAttachments`' attachment
> `DELETE`; (8) the CalDAV one-occurrence delete's `EXDATE` `PUT` (`deleteOccurrence`, #661). Membership is a PROPERTY (server content gone with no documented per-item recovery), not the verb
> `DELETE`; do not restate the count without re-running its predicate. A fail-closed argument that leans on
> "nothing is ever destroyed" is invalid for drafts and CalDAV events. Full text, exclusions and the census greps:
> [`seven-irreversible-wire-operations-inline-text.md`](Companion/Rules/Active/seven-irreversible-wire-operations-inline-text.md).
> Detail and evidence: [`Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md`](Companion/Memory/Current/102-there-are-four-irreversible-wire-operations-not-one.md)
> (filename preserved; its count is now eight).

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

**The problem is fixed; do not re-derive it or design around it.** The drain re-keys the row to the
destination UID and epoch from the `COPYUID` in hand (`MessageHeaderRekey.finishMove`); undo is an ordinary
reverse move (`AccountManager.undoMove`); no `SEARCH` selects a mutation target (ADR-IOS-068). Before
designing a receipt, alias table or outcome enum, ask whether the wire already handed you the answer. Status
and lesson in full: [`address-problem-solved-status-and-lesson.md`](Companion/Rules/Active/address-problem-solved-status-and-lesson.md).

> Full text, byte-for-byte: [Companion/Memory/Current/111-the-address-problem-root-cause-behind-most-action-queue-complexity.md](Companion/Memory/Current/111-the-address-problem-root-cause-behind-most-action-queue-complexity.md).

---

## Data Integrity Rules — ABSOLUTE

1. **NEVER mark unfetched content as fetched** — If a body/attachment/metadata fetch fails or returns empty, the record MUST stay in "not fetched" state (e.g. `hasBody=0`). NEVER write placeholder/sentinel values (`body=" "`, empty strings, etc.) to trick the system into thinking content was fetched. The ONLY exception is a **verified permanent server error** (HTTP 404/410 — content confirmed gone). Marking unfetched content as fetched **hides bugs and drops user messages**.
2. **Retry mechanisms must not mask failures** — Skip-offset and stall mechanisms exist to avoid infinite loops on permanently failing messages, but they must NEVER discard or mark content as complete. The message stays retryable.
3. **If headers exist, bodies should eventually be fetchable** — If an IMAP FETCH returns no data for a UID that we have a header for, that's a bug to investigate (connection died, UID renumbered, etc.), NOT a case to paper over.
4. **NEVER use a DATE window/cursor for IMAP sync — UID and message-date are DECORRELATED (ADR-IOS-042).** This caused real, multi-month Archive DATA LOSS that required a forced re-sync of affected users (commit `4145d2a`, migration `v59`). IMAP `fetchMessages(limit:)` returns the **highest UIDs**, and a UID is **archive-time**, not message-date: archiving one OLD-dated email gives it a fresh HIGH UID. So a date-based stale-detection "overlap window" drags its floor back to that old date and sweeps in **months of mid-range Archive mail the fetch never returned → deletes them** (searchable-but-unopenable orphans; multi-month gaps). The RULE: any SYNC query that decides **what to fetch, keep, delete, or where the cursor/floor sits** for an IMAP folder MUST window by **UID** (`CAST(messageId AS INTEGER)` — `messageId` is the UID), NEVER by `date`. The single source of truth is `SyncEngine.selectStaleHeaders` gated on `provider.staleWindowMode` (`.uid` for IMAP, `.date` for Gmail/Exchange) — do not bypass it or add a parallel date-based sync path. **DISPLAY ordering is exempt** (the inbox/folder list orders by `date` for human reading, and the `messageHeader_folderId[_isRead]_date` composite indexes accelerate THAT — display only). The distinction is: *display* may use date; *sync/stale/cursor decisions* on IMAP must use UID.
5. **A registered migration is IMMUTABLE the moment ANY database has run it — including your own simulator. "Uncommitted" ≠ "unapplied".** GRDB records applied state by the migration's NAME, per database. So a migration that is still uncommitted has nonetheless already run on every dev simulator/device that launched the branch, and from that point BOTH of these are broken:
   Never append to or rename an applied migration; every later schema change gets its own new `vNN`. Diff review cannot catch this: check `grdb_migrations` on a real simulator database. Failure modes, the launch crash and the exact check: [`migration-immutability-failure-modes.md`](Companion/Rules/Active/migration-immutability-failure-modes.md).

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Rules/Active/data-integrity.md](Companion/Rules/Active/data-integrity.md).

---

## Routed Operational Rules

Search the keywords in every row and read each matched rule in full. The exact former startup block
is preserved in [the 2026-08-13 routed snapshot](Companion/Process/Current/mandatory-operational-rules-startup-snapshot-2026-08-13.md).

| Keywords | Mandatory rule |
|---|---|
| audit, review, plan, vet, agent, delegation, supervision, stall, exact diff, shipped release, secret | [Current audit/review/supervision rules](Companion/Process/Current/audit-review-and-agent-supervision-rules.md) and [predecessor workflow](Companion/Process/Current/audit-workflow.md) |
| resilience, main thread, connection loss, idempotency, `Mutex`, isolation | [Resilience](Companion/Rules/Active/resilience.md) |
| Outbox, SMTP, send, `sentAt`, retry, discard, double-send | [Outbox reliability](Companion/Rules/Active/outbox-reliability.md) |
| AI, summary, action, reply, Thunderbird parity, LLM queue | [AI processing](Companion/Rules/Active/ai-processing.md) |
| SwiftUI, `@Observable`, array mutation, `ForEach`, pagination | [SwiftUI mutation safety](Companion/Rules/Active/swiftui-mutation-safety.md) |
| swipe, tap, animation, interaction freeze, deferred updates, snippets | [User interaction freeze](Companion/Rules/Active/user-interaction-freeze.md) |
| keyboard, text input, tap outside, scroll dismissal | [Keyboard dismissal](Companion/Rules/Active/keyboard-dismiss.md) |

---

## Other notes

1. Multiple agents might be running on the code base, so build may fail due to places irrelevant to your edits.

> Pre-compaction snapshot of this section at `0bcc851`, preserved byte-for-byte: [Companion/Process/Current/other-notes.md](Companion/Process/Current/other-notes.md).
