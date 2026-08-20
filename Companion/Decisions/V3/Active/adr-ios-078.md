## ADR-IOS-078: The Newest-100 Window Bounds Processing Only — Existing AI Content Is Never Gated From Display

**Date:** 2026-08-19

**Status:** Active. Owner decision, recorded verbatim in intent: *"what we intentionally intended
was that the AI processing does not happen for things in inbox that are beyond the 100 limit.
However, there is no reason whatsoever to gate AI that already exists … if an AI summary exists,
there's never a reason to gate it."*

**Context.** `7a31f1d22` ("Restore bounded queue behavior", shipped in `v1.7.11`) implemented the
IOS-AI-004 bounded-processing policy: only the newest `SyncConfig.maxRecentEmails` Inbox rows are
eligible for AI work (`ActiveAIQueue.recentInboxWindowContains`, migration `v87`). In the same
commit the bound leaked into DISPLAY: `SummaryBubbleView` gained a `recentInboxEligible` window
query and a "AI work is suppressed for older messages in large inboxes" notice that replaced the
bubble — including for messages whose summary **already existed**. That display half also carried a
lifecycle defect (the unresolved gate hid the view hosting its own resolver — `MIS-IOS-017`), which
PR #59 hot-fixed by making the gate resolve correctly. The owner then ruled the display gate itself
was designed in error. Separately, the shipped `v1.7.9` display had always gated the summary bubble
on inbox membership (`if !isInInbox { return .hidden }` ran before the content check), hiding a
retained summary when a Sent/Archive/Trash message was opened via search.

**Decision.**

1. **Summaries: never gated.** An AI summary that exists renders in every folder — no newest-100
   window check, no inbox-membership check, nothing beyond "the summary exists". The only remaining
   `.hidden` outcomes in `SummaryBubbleView.displayMode` are presentation states: demo-with-AI-
   declined, and the ABSENT-summary empty state outside the Inbox (where
   `AccountManager.processOpenedMessage` guards on `isInInbox`, so a loading spinner would
   advertise work that never happens). The absent-summary state sits after the content check, so it
   can never hide existing AI content. The demo consent state is deliberately checked FIRST — a demo
   user who declined AI sees no AI output at all, even pre-baked demo content: it is a consent
   surface, not an eligibility policy. This deliberately goes one step past a `v1.7.9` restoration: `v1.7.9`'s
   inbox-membership display gate on the summary is removed, not restored.
2. **Action pill / tag buttons: inbox-membership only.** `ActionTagDisplay.displayedTag` remains
   the single display decision — tag rendered in the Inbox, hidden outside it (tags are meaningless
   outside the Inbox; ADR-IOS-036 retention is unchanged). No newest-100 gating exists on this
   surface and none may be added. Verified already compliant at `785138481`; no code change.
3. **Processing: the window bounds SYNC-ORIGIN admission only** *(amended 2026-08-19, same
   decision train — the original form of this point read "Processing: unchanged" and kept the
   window on every producer; see "Pathway regating" below)*.
   `ActiveAIQueue.recentInboxWindowContains` remains the sole window seam, but it now applies to
   the sync/body-pipeline producer and the repopulation sweep, plus execution re-checks of jobs
   admitted that way. Push/NSE merge, manual open and moved-into-inbox are window-exempt. Display
   never consults it.

**Consequences.**

- An out-of-window Inbox message with no summary shows the ordinary `v1.7.9` empty state — loading,
  then after 20 s the failure/retry bubble. *(Superseded 2026-08-19, same decision train: this
  bullet originally continued "even though the bounded queue will never process it, and Retry is a
  no-op outside the window — accepted by the owner". The pathway regating below makes the manual
  open — including the failure bubble's Retry — a REAL processing path for out-of-window Inbox
  messages, so the empty state is no longer a dead end.)* The previous suppression notice is gone.
- A Sent/Archive/Trash message opened via search now renders its retained summary (`v1.7.9` hid it).
- The `.suppressed` display state, the `recentInboxEligible` view state and the view-side window
  query are deleted; `SummaryBubbleViewTests` pins exists⇒shown across the folder axis, and the
  window axis is gone from `displayMode`'s signature by construction.
- IOS-AI-004's display clause is replaced (see its amendment); its processing clause is untouched.
  *(2026-08-19 later the same day: the processing clause is then NARROWED by the pathway regating
  below — see IOS-AI-004's second amendment.)*
- The mistake class "a processing bound leaked into display semantics" is recorded as `MIS-IOS-018`.

**Pathway regating (2026-08-19, owner directive in the same decision train).**

Owner verbatim: *"the inbox limit is solely for automatic background processing when user first
installs tabmail. We just have to route manual open path to be exempt, and put this recent 100
check in the inbox sweep-based ai queuer, since recent arriving emails are by definition within
recent 100."* Items marked **coordinator-ruled** below were decided by the session coordinator
within that directive's intent and are explicitly surfaced for owner veto.

- **Window KEPT (sync bucket).** The repopulation sweep (`ActiveAIQueue.repopulationCandidates`,
  window-bounded in SQL) and the SYNC-ORIGIN feeders of the body pipeline:
  `BodyFetchProcessor.flushBatch`'s `enableAI && item.isInInbox` arm calls the default, non-exempt
  `enqueue` unless its caller says otherwise, and its gated feeders never do. Those gated feeders
  are TWO, not one: `ActiveBodyQueue`'s batch flush AND `InboxViewModel`'s snippet-loader Tier-2
  network fetch (list-scroll driven — exactly the unbounded shape this bound exists for).
  `BackfillBodyQueue` passes `enableAI: false` and never reaches AI at all. This is the install-flood door the bound exists for:
  `ActiveBodyQueue.repopulateFromDatabase` is Inbox-wide and UNBOUNDED, so on first install every
  historical Inbox row flows through `flushBatch`; the admission window is the only thing between
  that flood and the LLM. Deep backfill never enqueues AI at all (`BackfillBodyQueue` calls
  `flushBatch(enableAI: false)`). ⚠️ `flushBatch` is DUAL-ORIGIN — the user-open priority fetch
  also flushes through it (below); the origin travels as its `aiWindowExempt` parameter, so
  "flushBatch is gated" is true of its sync feeders, not of the function.
- **Window EXEMPT (arrival/user-intent bucket), carried by `AIJob.windowExempt`:**
  - *Push/NSE merge* (`NSEDataBridge`'s post-merge downstream loop): a pushed message is new mail
    the user was just notified about.
  - *Manual open*, both body states. Body already DURABLE:
    `AccountManager.processOpenedMessage` — the window guard is removed from the co-read; the
    `isInInbox` guard STAYS (AI processing remains inbox-scoped).
    ⚠️ **CORRECTED 2026-08-20 (iOS #66) — this clause read "Body already durable/*staged*" until
    2026-08-20, and that attributed the coverage to the WRONG MECHANISM.**
    `OpenedAIProcessingSnapshot.capture` reads the **durable** row only — its first guard is
    `MessageBody.fetchOne(db, key: headerId)` — so on a STAGED body it returns nil and
    `processOpenedMessage` returns at its `guard let opened`, a no-op regardless of the window.
    There is no runtime consequence, because a staged body always originates from an NSE merge
    whose post-merge downstream loop already enqueues `windowExempt: true`: the staged case is
    covered by the *push/NSE merge* bullet above, never by this one. `IOS-AI-004` states it
    correctly ("`processOpenedMessage`'s **cached-body** path"), so the two documents contradicted
    each other until this correction. Body not yet fetched: the open's
    own server fetch (`AccountManager.fetchBody` → `BodyFetchProcessor.fetchAndProcess(…,
    aiWindowExempt: true)` → `flushBatch`) enqueues exempt — every `fetchBody` caller is a
    user-driven detail-view path, so this producer is user intent by construction. (The first cut
    of this regating missed that arm — an out-of-window open whose body was not yet fetched was
    still suppressed at `flushBatch`'s gated enqueue; caught by the round-1 review.) **Scope:** this
    covers the open that performs its OWN fetch. When `ActiveBodyQueue` already owns the fetch
    (`MessageDetailViewModel.loadBody` sees `isQueuedOrInFlight` and polls), the body lands via the
    background queue's DEFAULT (gated) `flushBatch`, and the poll's `adoptReadyBody` displays it
    without re-triggering AI — that residual is the coordinator-deferred body-arrival auto-trigger
    below, Retry-recoverable. The failure bubble's Retry is a real processing path for out-of-window
    opens **once the body is durable**. *(It read "in every state" until 2026-08-20, iOS #66 — false
    for the same reason as the staged clause above: `SummaryBubbleView`'s Retry calls
    `processOpenedMessage`, which no-ops while the `MessageBody` row does not yet exist. Retry after
    the body lands re-enters the exempt direct path, which is what makes the poll-state residual
    recoverable.)*
  - *Moved-into-inbox* (`AccountManager.enqueueAIForMembersThatEnteredInbox`) — **coordinator-
    ruled:** a move into the Inbox is explicit user intent on a specific message and per-gesture
    volume is tiny; gating it would recreate the "user must click the message" gap ADR-IOS-008
    decision 3 closed.
- **Execution re-checks are origin-aware — coordinator-ruled.** `executeJob` and `readJobOutcome`
  window-retire a job only when `ActiveAIQueue.windowRetires(job:inRecentWindow:)` says so
  (`!inRecentWindow && !job.windowExempt`). Sync-origin jobs keep mid-queue age-out retirement —
  the bound stays enforced end-to-end; exempt jobs are exempt end-to-end. Inbox MEMBERSHIP
  retirement is unconditional for every origin (window-exemption is not inbox-exemption; before
  this change `executeJob`'s membership check was implied by the window check, now it is
  explicit). The action job chained after a summary inherits its parent's exemption
  (`ActiveAIQueue.chainedActionJob`). Dropping the re-checks entirely was rejected — it would
  weaken the sync bound. **Exemption WINS on dedupe:** `windowExempt` is excluded from `AIJob`
  identity, so an exempt offer that collides with a still-pending gated twin would otherwise be
  swallowed and the stored gated job window-retired — every admission that can carry the flag routes
  through one `admitOrUpgrade` primitive that upgrades the pending twin in place
  (`QueueStorage.replacePending`); the reverse direction never downgrades because only exempt offers
  replace. This governs BOTH the batch `enqueue` (S/R) AND the action chained after a summary
  (`chainActionJob`) — the round-1 review fixed the S/R path, and the round-2 review found the same
  dedupe-swallow class at the chain sites, where an exempt summary's action could be rejected by a
  gated action twin already pending from `enqueueBatch` and then window-retired. (Reachability is
  narrow — a pending gated twin must age out before an arrival event re-offers the same headerId —
  but the upgrade is cheap and makes the exemption hold for every PENDING twin rather than being
  reachability-argued.) **Scope of the upgrade — the in-flight residual.** `replacePending`
  deliberately skips in-flight items, and `collectCandidates` marks a job in-flight synchronously
  while the executor's admission re-check runs later, after a hop. So an exempt offer landing in
  that prefix is rejected, and if the message has aged out the in-flight gated twin still
  window-retires. The exemption is therefore NOT unconditional; the residual is narrow, fail-closed
  (`.scopeExited` writes no `recentlyCompleted` marker, so a later exempt offer is admitted fresh)
  and one-gesture recoverable through Retry/reopen. Recorded 2026-08-19 (round-6 review).
- **Silent push: no plumbing — coordinator-ruled, then owner-CONFIRMED 2026-08-20 (iOS #68).** A
  silent push wakes the delta sync; genuinely new mail admitted through that path is *almost always*
  inside the newest-100 window, so the gate rarely bites it and no origin flag travels through the
  sync pipeline.
  ⚠️ **The absolute this bullet used to state is FALSE, and its counterexample is REACHABLE.** Until
  2026-08-20 it read: *"new mail admitted through that path is **by definition** inside the
  newest-100 window, so the gate never bites it"*. The window is ordered by `MessageHeader.date`,
  and that field is **INTERNALDATE** — `IMAPProvider.mapMessageInfo` prefers the server's internal
  date over the envelope `Date:` header — while IMAP `COPY` **preserves INTERNALDATE**. So a message
  that another client (desktop, webmail, another device) **moves or restores into the Inbox** — out
  of Archive, out of Trash, by a server-side filter rule — reaches this device through delta sync
  carrying its **original** internal date, not the moment it entered the Inbox. In an Inbox holding
  more than `SyncConfig.maxRecentEmails` messages it can therefore sort **outside** the window and
  stay gated. This is the same decorrelation ADR-IOS-042 keys IMAP sync windows by UID for: arrival
  order and message date are independent. The outcome is **path-dependent** — the identical message
  arriving through the NSE merge path *is* window-exempt and does process.
  **Owner ruling 2026-08-20, verbatim: *"this is also very rare, and mostly a budget exhaustion
  prevention. just fix the docs to be accurate."*** So the BEHAVIOUR is confirmed as it stands and
  **no exemption is plumbed**: a message moved into the Inbox by another client may receive **no
  automatic summary until the user opens it**, and that is **accepted**. It satisfies the residual
  invariant below — fail-closed, non-durable, and repairable by one ordinary gesture (opening it
  re-enters the exempt direct path). ⛔ Do **not** "fix" this by treating a delta-sync arrival as an
  arrival-origin event and plumbing the exemption through: that is a behaviour change, it widens the
  door toward the install flood this ADR exists to keep shut, and it was explicitly declined.
- **Deferred (coordinator-ruled follow-up): the body-arrival auto-trigger for the background-queue
  poll path.** When a manual open finds its body already owned by `ActiveBodyQueue`
  (`loadBody` → `isQueuedOrInFlight` → `startBodyPoll`), the body is written by the background
  queue's gated `flushBatch` and the poll's `adoptReadyBody` displays it WITHOUT re-triggering AI —
  so an out-of-window open in this state gets no summary until the user taps Retry (or reopens once
  the body is durable, which routes through `processOpenedMessage`). This is the same "body-arrival
  auto-trigger" the coordinator ruled a SKIP/optional follow-up; the round-1 note that claimed it
  "already existed inside the fetch pipeline" was correct ONLY for the open's own-fetch arm and
  over-reached for this poll arm (round-2 review). It stays deferred rather than fixed here because
  `startBodyPoll` is a heavily-audited function with documented wrong-message (C3) recovery holes
  (`IOS-BODY-004`); adding an exempt `processOpenedMessage` at its adoption sites needs its own
  audit and tests. Fail-closed and Retry-recoverable per THE MANTRA — registered as the residual in
  IOS-AI-004.
- **Residual: the re-key `.dropped` fallback's rediscovery is window-bounded** (found round-7
  review). When `processOpenedMessage`'s guarded write refuses a stale address because a move
  re-keyed the row mid-flight, the fallback calls `ActiveAIQueue.repopulateFromDatabase()`, whose
  `repopulationCandidates` SQL is still limited to the newest `SyncConfig.maxRecentEmails` Inbox
  rows — so for an OUT-OF-WINDOW row that rediscovery is a no-op. Before this regating the branch
  was unreachable for such rows (the removed window guard returned nil from the co-read first);
  the exemption made it reachable. Deliberately NOT fixed by widening the sweep, which would
  reopen the install-flood door this ADR exists to keep shut. Fail-closed and one-gesture
  recoverable (reopen/Retry re-enters the exempt direct path).
- **Residual: an exempt job is lost outright when the queues are cancelled** (found round-8 review).
  `SyncScheduler.cancelAllInFlightQueues` → `ActiveAIQueue.cancelAllInFlight` →
  `QueueStorage.cancelAllInFlight` clears `queue`, `enqueued`, `inFlight`, `retryCount` and
  `recentlyCompleted` outright, and the ONLY rebuild is `repopulateFromDatabase` →
  `repopulationCandidates`, which is window-bounded in SQL. Its triggers are ORDINARY, not
  exceptional — `syncStartup`'s resume-recovery, the BGAppRefresh/BGProcessing expiration handlers,
  `PushNotificationService`, and `executeJob`'s own background-task expiration handler — so a
  pending or in-flight EXEMPT job for an out-of-window row does not survive a background→foreground
  round trip. The pre-existing rationale at the `SyncScheduler` call site ("new mail still arrives
  via sync→enqueueBatch (dedup-safe)") is a recovery argument that only ever held for IN-WINDOW
  work; this change widened what it is covering. Fail-closed, one-gesture recoverable, no durable
  state — but it means the exemption is *best-effort within a foreground session*, which is the
  honest characterisation of the whole ephemeral design.
- **The residual INVARIANT (stated as a property, deliberately NOT as a count).** Every residual of
  this change has one shape: **for an out-of-window row, exempt AI work can fail to be scheduled or
  can be discarded before it runs — never silently wrong, never durable, and always repairable by
  one user gesture** (reopen or Retry, both of which re-enter the exempt direct path). The known
  instances at this writing are the deferred body-arrival auto-trigger, the `.dropped`-fallback
  rediscovery, the `replacePending` in-flight exclusion, and this queue-cancellation loss. That
  list is explicitly NON-EXHAUSTIVE: an earlier revision asserted "exactly three" and the round-8
  review immediately falsified it by finding a fourth. Judge any newly-discovered case against the
  invariant above — if it satisfies it, it is a known-class residual and needs no new mechanism; if
  it does NOT (durable, silent, or not user-repairable), that is a defect and must be fixed.
- **TTL sweep already correct — no change.** `SyncEngineMaintenance.refreshAICacheTTLAndPurge` /
  `runPurgeExpiredAICache` evict by inbox MEMBERSHIP (an expired cache entry is rescued whenever
  its `rfc822MessageId` still matches an `isInInbox == true` header), never by window. The
  owner's preferred behavior already held.
- **No durable exception state.** Exempt processing is direct and ephemeral — no marker columns,
  no triggers, no redrive. IOS-AI-004's retirement of PR #39's durable machinery stands.
