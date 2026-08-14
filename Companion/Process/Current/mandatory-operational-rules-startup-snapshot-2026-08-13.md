# Mandatory operational-rules startup snapshot — 2026-08-13

> Routed from `CLAUDE.md` on 2026-08-13. The fenced block is the former startup block, preserved byte-for-byte and in order. `CLAUDE.md` retains a keyword-bearing route to every authoritative rule; fencing keeps the snapshot's old root-relative links inert at this deeper path.

---

```markdown
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
```
