# IOS-AI-004

- Register classification: `accepted`
- New post-freeze record (2026-08-12) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED PRODUCT LIMITATION (2026-08-17; display clause replaced 2026-08-19; processing
scope narrowed to sync-origin admission 2026-08-19, ADR-IOS-078 pathway regating).** AI output is
derived content, not a user-authored intention. TabMail's AUTOMATIC pipeline processes only the
newest `SyncConfig.maxRecentEmails` Inbox messages: the repopulation sweep
(`repopulationCandidates`, bounded in SQL) and the sync/body-pipeline producer
(`BodyFetchProcessor.flushBatch` → non-exempt `enqueue` when fed by its gated callers —
`ActiveBodyQueue`'s batch flush AND `InboxViewModel`'s snippet-loader Tier-2 fetch;
the user-open fetch routes through the same function with `aiWindowExempt: true`) are
window-bounded. The bound exists for
the install flood — `ActiveBodyQueue.repopulateFromDatabase` is Inbox-wide and unbounded, so
without the admission window a first install would run AI over the entire historical Inbox.

**The window no longer applies to arrival/user-intent events (owner directive 2026-08-19,
ADR-IOS-078 pathway regating).** Opening a message (including the failure bubble's Retry),
receiving it by push/NSE merge, or moving it into the Inbox now processes it regardless of the
window (`AIJob.windowExempt`; execution re-checks are origin-aware via
`ActiveAIQueue.windowRetires`; inbox MEMBERSHIP remains an unconditional scope for every origin).
The 2026-08-17 sentence that stood here — "A message outside that population is deliberately not
made eligible merely because it is opened, pushed, or moved into Inbox" — is superseded for
ELIGIBILITY: those events process the message directly and ephemerally. What remains true, and is
the part this record still protects, is that they create NO DURABLE EXCEPTION STATE — no marker
columns, no triggers, no redrive, no second durable class (the PR #39 retirement below stands).

**Display is NOT gated (owner decision 2026-08-19, ADR-IOS-078).** The bound above is a
PROCESSING bound only. The 2026-08-17 display half of this record — a `SummaryBubbleView` window
check and a quiet suppression notice — was an error and is removed: an existing AI summary renders
in every folder; the sole exception is the demo-with-AI-declined consent state, which is checked
before content by design (ADR-IOS-078). An in-window presentation difference no longer exists; an
out-of-window Inbox message with no summary shows the ordinary v1.7.9 empty state (loading, then
the failure/retry bubble), and since the same day's pathway regating that state is a real entry
point — Retry processes the message.

This supersedes the earlier attempt to make direct events durable beyond the automatic window. PR
#39's `aiDirectPending` columns, triggers, cache mirror, re-key carry and direct-event redrive widened
the queue state space for a hypothetical derived-work recovery. In ordinary use that complexity made
old incomplete rows repeatedly reachable by the AI/body drains. The owner chose the prior bounded
policy and everyday liveness over preserving that derived work.

## Governing behavior

- `ActiveAIQueue.recentInboxWindowContains` is the admission decision for SYNC-ORIGIN enqueue
  (`BodyFetchProcessor.flushBatch` fed by its gated callers — `ActiveBodyQueue`'s batch flush and
  `InboxViewModel`'s snippet-loader Tier-2 fetch), the repopulation sweep, and
  execution re-checks of non-exempt jobs (`ActiveAIQueue.windowRetires`). Push/NSE merge,
  moved-into-inbox and opened-message processing — including the open's own body fetch
  (`AccountManager.fetchBody` → `fetchAndProcess(aiWindowExempt: true)`) — are window-exempt
  (2026-08-19 pathway regating) and stay inbox-scoped by TWO DISTINCT mechanisms, which must not be
  conflated (corrected 2026-08-19, round-6 then round-7 review — the round-6 correction itself
  over-generalized and is superseded by this one):
  - **Queue-mediated exempt origins** (the open's own body fetch via `flushBatch`, push/NSE merge,
    moved-into-inbox) carry `AIJob.windowExempt` and are scoped by `ActiveAIQueue.executeJob`'s
    UNCONDITIONAL `message.isInInbox` re-check. There the re-check is load-bearing rather than the
    producer-side check, because `flushBatch` and `NSEDataBridge` do self-check `item.isInInbox`
    but `enqueueAIForMembersThatEnteredInbox` deliberately does NOT — `inboxEntryAITargetSQL` omits
    the column on purpose so a redundant conjunct cannot mask the failure of the guard that matters.
  - **The direct arm** — `AccountManager.processOpenedMessage`'s cached-body path — constructs NO
    `AIJob` and never enters the queue; it calls `processMessage` inline. `windowExempt`,
    `windowRetires` and `executeJob` therefore never run for it, and its own
    `guard opened.current.isInInbox` is the ONLY inbox scope on that path. It must not be removed
    on the theory that the executor re-checks. An exempt offer that collides with a still-pending gated twin upgrades it in
  place (`QueueStorage.replacePending`) — dedupe never swallows an exemption, and nothing ever
  downgrades one. `SummaryBubbleView` no longer consults the window (2026-08-19): display renders
  whatever AI content already exists, in every folder.
- The newest window is selected before cached-work filtering. Completed recent messages therefore do
  not cause the queue to reach farther back for replacement work.
- A SYNC-ORIGIN job that ages out after enqueue is retired as a scope exit; it is not interpreted
  as incomplete work that should retry. A window-exempt job is never window-retired; a job whose
  message has LEFT the Inbox retires regardless of origin.
- Existing v85/v86 migration identifiers remain immutable. Forward migration
  `v87_retireDirectAIPending` drops their triggers, sparse index and marker columns.
- No provider fetch, stored email body, authored data or user action is discarded by this policy.

## Residual and reopening rule

An older Inbox message the user never opens, never receives by push, and never moves may have no
AI summary/action/reply. That is the accepted outcome *(narrowed 2026-08-19: opening, push/NSE
merge, or a move into the Inbox now processes the message — the residual is only messages none of
those events ever touch)*. Narrow residuals sit inside that narrowing. They share one INVARIANT,
which is the thing to check — not the count: **for an out-of-window row, exempt AI work can fail to
be scheduled or be discarded before it runs; never silently wrong, never durable, always repairable
by one gesture** (reopen/Retry re-enter the exempt direct path). Known instances at this writing,
explicitly NON-EXHAUSTIVE: (1) the coordinator-deferred body-arrival auto-trigger for the
background-queue poll arm (`startBodyPoll` → `adoptReadyBody`, `IOS-BODY-004`); (2) the re-key
`.dropped` fallback's `repopulateFromDatabase()` rediscovery, window-bounded and therefore a no-op
for an out-of-window row — newly reachable since the exemption (round-7 review); (3) the in-flight
exclusion of `QueueStorage.replacePending`, where an exempt offer colliding with an already-in-flight
gated twin is rejected and that twin can still window-retire; and (4) outright queue loss via
`SyncScheduler.cancelAllInFlightQueues` → `QueueStorage.cancelAllInFlight`, whose only rebuild is the
window-bounded sweep, so an exempt job does not survive a background→foreground round trip (round-8
review). An earlier revision claimed "exactly three" and was falsified within one round — hence the
invariant-first framing. Reopen only if
measured product usage justifies changing
`SyncConfig.maxRecentEmails` itself; do not add a second durable exception class, identity mapping
or relaunch redrive for derived work — the 2026-08-19 exemptions are deliberately EPHEMERAL
(enqueue-time flag on an in-memory job; a relaunch re-discovers work through the bounded sweep
only).

**Deferred sub-case (coordinator-ruled follow-up, round-2 review 2026-08-19):** the *body-arrival
auto-trigger* for a manual open whose body is already owned by `ActiveBodyQueue`. In that state
`MessageDetailViewModel.loadBody` sees `isQueuedOrInFlight` and polls; the body lands via the
background queue's DEFAULT (gated) `flushBatch` and `startBodyPoll`'s `adoptReadyBody` displays it
without re-triggering AI, so an out-of-window open in this specific race gets no summary until the
user taps Retry (or reopens once the body is durable — that path routes through
`processOpenedMessage` and is exempt). The own-fetch open arm (`fetchBody` →
`fetchAndProcess(aiWindowExempt: true)`) IS covered; only the background-owned arm is deferred. It
stays deferred rather than fixed inline because `startBodyPoll` is a heavily-audited function with
documented wrong-message (C3) recovery holes (`IOS-BODY-004`) — an exempt `processOpenedMessage` at
its adoption sites needs its own audit and tests. Fail-closed and one-gesture recoverable (Retry /
reopen) per THE MANTRA. *(A second narrow limitation on the QUEUE path, pre-dating this work: a row
that already has a summary but no action tag will not re-chain the action on re-enqueue —
`executeJob` short-circuits the summary job on an existing `summaryBlurb` before the chain — so an
out-of-window such row is not repaired by the queue. **Corrected 2026-08-19 (round-8 review): this
limitation is REOPEN-RECOVERABLE, and it is this commit that made it so.** The earlier wording here
said it was "recoverable only if the row re-enters the window or its summary is cleared"; that was
true while `processOpenedMessage` carried a window guard, and the regating falsified it. Reopening
now repairs the row without touching `executeJob` at all: `processOpenedMessage` computes
`needsAction = current.actionTag == nil` and passes its `needsSummary || needsAction || needsReply`
guard, then `processMessage`'s `else if !hasExistingAction` arm calls `classifyAction` and writes
the tag through `aiGuardedHeaderWrite`. So this limitation carries the same one-gesture recovery as
every other residual here — do NOT build a redrive or widen the sweep for it.)*

## Search terms

`IOS-AI-004`; `SyncConfig.maxRecentEmails`; `recentInboxWindowContains`;
`repopulationCandidates`; `windowExempt`; `windowRetires`; pathway regating;
`processOpenedMessage`; `enqueueAIForMembersThatEnteredInbox`; `SummaryBubbleView`;
`admitOrUpgrade`; `chainActionJob`; `startBodyPoll`; `isQueuedOrInFlight`; `IOS-BODY-004`;
body-arrival auto-trigger; action chain dedupe;
`v85_addDirectAIPending`; `v86_retireDirectAIOnInboxRoleExit`; `v87_retireDirectAIPending`;
PR #39; large inbox; AI work suppressed
