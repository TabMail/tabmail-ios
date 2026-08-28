<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** The preserved demo-mode design below names
> `registerAlarmsWithPushWorker` and `TaskEvaluationService.evaluate`. Both symbols were deleted
> with the scheduled-task feature; see ADR-IOS-079. Their guard pattern still applies to any future
> KB-reading background job: demo data must not overwrite real execution state or registrations.
<!-- COMPANION-CURRENT-NOTE-END -->


## ADR-IOS-038: Demo Mode — Custom JWT + Local Mock Provider + Pre-Baked AI Cache

**Status:** Accepted (2026-04-30)

**Decision:** Add a "Try the demo without creating an account" entry on the
login screen that lets a brand-new user explore TabMail with sample data
without creating a Supabase user. Implemented in three layers:

1. **Backend identity:** stateless HS256 demo JWT (`iss: 'tabmail-demo'`)
   minted by new `POST /demo/start` endpoint. Backend's `gatewayHelpers`
   peeks the issuer and short-circuits to a synthesized entitlement with
   `user_id = '00000000-0000-4000-8000-44454d4f0000'` (fixed UUID
   sentinel — hex `4d4f` mnemonic "DE-MO"). All demo cost rolls up to that
   single sentinel row in `usage_events`. A per-token in-memory rate limit
   defends against abuse; a per-IP rate limit on `/demo/start`
   prevents mint flooding. Dual-key HMAC rotation (`PRIMARY` +
   `PREV`) mirrors `INTERNAL_USAGE_SECRET`.

2. **Local mock provider:** `DemoProvider` (EmailProvider) and
   `DemoCalendarProvider` (CalendarProvider) answer entirely from GRDB —
   no network. Demo account is `accountId == "demo-account"`. Demo
   calendar events live in a new `demoCalendarEvent` table (table-prefix
   scoping for clean wipes).

3. **Pre-baked AI cache invariant:** every seeded inbox message
   has `MessageHeader.summaryBlurb`, `actionTag`, and (where applicable)
   `cachedReply` populated by `DemoSeed`, plus a corresponding
   `MessageAICache` row. Opening any seeded message MUST NOT fire an LLM
   round-trip. `AIService.process` carries a hard demo guard that
   returns empty results rather than running the LLM, even if upstream
   short-circuit logic ever changes.

**LLM call accounting:** the user-visible 50-call cap lives
on iOS (`DemoModeStore.callsConsumed` in UserDefaults, persisting per
install). Counter is decremented at three chokepoints — and only there:
`AIChat.sendChatMessage`, `AIInlineEdit.performInlineEdit`, and the
`BackfillAIQueue.enqueueActionRefine` enqueue site driven from
`AccountManagerAI.applyManualTag`. Tool rounds within one agent
turn don't double-count. Refund matrix: `URLError`,
`CancellationError`, 5xx, demo-token 429 refund; 4xx/parse failures don't.

**Consent gates:** demo runs the production `ConsentGateView` and
`AIConsentView` on entry, but writes to demo-prefixed `@AppStorage` keys
(`demo.hasCompletedConsentGate`, `demo.hasSeenAIConsent`,
`demo.aiEnabled`) so production gates run from scratch when the user
later signs up. `AIConsentView` was refactored to remove its internal
`AIService.writeOptOutFlag` call — caller now decides where to persist
the AI choice. `PushConsentView` is skipped in demo (no real push).

**AI-disabled demo:** when the user declines AI on the demo gate,
seeded summaries / action chips / cached replies / chat pill / inline
edit are all rendered as off (the data stays in GRDB, the views just
gate on `DemoModeStore.aiEnabled`). The demo Settings page exposes an
"Enable AI" button that re-runs the AI consent gate without re-seeding.

**Cleanup:** `DemoModeService.exit()` wipes:
- `accountId == "demo-account"` rows from `messageHeader`, `folder`,
  `messageBody`, `messageAICache`, `outboxMessage`, `pendingOperation`,
  `account`.
- `chatTurn WHERE sessionId LIKE 'demo:%'`.
- `demoCalendarEvent` (full table — demo only).
- FTS demo entries via new `SearchIndex.purgeForAccount(_:)`.
- memory.db demo entries via new `MemoryIndex.purgeForSessionPrefix(_:)`.

The 50-call counter, demo gate flags, and TipKit shown-state all
**persist** across exit. Only uninstall resets them.

**Once user signs up (refined 2026-05-01):** the original plan used a
sticky `demo.servedItsPurpose` UserDefault set on first non-demo account
add. **Replaced with a state check**: `TabMailLoginView`'s demo button now
gates on `navigationStore.hasAnyAccount` (a new field on `NavigationStore`
that counts active rows in `account` including `calendarOnly == true`).
Reactive on `.backgroundDataDidChange`, so adding any account hides the
button on the next refresh and removing all accounts (sign-out + wipe)
restores it — no sticky flag, no need to clear UserDefaults to recover.
`connectAccount` still calls `DemoModeService.purgeOrphanedDemoData` to
clean residual demo rows.

**What we explicitly DO NOT do in demo:**
- Push notifications (`PushNotificationService.subscribeAccount` is
  guarded).
- Device Sync (`DeviceSyncService.connect` is guarded).
- Real EKEventStore writes (ICS imports route to `DemoCalendarProvider`
  via guard in `ICSCalendarImporter.presentCalendarImport`).
- Vector embeddings during seeding (FTS-only).
- Proactive reminder notifications (`ProactiveNotifyService` entry points
  are demo-guarded — rescheduling from the demo-scoped reminder list would
  replace the user's pending OS notification schedule and pollute
  `ReachedOutStore` with demo hashes; added 2026-07-02).
- KB refinement (the session-expiry enqueue skips `demo:` sessions — a
  demo chat must never rewrite the user's KB; added 2026-07-02).

**Chat + reminder isolation (added 2026-07-02):**
- **Every demo chat sessionId carries the `demo:` prefix** via
  `DemoModeStore.scopedSessionId(_:)` — `demo:{uuid}` (inbox),
  `demo:msg:{key}` (message detail), `demo:compose:{draftId}` (compose).
  ALL mint AND lookup sites route through the helper (they live in
  `DynamicIslandChatButton`); `DraftStore` compose-turn deletes target both
  the plain and `demo:`-prefixed variants unconditionally. The prefix is
  what makes `DemoSeed.wipe`'s chatTurn/chatHistory range deletes and
  `MemoryIndex.purgeForSessionPrefix("demo:")` actually match — before
  this fix, demo turns were minted UNprefixed, so they were never wiped
  and mixed freely with the user's sessions. Within a demo run, chat
  behaves exactly like the real app (sessions persist, resume, swipe as
  history pages) — they are just namespaced, and all of it is wiped on
  exit. Wipe cost is unchanged at boot: `hasDemoData` still short-circuits
  on one PK lookup, and both range deletes use the `chatTurn_sessionId` /
  `chatHistory_sessionId` indexes (half-open range form, no LIKE scans).
- `ChatStore.inboxSessionScopeSQL(demoActive:)` scopes the session-history
  swipe UI: demo mode lists only `demo:` inbox sessions; normal mode
  excludes all `demo:` sessions. Inbox-session eviction always excludes
  demo sessions (they must not crowd out or count against the user's
  session limit).
- `ChatPillState.shared.removeAllSessions()` runs on demo entry
  (`completeSetup`, behind the seeding splash) and on exit, so in-memory
  pill state (live turns, loaded pages, reminder buffers) never crosses
  the demo/real boundary.
- `ReminderBuilder` is demo-scoped both directions: message reminders
  filter `accountId == "demo-account"` in demo (3 seeded reminders match
  the 3 cards shown on chat expand) / `!=` in normal mode, and KB
  reminders/tasks parse from the demo prompt overlay (below). The account
  filter is an extra AND predicate on the existing reminder query — no new
  table scans. Cache invalidates on entry/exit via the existing
  `.remindersDidChange` posts.

**Tool-boundary isolation (added 2026-07-02, same-day follow-up):** an
audit found essentially the whole agent-tool layer crossed the demo/real
boundary (`ToolContext.db` is the shared pool; `ChatIdTranslator` is one
global map; `registerDemoProviders` leaves real providers registered). The
fix gates at shared chokepoints, not per-tool patches:
- **Nonisolated demo flag** — `DemoModeStore.isDemoActive`
  (`Mutex`-mirrored from `isActive.didSet`) so nonisolated readers
  (PromptStore snapshots, DisabledRemindersStore, Search/Memory indexes,
  tool guards) can branch without a MainActor hop.
- **Prompt overlay** — while demo is active, ALL FOUR PromptStore fields
  (kb / composition / action / templates) read+write `demo.`-prefixed
  UserDefaults keys (`PromptStore.storageKey`), seeded from bundled
  defaults by `enterDemoOverlay()` (called in `completeSetup`) and torn
  down by `exitDemoOverlay()` (called in `exit()` BEFORE `isActive` flips
  false — ordering contract). Demo-time `didSet`s skip NSE mirror, Device
  Sync broadcast/timestamps, and prompt history; `applySync` / `reset*` /
  `loadHistory` / `restoreFromHistory` are demo-guarded. Device Sync is
  `disconnect()`ed on demo entry (an existing coexistence connection could
  push peer state into the overlay) and `forceReconnect()`ed on exit.
  This closes kb_add/kb_del/reminder_add/reminder_del/task_*/template_*
  AND gives demo chat a demo KB (snapshot readers are demo-aware).
- **`DemoToolGuard`** (in DemoSeed.swift) — `accountScope(demoActive:)`
  GRDB predicate + `headerAccessible(_:)` (blocks BOTH directions) +
  `blockedMessage`. Applied in: InboxReadTool (account-scoped queries),
  EmailRead/Open/Reply/Forward/Archive/Delete (post-resolve header guard —
  closes the execute hole where stale global ChatIdTranslator numeric IDs
  let a demo chat act on REAL emails), EmailComposeTool (demo forces the
  demo account; normal mode excludes it — coexistence has TWO isPrimary
  rows), Contact*/ChangeSetting tools (blocked in demo).
- **SearchIndex** — `demoAccountScopeSQL` on the indexed
  `message_meta.accountId` in FTS candidates / FTS-only / date-scan legs;
  vector-only hybrid hits filtered by `headerIdInDemoScope` (headerId =
  `accountId:folderPath:messageId`). Covers email_search AND the inbox
  search UI ("Search All" spanned every account).
- **MemoryIndex** — `demoScopeSQL` (sessionId `demo:` range) on the FTS
  leg, the vec KNN leg (meta join), and `readByTimestamp` — memory_search /
  memory_read never cross modes (NULL sessionId = legacy real).
- **CalendarProviderDispatch** — demo resolves ONLY `DemoCalendarProvider`
  (new `CalendarBackend.demo` case); normal mode skips the demo entry.
  Without this, coexistence calendar_read leaked real events and
  calendar_event_create wrote to the REAL calendar.
- **DisabledRemindersStore** — demo operates on `demo.disabled_reminders_v2`
  (fresh map, no Device Sync broadcast); deleted on exit.
- **BackfillAIQueue** — `dispatchBatch` defers while demo is active (a
  queued real-session KB/action refine would run against the demo overlay
  and authenticate via the demo token); rows drain after exit.
- **DemoSeed.wipe** additions: `chatIdMapping` (demo range) +
  `pendingCalendarOperation` (demo account).
- Boot cost unchanged: everything is either an extra predicate on existing
  queries or gated behind `isDemoActive`; the wipe stays behind the
  `hasDemoData` PK short-circuit with indexed range deletes.

**Post-commit audit findings (2026-07-02, all fixed same day):**
- Fork path (`forkFromMessage`) minted an UNscoped sessionId — wrapped in
  `scopedSessionId` (the invariant: EVERY sessionId mint/lookup routes
  through it; grep for `UUID().uuidString` near chat code when touching).
- `ChatPillState.removeAllSessions()` now CANCELS `activeChatTask` (and
  drops resume checkpoints): a streaming agent loop re-samples the demo
  flag per tool call, so a task surviving the mode flip executes tools on
  the wrong side of the boundary. Teardown (+ Device Sync disconnect)
  moved from `completeSetup` to `start()` so the entry window is closed
  the instant `isActive` flips.
- In-flight refinements that complete DURING demo are dropped at their
  save sites (`KBRefinementService`, `AIPromptLearning`) — else the real
  refined KB/action text would be spliced into the demo overlay (visible
  in a recording). `registerAlarmsWithPushWorker` +
  `TaskEvaluationService.evaluate` are demo-guarded (empty demo KB would
  GC real task execution state / clobber alarm registrations).
- `DisabledRemindersStore` RMW ops capture `activeKeyV2` once (read+write
  same key even if the mode flips mid-operation).
- `DemoSeed.wipe` also deletes `draft` rows (demo compose autosaves).
- `MemoryIndexTests.vecCandidates_demoScope` pins the vec0 KNN
  subquery+JOIN shape (a planner rejection would silently degrade memory
  search to FTS-only in normal mode).
- Separately (same session): `BackendConfig.useDevServers` no longer
  defaults to dev on DEBUG builds once the debug menu is unlocked — ALL
  builds default to prod, dev is toggle-only. The old default silently
  pointed debug builds at dev.tabmail.ai, whose environment auth gate
  blocks `/demo/start` (not in `publicPaths`) → "Could not start demo:
  HTTP 401". Demo mint is prod-only by decision.
- Debug-menu entry (`startFromDebugMenu`) sets
  `DemoModeStore.enteredFromDebugMenu` (in-memory): RootView suppresses
  the DemoBanner for clean demo recordings; "Exit Demo Mode" and
  `resetCallBudget()` (reset the 50-call counter) live in the debug menu
  instead.

**Related:**
- The demo-auth mint/verify/throttle, the admin demo-stats readout, and the
  HMAC secret-rotation tooling all live server-side.
- ADR-IOS-008 (AI processing architecture — demo replicates the
  short-circuit).
- ADR-IOS-018 (PendingOperation queue — DemoProvider stubs the drain
  side).

---
