# TabMail iOS - Claude Code Rules

> **STOP. Before answering, I must read ALL companion files listed below — both global and project-specific. I must also update them when I discover something new. This is mandatory for every task, every time — no exceptions. You MUST always state in your response that you have read the companion files, so you are reminded of this obligation in every answer.**

## Companion Files (READ BEFORE EVERY TASK)

Before starting any task in this project, read these files and update them when you learn something new:

**Global (parent directory):**
- **`../CLAUDE.md`** — Global rules that apply to all subprojects.
- **`../PROJECT_STRUCTURE.md`** — Monorepo layout, tech stack, component relationships.
- **`../PROJECT_MEMORY.md`** — Cross-cutting knowledge and workflows.
- **`../DECISIONS.md`** — Cross-cutting architectural decisions.

**This project:**
- **`PROJECT_STRUCTURE.md`** — Directory tree, entry points, sub-component map.
- **`PROJECT_MEMORY.md`** — iOS-specific knowledge, patterns, quirks.
- **`DECISIONS.md`** — iOS-specific architectural decisions.

**You MUST read all companion files before every task. Update them when you discover something new.**

---

## Development Rules

1. **SwiftUI + GRDB** — All new UI in SwiftUI. Data persistence via GRDB (`AppDatabase.swift` manages migrations and `DatabasePool`).
2. **Swift language** — All code in Swift.
3. **XcodeGen** — Project file generated from `project.yml`. Do not edit `.xcodeproj` directly. **`TabMail.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/*` are gitignored** — after `git clone` (or pulling changes that touch `project.yml`), run **`./Scripts/xcodegen.sh`** (NOT a bare `xcodegen generate`) before opening Xcode. The wrapper sources `DEVELOPMENT_TEAM` from gitignored `Secrets.xcconfig` and exports it so XcodeGen expands `${DEVELOPMENT_TEAM}` (in `project.yml` `settings.base`) into `DevelopmentTeam` in `TargetAttributes` for **every** target — including the NSE (`TabMailNotificationService`). A bare `xcodegen generate` with the var unset writes a literal `"${DEVELOPMENT_TEAM}"` and breaks signing; an NSE with no resolved team is signed with an invalid profile the device rejects (`applekeystored deny file-write-xattr` → SpringBoard `can be modified: 0` → the NSE never launches, so smart push silently dies while silent/background push still works). Fastlane lanes / `ensure_xcodegen` must call `./Scripts/xcodegen.sh`.
4. **Secrets in Secrets.xcconfig** — OAuth client IDs, API keys, etc. are in `Secrets.xcconfig` (gitignored). Loaded via `project.yml` configFiles → exposed in `Info.plist` → read at runtime.
5. **IMAP/SMTP via SwiftMail fork** — Use the SwiftMail fork (`github.com/TabMail/SwiftMail`, BSD-2-Clause, pinned in `project.yml`) for mail protocol operations. Do not add other IMAP/SMTP libraries.
6. **Modularization** - If a single code becomes longer than 500 lines, consider whether there are modularization opportunities for easy maintenance and upgrade.
7. **Code reuse** - Make sure to check if a similar function exists before you implement a function so that we do NOT have multiple re-implementations of the same function.

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
6. **Never silently discard.** Failed operations stay visible (Outbox shows failed sends, PendingOperation retries up to limit then stops). The user always has agency to retry or dismiss. Automatic cleanup only happens for provably-completed operations.

**When in doubt: persist the intention, retry later, show the user what happened.**

See ADR-IOS-001 (optimistic UI), ADR-IOS-003 (crash recovery), ADR-IOS-018 (action queue), ADR-IOS-019 (outbox).

---

## Data Integrity Rules — ABSOLUTE

1. **NEVER mark unfetched content as fetched** — If a body/attachment/metadata fetch fails or returns empty, the record MUST stay in "not fetched" state (e.g. `hasBody=0`). NEVER write placeholder/sentinel values (`body=" "`, empty strings, etc.) to trick the system into thinking content was fetched. The ONLY exception is a **verified permanent server error** (HTTP 404/410 — content confirmed gone). Marking unfetched content as fetched **hides bugs and drops user messages**.
2. **Retry mechanisms must not mask failures** — Skip-offset and stall mechanisms exist to avoid infinite loops on permanently failing messages, but they must NEVER discard or mark content as complete. The message stays retryable.
3. **If headers exist, bodies should eventually be fetchable** — If an IMAP FETCH returns no data for a UID that we have a header for, that's a bug to investigate (connection died, UID renumbered, etc.), NOT a case to paper over.
4. **NEVER use a DATE window/cursor for IMAP sync — UID and message-date are DECORRELATED (ADR-IOS-042).** This caused real, multi-month Archive DATA LOSS that required a forced re-sync of affected users (commit `4145d2a`, migration `v59`). IMAP `fetchMessages(limit:)` returns the **highest UIDs**, and a UID is **archive-time**, not message-date: archiving one OLD-dated email gives it a fresh HIGH UID. So a date-based stale-detection "overlap window" drags its floor back to that old date and sweeps in **months of mid-range Archive mail the fetch never returned → deletes them** (searchable-but-unopenable orphans; multi-month gaps). The RULE: any SYNC query that decides **what to fetch, keep, delete, or where the cursor/floor sits** for an IMAP folder MUST window by **UID** (`CAST(messageId AS INTEGER)` — `messageId` is the UID), NEVER by `date`. The single source of truth is `SyncEngine.selectStaleHeaders` gated on `provider.staleWindowMode` (`.uid` for IMAP, `.date` for Gmail/Exchange) — do not bypass it or add a parallel date-based sync path. **DISPLAY ordering is exempt** (the inbox/folder list orders by `date` for human reading, and the `messageHeader_folderId[_isRead]_date` composite indexes accelerate THAT — display only). The distinction is: *display* may use date; *sync/stale/cursor decisions* on IMAP must use UID.

---

## Resilience Rules

These are **mandatory** for all code in this project:

1. **NEVER block the main thread** — **CRITICAL.** GRDB's `DatabasePool` is thread-safe (concurrent readers, serialized writers), so no background `DispatchQueue` dance is needed. Heavy writes (backfill inserts, bulk updates) should use `dbPool.write { }` — the WAL journal mode keeps reads non-blocking. Avoid doing expensive computation inside write transactions on the main actor; offload to background Tasks where needed.
2. **Assume connections drop at any time** — State updates (e.g. history ID, sync cursors) must only be persisted upon verified completion. Never update state optimistically for backend/IMAP operations — a dropped connection with pre-written state causes stale entries that are hard to recover from.
3. **Assume every action can fail mid-operation** — The user can close the app, lose signal, or the process can be killed at any point. All operations must be idempotent. Implement state completion checks and self-healing: on next launch or sync, detect incomplete operations and either retry or clean up.
4. **Optimistic UI, hardened sync** — GUI actions must feel instant. Archiving, deleting, or moving messages should immediately animate away (swipe-to-zap, iOS-native animations) and update local GRDB state. The actual IMAP/provider sync happens asynchronously in the background, with the hardened retry/idempotency guarantees from rules 2 and 3.
5. **Use `Mutex` (from `import Synchronization`) instead of `nonisolated(unsafe)`** — When mutable state must be shared across isolation domains, protect it with `Mutex<T>` (SE-0433). NEVER use `nonisolated(unsafe)` to bypass the compiler — it hides data races. `NSLock` is also superseded by `Mutex` for new code. `@unchecked Sendable` is acceptable ONLY on the inner value type when the Mutex provides the synchronization, or on types wrapping inherently thread-safe APIs (e.g. CoreML's `MLModel`).

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

---

## AI Processing Rules

**MANDATORY: All AI processing (summary, action, reply) must exactly replicate the Thunderbird addon's architecture (ADR-IOS-008).**

- The TB addon's `messageProcessorQueue.js`, `summaryGenerator.js`, `actionGenerator.js`, and `llm.js` are the **authoritative reference implementations**.
- Before implementing or modifying any AI flow, **read the TB reference code first** to ensure 1:1 parity.
- Key patterns that MUST be replicated: persistent processing queue, event-driven enqueue, drain loop with watchdog timer, per-message semaphores, global LLM concurrency limit, caching with TTL, first-compute-wins, three-call action voting.
- Do NOT invent new AI processing patterns. Adapt TB's patterns to Swift/iOS idioms, but preserve the same architecture.

---

## SwiftUI Mutation Safety Rules

1. **NEVER remove items from an `@Observable` array synchronously during `onAppear`/`onDisappear`** when that array feeds the same `ForEach`. SwiftUI is mid-layout and will crash. Defer removals to the next run loop: `Task { @MainActor in ... }`.
2. **Appending is safe** from lifecycle callbacks — new items don't invalidate existing layout.
3. **User action handlers** (button, swipe, gesture) are safe for both append and remove.
4. **When evicting from paginated arrays**, keep evicted IDs in the dedup set to prevent re-fetch loops. Reset the set only on full reload.

---

## User Interaction Freeze Rule

**While the user is interacting (swiping, tapping, any animation in-flight), NO background updates may mutate `@Observable` state that feeds the visible view. This is a fundamental UX rule — no exceptions.**

- Background data changes (`backgroundDataDidChange`, AI updates, snippet loading, sync completions) MUST be deferred while the user is interacting.
- Use `InboxViewModel.beginInteraction()` / `endInteraction()` to gate the interaction window. All swipe action handlers, button taps, and gesture callbacks MUST bracket with these calls.
- `endInteraction()` starts a cooldown (200ms) to let SwiftUI animations settle before flushing deferred updates.
- Deferred updates are applied in one batch after cooldown: pending reloads take priority over individual snapshot refreshes.
- Snippet loading collects all updates into a batch and applies them in a single synchronous loop (one `@Observable` mutation → one re-render, not N).
- **Rationale:** The user acts on the *visualized* state. Re-laying out the list mid-swipe causes jank, dropped gestures, and animation conflicts. All pending updates come AFTER the interaction completes.

---

## Keyboard Dismiss Rule

**Tapping anywhere outside the keyboard MUST dismiss the keyboard. This is a fundamental UX design rule — no exceptions.**

- Every screen with text input MUST apply `.dismissKeyboardOnTap()` (defined in `KeyboardDismiss.swift`) on its root container.
- ScrollViews with text input should also use `.scrollDismissesKeyboard(.interactively)`.
- The keyboard reappears naturally when the user taps a text field — no special handling needed.
- Do NOT add manual keyboard dismiss buttons (toolbar chevrons, floating buttons, etc.). The tap-outside gesture handles everything.

---

## Other notes

1. Multiple agents might be running on the code base, so build may fail due to places irrelevant to your edits.