<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** The preserved demo-mode design below names
> `registerAlarmsWithPushWorker` and `TaskEvaluationService.evaluate`. Both symbols were deleted
> with the scheduled-task feature; see ADR-IOS-079. Their guard pattern still applies to any future
> KB-reading background job: demo data must not overwrite real execution state or registrations.

**Amended after this fragment was pinned (moved into this note on 2026-10-24, #288).** Where the text below and the pinned body differ, this text wins:

Added after the line beginning "search UI ("Search All" spanned every account).":

  *Amended 2026-10-23 (tabmail-ios#265, ADR-IOS-094):* the vector leg is
  scoped in SQL before the merge (`searchVecCandidates` joins the KNN
  results to `message_meta` with `demoAccountScopeSQL`, as MemoryIndex does);
  the post-merge filter (by then `contentKeyInDemoScope`) is deleted. A
  date sort's 4,096 candidates otherwise let the other mode's matches by
  meaning fill the limit before the filter dropped them.

Added after the line beginning "memory_read never cross modes (NULL sessionId = legacy real).":

  *Amended 2026-10-20:* `memory_search`'s page cache (`MemorySearchCache`)
  is kept per mode too: the tool reads the mode once and uses that reading
  for both the cache key and `MemoryIndex.search(demoActive:)`, since a
  compose edit runs the tool with no chat turn resetting the cache between
  modes. `DemoModeService.purgeDemoMemory` (demo exit and the orphan wipe)
  empties the cache after purging the demo turns, so none is served again.
  A demo start runs the orphan wipe before it turns demo on (a force-quit's
  launch wipe clears the main database only), and **fails closed**: if
  `MemoryIndex.purgeForSessionPrefix` cannot confirm every demo turn is gone,
  `DemoModeService.activate` leaves demo off and throws (the login screen's
  start error; the user retries). Demo exit and a real sign-up only log the
  failure: real mode never reads `demo:` turns, and the next demo start wipes
  them first.
  *Amended 2026-10-21 (#231, late writers):* a chat write still running from
  a demo that has ended could bring its turn back after the next demo's
  confirmed purge. Two writers, two fixes. (1) Memory self-heal Stage A
  (`ChatStore.historyTurnIdsForSelfHeal`) leaves `demo:` sessions out: demo
  history is discarded at exit, so there is nothing to repair, and a demo turn
  it loaded could be indexed after the wipe. (2) Chat appends carry an
  in-memory **admission** (`DemoModeStore.Admission`): a demo run opens one when
  `isActive` turns on, `DemoModeService.exit` revokes it FIRST (before its
  wipes), and it never reopens (a run counter). The three send paths in
  `DynamicIslandChatButton` capture `chatAdmission` with the session id
  (compose's own user-turn persistence included) and pass it to
  `ChatStore.appendTurn(_:admission:)`; `DemoModeStore.admits` is checked inside
  the chatHistory write transaction and inside `MemoryIndex.indexTurn`'s
  memory.db write transaction, so each write lands before the cleanup that
  deletes it or is refused (`ChatStore.DemoTurnRefused`). A `demo:` turn with
  no admission is refused; any other turn is real history and always admitted.
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

**Amendment 2026-10-21 — guided tutorial, scripted, no AI (owner V5):**
- **Guided tutorial on the demo.** `TutorialCoordinator` (Services/Tutorial)
  runs three parts (act on email, reuse a reply, ask anything) on the
  seeded demo inbox through the native screens, advancing only on real
  events: the receipt leaves the demo Inbox, DailyTech's tag changes, a
  local Sent row appears, a confirmed template is persisted, the source
  email opens. Sample messages are named by `DemoSeed.TutorialFixture`
  ids, never by rendered strings. Progress lives in `TutorialProgress`
  (UserDefaults: version, completed parts, discoveries, first-run welcome); an
  unfinished part restarts from its beginning. The full-screen welcome
  is armed only by the fresh-install branch of
  `TabMailApp.prepareSessionStorageForLaunch`; everyone else gets the
  sidebar row. Finish and Skip tutorial both end in
  `DemoModeService.exit()`; the run state is cleared only after it, so
  the plain demo's consent screens never flash in between. Copy says
  "1 of 3", never "lesson" (owner).
- **Scripted, no AI, no consent (owner 2026-10-21).** The tutorial makes
  no AI or backend call and shows no consent screen: the age and terms
  screen and the AI choice stay where they are (sign-in, and the plain
  demo before seeding). `DemoModeStore.isTutorialPractice` (in memory,
  set before the demo activates, cleared on exit) is the switch:
  `BackendClient.currentAuthToken()` returns nil, so no demo token is
  minted (`DemoModeService.start(mintToken: false)`), and the two
  builders that would send without a token (`transcribeDictation`,
  `makeCompletionsRequest`) throw `.unauthorized` before building.
  The seeded, pre-written tags and summaries show whatever the demo AI
  choice (`hidesAIContent`), and `completeSetup` opens the subscription
  gate so the chat pill is not locked.
- **Scripted chat.** The inbox chat's input is filled in and read-only
  (`TutorialChatInputBar`, owner: "in real use you speak or type; here it
  is filled in"); message and draft chats show only the note. Send runs
  `TutorialChatScript` in place of the AI call inside `sendAgentChat`, so
  turns render and persist like an AI reply: the template answer shows
  the real `TemplateCreateTool` card with the practice reply as written
  in compose (`practiceReplyAuthored`), the flight answer cites Jordan's
  seeded email (`[Email](N)` pill), "What can you do?" is a fixed list.
  Dictation is off in the tutorial (`canDictate`), and no tip events are
  donated.
- **No permission prompt during the tutorial.** The launch notification
  request waits while the welcome is pending; RootView asks once the
  welcome is skipped or the tutorial ends. Compose skips Contacts
  access and name lookups while the tutorial runs.
- **Re-tags of demo samples never teach (bug fix).** A demo re-tag used to
  enqueue an `actionRefine` row; drains are deferred while the demo runs,
  so the row drained after exit against the real `user_action` prompt.
  `BackfillAIQueue.enqueueActionRefine` now refuses a demo sample
  (`ActionRefineSnapshot.isDemoSample`). The `enqueueActionRefine`
  chokepoint in the call accounting above therefore no longer consumes a
  demo call. (A drain-time drop for rows queued by older builds was
  considered and deleted the same day: that population is rare and it
  behaves as every shipped build already did.)
- **Demo sends and actions drain (bug fix).** `registerDemoProviders`
  gives the demo account a work queue; the outbox and action drains skip
  accounts without one, so every demo send had stayed queued and never
  reached Sent. `DemoProvider.send` writes nothing: the outbox's
  optimistic Sent header is the one sent copy. `DemoProvider.move` is a
  no-op: the optimistic move already placed the row and the demo has no
  server. It used to re-key the row to a destination-shaped id, which
  nothing followed once moves drained, so Undo of a drained demo archive
  did nothing. Demo rows keep their id for the life of the demo.
- **Tips hidden in the demo** (supersedes "TipKit shown-state persists"
  being visible in demo): `OnboardingTipGate.onboardingComplete` is
  `allOnboardingGatesPassed && !isActive`, so no tip (each shows once) is
  used up on sample mail. The two user-label tips gained the same rule.
- **Signed-in replay and notifications.** The sidebar row starts the
  tutorial next to a live account (banner hidden while the tutorial
  runs, its coach cards carry Skip). A notification tap during the
  tutorial ends it; the pending deep link stays stored and the restored
  inbox's `MailNavigationView` opens the email on appear.
- **Smoke-test round 2 (owner 2026-10-21).** Replay moved from the
  sidebar to the debug menu ("Replay Tutorial"); the sidebar row shows
  progress only and is gone once every part is done. The practice reply
  is sent with no undo hold (`queueSend(holdsForUndo: false)`, stored
  `holdUntil` NULL, so the drain claims it at once and the toast offers
  no Undo); every other send keeps the hold. The coach card is a dark
  translucent HUD in both appearances.
- **Parts found on their own count as done (owner 2026-10-25).** Outside
  the tutorial, doing a part's moves in the real app completes it, as if
  the part had been taken: part 1 needs both an action-tag tap
  (`executeTaggedAction`, inbox and message view) and a tag change from
  the hold menu (`applyManualTag`, both view models), each recorded on
  its own; part 2 a created template (`PromptStore.addTemplate`, the
  funnel for settings, marketplace and chat; Device Sync merges do not
  count); part 3 a message sent in the inbox chat. `TutorialDiscovery`
  in `TutorialProgress` (UserDefaults, version-gated like completion; a
  write after a version bump drops the older version's progress first).
  Ignored while the tutorial runs: its own steps complete their parts.
  The step's target tag and the Chat pill carry a pulsing glow ring
  (`TutorialGlowRing`, owner: "blink or a little bit of glow"; replaced
  by the moving ring below the same day).
- **Smoke-test round 3 (owner 2026-10-25).** Hints move: every hint is
  `TutorialPulseRing`, a steady outline plus a ripple that grows outward
  and fades ("something that's moving is more likely to catch
  attention"). Rings: the step's tag, the Chat pill, the chat Send
  button, the compose Send and Use Suggestion buttons, the email pill
  in the part 3 answer and its Open Email link. No "Finish later" on
  any card (Skip tutorial is always at the top right); part ends show
  See rule / See template and Next. Part 1's retag adds a sample delete
  rule to the demo overlay's `deleteRules` (dropped on exit with the
  overlay) and See rule opens Settings' Action Classification screen
  with that rule ringed and a coach card saying it is a sample. The
  screen shows the rules only: the thresholds (real settings, synced),
  Compact now (an AI call) and Reset are hidden. No AI, nothing
  persisted. Part 2's compose step shows an Edit prompt ("Say I
  can't make it") in the read-only chat input; Send shows the working
  pulse for a short delay (`TutorialChatScript.editDuration`) and swaps
  the suggestion for a scripted decline through the compose's own
  `onDraftUpdate` path; Use Suggestion stays locked until then
  (`MailGesture.useSuggestion`). The template is "Polite decline".
  The compose cover did not re-run its coach card when the edit landed
  (measured with debug logs: the inbox card re-ran, the compose card did
  not, while ComposeView itself redrew), so the compose card's identity
  follows `replyEdited` (`.id`).
- **Smoke-test round 4 (owner 2026-10-25).** Navigation is off while
  the tutorial runs: the inbox's back button (to the folders) is hidden,
  and triage, compose, filter and search in the inbox and compose, reply
  and archive in the message view are disabled and dimmed
  (`tutorialLockedNavigation`). The message view keeps its back button:
  a row tap opens any message, and back is the only way out of one
  without a card. The open inbox chat covers the coach card at full
  height (it was laid out below the card, too short to read in part 3);
  the chat-hosted card is gone, and the chat's rings lead instead:
  Send, the email pill, and the close button when the next move is a
  card button (`highlightsChatClose`: Template saved, and Ask anything
  once "What can you do?" was sent, which is now asked once, like the
  flight question). With the chat closed after the flight question, the
  inbox card says "Check the original" and the Chat pill is ringed. The
  email pill's ring goes while its popover is open, so only Open Email
  is ringed.
- **Smoke-test round 5 (owner 2026-10-25).** The template proposal's
  Create is ringed (`highlightsTemplateCreate`), and so is Done on the
  See rule and See template sheets (`TutorialSheetDoneButton`). The
  scroll to a tag step's row is re-issued whenever the list's geometry
  changes while a step targets a row (`TutorialInboxScroll`): on device,
  a Replay from the debug menu asked for the scroll as the inbox first
  appeared, while the list was still laying out and the coach card was
  settling its height, and the offset stayed 0 (debug log, 2026-10-25).
  A one-shot scroll on appear is not enough; the simulator happened to
  settle in time.
- **Considered and dropped the same day: consent once.** A variant asked
  the age/terms and AI screens before the AI parts and carried the
  outcome to sign-in (`CarriedConsent`). The owner chose a scripted
  tutorial instead; nothing of it shipped, and the demo-prefixed consent
  gates above stand.

**Related:**
- The demo-auth mint/verify/throttle, the admin demo-stats readout, and the
  HMAC secret-rotation tooling all live server-side.
- ADR-IOS-008 (AI processing architecture — demo replicates the
  short-circuit).
- ADR-IOS-018 (PendingOperation queue — DemoProvider stubs the drain
  side; since 2026-10-21 the demo drain runs, see above).

---
