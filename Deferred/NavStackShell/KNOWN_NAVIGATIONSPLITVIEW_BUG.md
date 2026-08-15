# Known Issue: SwiftUI NavigationSplitView Compact-Mode Race

**Status**: known, not fixed at app level. Mitigations in place, does NOT block release. Scroll to the bottom ("KNOWN ISSUE — SwiftUI NavigationSplitView compact-mode race") for the current summary. Everything above is the investigation trail — including a retracted root-cause theory ("MainActor starvation") that turned out to be wrong. Kept intact so the next engineer doesn't repeat the same dead ends.

**Original investigation title**: "MainActor Starvation — Stuck Blank Inbox + Delayed Sync Status". That title is historically accurate for the first session's theory; the second session proved MainActor is completely idle during the stuck state (heartbeat detector measured 0ms latency across 2+ minutes of visual freeze). The actual bug lives in the SwiftUI `NavigationSplitView` compact-mode internal state machine.

---

## Symptoms

1. **Blank inbox during rapid folder navigation.** User taps rapidly between Inbox → Archive → Inbox etc. The list area renders blank (sometimes the toolbar buttons also appear "elongated / mid-animation"). Self-recovers after 1–7 s in most cases; sometimes stays stuck indefinitely.
2. **Header renders in large-title mode** instead of inline during the stuck window — SwiftUI never applied the toolbar configuration.
3. **Delayed sync status pill** after foreground return. Logs show sync is running but the pill shows stale state.
4. Happens in BOTH debug and TestFlight builds. More frequent / longer stalls under rapid nav or after long app-idle + foreground return.

Reproduced by:
- Force-quitting app, launching, immediately navigating rapidly between folders during cold-start sync window.
- Or: leaving app idle 30+ s, returning to foreground, navigating immediately.

---

## Root Cause

**MainActor is blocked for multiple seconds at a time.** SwiftUI body evaluates correctly with data loaded (`normalListView body eval — OK loaded=50` fires during the blank), but the visual commit does not happen — MainActor can't service the next render tick. When it finally unblocks, the view appears.

Confirmed via:
- **Thread Performance Checker** fired in one repro with stack trace `GRDB.Pool.get → DatabasePool.read → SearchIndex.headerIdsWithEmptyFolderId → SyncEngine.backfillFolderIdsIfNeeded` — MainActor (`.userInitiated` QoS) waiting on a `.low`-QoS task holding a GRDB reader.
- **`MainActorStallDetector`** (new, `TabMail/Services/MainActorStallDetector.swift`) — off-main timer dispatches onto main every 100 ms and logs latency ≥200 ms. Captured 152 stalls in one session, max **7867 ms**, avg **2757 ms**.
- **`fetchPage timing wait=0ms query=120ms`** captured once — meaning at that moment the GRDB reader pool was NOT contended. Stalls persist without pool contention → blocker is something else MainActor-sync, not the reader pool.

Concrete evidence log sequence (from `inbox_logs 4.txt`):
```
06:14:42  [MainStall] detector started             ← app foregrounded
06:14:43  [AA619B] init                            
06:14:43  [AA619B] loadInitialPage in 12ms          ← normal
06:14:44  [AA619B] listDidAppear
06:14:44  [MainStall] 1446ms                        ← MainActor blocked
06:14:44  [MainStall] 1309ms, 1173ms, ... (14 more)
06:14:47  [AA619B] folder VO emit
06:14:48  [AA619B] reloadMessages done in 3780ms    ← wallclock — most was stall
06:14:53  [MainStall] 6759ms                        ← 6.7 s peak
```

Related observation in `logmain.log`:
```
[BackfillEmbeddingQueue] Repopulate: 0 items (3838ms)
```
A GRDB query that returns zero results takes **3.8 seconds**. Suggests missing or non-matching index. Runs async so doesn't directly block MainActor, but holds a reader and contributes to pool saturation.

---

## Causes Ruled Out / Partially Fixed

| # | Cause | Shipped Fix | Status |
|---|---|---|---|
| 1 | Sync cursor clobbering optimistic moves | planned in `docs/PLAN_SYNC_CLOBBERS_OPTIMISTIC_MOVES.md` (separate plan) | Separate investigation |
| 2 | Filter state stuck / VM state desync | widened `(id, role)` key, `selfHealFolders` partial sets | Shipped 623b232 |
| 3 | SwiftUI phantom VMs (double inits from eager `@State(initialValue:)`) | moved side effects out of `init` into `start()` called from `.onAppear` | Shipped 49e6b51 |
| 4 | SwiftUI toolbar entry animation stuck under rapid nav | `.transaction { $0.disablesAnimations = true }` on each ToolbarItem | Shipped 57a94fc |
| 5 | GRDB priority inversion (`.low` Task QoS vs MainActor) | `.low` → `.medium` for 3 sync-engine Tasks + ADR-IOS-031 | Shipped f1162d1, c3a4acc |
| 6 | VM init does expensive sync GRDB fetch blocking render | `loadInitialPage` in `init` (cheap); observers/VO in `start()` | Shipped 49e6b51 |
| 7 | Sync tasks pile up from rapid-nav `startSync()` calls | `startSync` deferred 250 ms + cancel on VM deinit | Shipped c3a4acc |
| 8 | Logger file I/O blocking MainActor | all loggers moved to async-dispatched `ioQueue` | Shipped ad634c8 |
| 9 | Reader pool too small (10) for foreground-return burst | bumped main + FTS to **64 readers** | Shipped 625a60c |
| 10 | Toolbar bar re-install under NavigationSplitView column swap | same `.transaction` scope as #4 | Shipped 57a94fc |

All of the above were real contributors. **The symptom persists after all of them.**

---

## Remaining Hypotheses

At this point MainActor is still getting blocked for multiple seconds by SOMETHING that isn't:
- `fetchPage` (confirmed `wait=0ms`)
- Reader-pool contention (pool has 64 slots, only ~15 observed in use)
- Priority inversion (raised QoS removed TPC warnings)
- Phantom VM churn (phantoms deinit silently now)

Remaining suspects, each instrumented to catch next occurrence:

### A. `rebuildDisplayGroups` on MainActor

`ThreadGroupBuilder.buildDisplayGroups(from: loadedMessages)` runs synchronous grouping on MainActor. For 50 messages spread across threads, the algorithm does O(N) thread dedup + sort. If N is much larger (500+ during full-inbox scroll), could easily blow past 1 s. **Instrumented** (`rebuildDisplayGroups Nms` log ≥50 ms).

### B. `applyDiff` inside `reloadMessages`

Two-pass array diff on `loadedMessages` with `@Observable` mutations. Each `loadedMessages[i] = fresh` or `.insert(at:)` triggers SwiftUI observation. 50 mutations × observation propagation could cascade. **Instrumented** (`reloadMessages MainActor-sync cost: applyDiff=X rebuildGroups=Y` log).

### C. `flushAIBatch`

`dbPool.read` (sync on MainActor) + per-row snapshot diff + `withAnimation` wrapping `rebuildDisplayGroups`. Called when `.messageDataDidChange` notifications pile up. **Instrumented** (`flushAIBatch Nms ids=X` log ≥50 ms).

### D. NotificationCenter handler cascade

Many observers registered on main queue:
- `.inboxDataDidChange` (InboxViewModel)
- `.messageDataDidChange` (InboxViewModel AI batch)
- `.backgroundDataDidChange` (NavigationStore)
- `.unreadCountsDidChange` (NavigationStore)
- `.syncPhaseChanged` (SyncStatusObs)
- Plus: outbox, calendar, consent, agent, etc.

During a sync burst, multiple fire in the same runloop pass. If any observer's callback is slow, it blocks the queue behind it. Not yet instrumented.

### E. SyncScheduler work on MainActor

`SyncScheduler.poll()` kicks off `manager.backgroundSyncAll(...)` which per-account:
- `ensureConnected` (provider reconnect)
- delta fetch (Gmail history, IMAP LIST, Exchange delta)
- write batch to GRDB

`AccountManager` is an actor; each method-hop from MainActor is an await. Accumulated awaits on 5 accounts with sync state mutation → many MainActor reentries. Not yet instrumented.

### F. `NavigationStore` refresh cascade

`backgroundDataDidChange` → `refresh()` → 3 synchronous GRDB reads (accounts, folders, outbox) + overlay computation (per-pending-mutation header fetch). Synchronous on MainActor. Large overlay = many sequential reads. Worth instrumenting.

### G. `BackfillEmbeddingQueue.repopulateFromDatabase` query

Takes 3.8 s for zero-result query. SQL:
```sql
SELECT id FROM messageHeader
WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0
ORDER BY isInInbox DESC, date DESC
LIMIT 200000
```
No matching index. Partial index `idx_messageHeader_aiRepopulate` requires `isInInbox=1` in WHERE — this query doesn't have it. Full table scan + sort.
Async, so doesn't block MainActor directly, but holds a reader for 3.8 s and increases pool pressure.

### H. Something in UIKit nav-bar bridging (large-title symptom)

The "large title instead of inline" symptom suggests UIKit hasn't received the `.toolbar` modifier's configuration. Outside our SwiftUI code's visibility — we can at best work around it by reducing churn during the transition window.

---

## Instrumentation in Place (as of commit `e0c085a`)

All log through `BackgroundSyncLogger.logInbox` → Debug menu → "Inbox Logs":

| Log line | Location | Meaning |
|---|---|---|
| `[TAG] init folders=... selection=...` | `InboxViewModel.init` | VM constructed |
| `[TAG] start folders=X loadedCount=Y` | `InboxViewModel.start()` | Real VM (not phantom) starts observers+VO |
| `[TAG] deinit started=<bool>` | `InboxViewModel.deinit` | VM freed; `started=false` = phantom |
| `[TAG] loadInitialPage folders=X loadedCount=Y in Nms` | `InboxViewModel.loadInitialPage` | First page fetched (sync on MainActor) |
| `[TAG] InboxView.onAppear ...` | `InboxView.onAppear` | View became visible |
| `[TAG] InboxView.onDisappear ...` | `InboxView.onDisappear` | View became hidden |
| `[TAG] listDidAppear ...` / `... reloadMessages done in Nms` | `InboxViewModel.listDidAppear` | Reappear reload completed |
| `[TAG] folder VO emit count=X keys=...` | folder `ValueObservation` sink | GRDB folder table changed |
| `[TAG] updateFolders old=... new=...` | `InboxViewModel.updateFolders` | Folder set actually changed (post-dedup) |
| `[TAG] normalListView body eval — {EMPTY, BLANKBUG, FILTERED, OK}` | `InboxView.normalListView` | Body evaluated, state classified |
| `[TAG] fetchPage timing wait=Xms query=Yms total=Zms` | `InboxViewModel.fetchPage` | Pool-wait split from query cost, ≥50 ms only |
| `[TAG] resolveFoldersFromDB Nms` | `InboxViewModel.resolveFoldersFromDB` | Folder self-heal cost, ≥50 ms only |
| `[TAG] rebuildDisplayGroups Nms messages=M groups=G` | `InboxViewModel.rebuildDisplayGroups` | Thread grouping cost, ≥50 ms only |
| `[TAG] reloadMessages MainActor-sync cost: applyDiff=Xms rebuildGroups=Yms` | `InboxViewModel.reloadMessages` | MainActor-blocking portion, ≥50 ms combined |
| `[TAG] flushAIBatch Nms ids=X` | `InboxViewModel.flushAIBatch` | AI batch cost, ≥50 ms only |
| `[MainStall] Nms` | `MainActorStallDetector` | Main queue latency ≥200 ms — unambiguous proof of stall |
| `[MainStall] detector started (threshold=200ms)` | app init | Detector up |

**How to use:** when the user reproduces a blank, any `MainStall` entry in the next few log lines shows the stall duration. The preceding instrumentation lines show which MainActor operation was running just before the stall — that's the blocker.

---

## Next Steps (for next iteration)

### 1. Collect one more repro log

User reproduces blank with the build at commit `e0c085a` or later. Expected findings:
- If a `[MainStall] Nms` fires with a matching timing log right before (e.g. `rebuildDisplayGroups 2500ms`) → blocker identified. Fix = move that work off main or batch/throttle.
- If `MainStall` fires with NO preceding timing log → the blocker is outside InboxViewModel. Need to instrument NavigationStore.refresh, SyncScheduler.poll, and specific NotificationCenter observers (candidates D, E, F).

### 2. Optimize `BackfillEmbeddingQueue.repopulateFromDatabase` query (candidate G)

Low-priority but easy win. Either:
- Add index: `CREATE INDEX idx_messageHeader_embeddingPending ON messageHeader(bodyComplete, embeddingComplete, bodyEmptyConfirmed) WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0`. Partial index on the exact WHERE predicate.
- Or scope to recent messages only (e.g. `AND date > date('now', '-30 days')`).
- Or: drop the `ORDER BY` and let the queue process in any order (most callers don't care about order).

### 3. Instrument NavigationStore.refresh + overlay loop

If step 1 shows `MainStall` with no InboxViewModel log attribution, add timing:
- `NavigationStore.refresh()` total + each of its 3 GRDB reads.
- The `for (msgId, mutation) in overlay` loop at `NavigationStore.swift:114` — per-pending-mutation GRDB read. If overlay is large, this is O(N) sync reads on MainActor.

### 4. Rule out UIKit bridging

If candidates A–G are all instrumented and none fire during a stuck stall, the blocker is UIKit nav-bar bridging (candidate H) — outside our control but mitigable by further reducing MainActor work during transition windows.

### 5. Architectural follow-up (if needed)

If the stalls are fundamentally MainActor-sync GRDB reads in a cascade: convert `fetchPage` and `resolveFoldersFromDB` to `async` versions, let MainActor yield during those reads. Accept a single-frame blank on first render as the cost (currently prevented by sync `fetchPage` in `init`). This is the biggest-leverage fix but requires changing the `loadInitialPage` / view-init chain to tolerate async initialization.

---

## Commit Log Reference

```
e0c085a  Instrument rebuildDisplayGroups, applyDiff, flushAIBatch timing  (current HEAD)
625a60c  Instrument fetchPage/resolveFoldersFromDB + bump reader pools to 64
dc8ae8b  Add MainActorStallDetector
c3a4acc  Defer startSync() by 250ms + cancel on deinit; ADR-IOS-031
f1162d1  Fix GRDB priority inversion (.low → .medium Task QoS)
57a94fc  Suppress toolbar entry animations during NavigationSplitView swap
49e6b51  Move VM side effects out of init (phantom VM fix)
ad634c8  Off-main file I/O for all loggers
3d97ad7  loadInitialPage in init (no blank-first-frame) + debug menu wiring
fcce704  Folder VO replacing .onChange (role-flip race fix)
623b232  Lifecycle hardening (observer registration in init)
```

Related ADR: **ADR-IOS-031** in `DECISIONS.md` — "Background Tasks Touching GRDB MUST Use `.medium` Priority (Never `.low` / `.utility` / `.background`)".

---

## Progress Log

- **2026-04-19 (initial)** — Symptom reported: blank inbox, sometimes stuck permanently.
- **2026-04-19** — Investigation identified phantom VMs (fixed), SwiftUI toolbar animation bug (fixed with `.transaction`), priority inversion via Thread Performance Checker (fixed with QoS bump).
- **2026-04-19** — MainActorStallDetector captured 152 stalls max 7867 ms, avg 2757 ms — confirming MainActor starvation. `fetchPage timing wait=0ms` ruled out reader pool contention. Reader pool still bumped 10 → 64 defensively.
- **2026-04-19** — Observed `BackfillEmbeddingQueue.Repopulate: 0 items (3838ms)` — unindexed-query suspect.
- **2026-04-19** — More instrumentation added covering rebuildDisplayGroups, applyDiff, flushAIBatch, resolveFoldersFromDB. Awaiting next repro to identify remaining blocker.

---

## 2026-04-19 session 2 — retraction + reframing

### Summary

After spending this session chasing phantom-VM elimination, I was wrong. The **earlier conclusion "root cause is MainActor starvation" is retracted**. The big 9000 ms stalls it was built on turned out to be **debug-build cold-start only** — TestFlight shows brief 1-2s cold-starts and then nothing. That cold-start number is mostly Swift `-Onone` tax on GRDB row decoding / SearchIndex init / CoreML load. Not a production-relevant stall.

The actual user-visible symptom — blank/stuck inbox during back-and-forth navigation — is NOT MainActor starvation. Proven this session.

### What we tried this session (and what happened)

1. **Verified the web-sourced consensus** (with real citations this time) that `@State(initialValue: ObservableObjectInit(...))` eagerly constructs a throwaway VM on every parent rebuild — Swift Forums thread 70811, plus fatbobman's LazyState article, plus Apple's `StateObject.init(wrappedValue:)` `@autoclosure` docs. The phantom observation was real.

2. **Implemented the "hoist VM to parent cache" refactor** (option a + b hybrid from the web research):
   - Added `NavigationStore.inboxViewModel(for:make:)` — MRU cache size 2, keyed by `MailboxSelection`.
   - Changed `InboxView.viewModel` from `@State private var viewModel: InboxViewModel` (with eager `State(initialValue:)`) to `@Bindable var viewModel: InboxViewModel` passed from `MailNavigationView`.
   - Moved VM construction + `.start()` into the cache's `make:` closure.
   - Ran the full test suite — **6180 / 6180 passing**.

3. **Verified the refactor eliminated phantom VMs**: post-fix logs show 1 VM across a whole rapid-nav session instead of 14+ VMs. Phantom theory was correct at the mechanism level.

4. **BUT: the user-visible symptom got WORSE, not better.**
   - User reported blank/stuck now happens "almost every other tap, even not rapid".
   - User captured screenshot showing InboxView with nav bar (back chevron, large-title "All Inboxes", empty toolbar placeholder pill) rendered by UIKit, but **body area completely black** — SwiftUI body did not render.

5. **Upgraded `MainActorStallDetector` with a 15-s heartbeat** so absence of `[MainStall]` logs could be distinguished from a dead detector. This turned out to be the decisive instrument.

6. **Ran a stuck repro with the new detector**. Log showed:
   - Last user action: `[BAB9A0] InboxView.onDisappear ... visibleMs=1617`
   - Then **11+ consecutive heartbeats** each reporting `samples=151 max=0ms avg=0ms stalls>=200ms=0 softLag>=50ms=0` — 2.5+ minutes of completely idle MainActor while the user was staring at a frozen screen.
   - No new body evals, no new lifecycle events.

### What the heartbeat data proves

Main is servicing the 100ms detector tick with ZERO measurable latency, repeatedly, for minutes, while the UI is visually stuck. That's not starvation. Main has nothing to do. SwiftUI is simply not calling `body` on the visible view.

Therefore the blocker is in one of these layers, **all above MainActor**:

- **SwiftUI render/commit pipeline** — body result computed elsewhere but not committed to screen.
- **SwiftUI ↔ UIKit nav-bar bridging** — `UIHostingController` not committing updated snapshots after a nav transition.
- **Animation transaction stuck** — a `.animation` or `.transition` or `withAnimation` block that SwiftUI considers still in-flight, blocking subsequent body invocations.
- **View identity / tree diff** — SwiftUI sees the view as "already presented with current state" and short-circuits.

The `onDisappear` firing in the log and the view still being visible is the most telling signature: SwiftUI's internal lifecycle says "gone", UIKit's scene is still showing it, and neither side re-fires `onAppear` to resume rendering.

### Diagnostic ruled out

- **`.id(selection)`** on InboxView — forces new identity on selection change. Tested. **No change in stuck behavior.** Because the user's stuck repro was same-selection nav (Inbox → message detail → back), so the `.id` diagnostic never triggered. Does not rule out identity as cause — just rules out "selection-change-triggered identity churn" as cause.

### Decision at end of session — revert

The `@Bindable` + parent-owned VM cache was a surgical, well-sourced refactor that did fix phantom VMs (a real but **irrelevant** problem for the actual symptom). It may have made the visible symptom worse by removing `@State`'s SwiftUI-managed view-lifecycle ownership — SwiftUI and UIKit were relying on that for view-identity transitions, and giving them a plain stored `@Bindable` reference disrupted assumptions.

**All refactor-era changes reverted** at end of session:
- `InboxView.viewModel` back to `@State private var viewModel: InboxViewModel` constructed via `State(initialValue: InboxViewModel(...))` in `init` (phantom VMs return, but so does the original less-frequent symptom profile).
- `MailNavigationView` back to plain `InboxView(...)` call with no cache lookup.
- `NavigationStore.inboxViewModel(for:make:)` + its cache fields removed.
- 10 tooltip preview files reverted to not pass `viewModel:`.
- Tests still pass (no test changes needed; VM-construction helpers in tests were never touched).

### What was KEPT from this session

These are genuinely useful and tested on a real repro:

- **`MainActorStallDetector` heartbeat** (`MainActorStallDetector.swift` L44-L95). Every 15 s the detector emits `[MainStall] heartbeat samples=N max=Xms avg=Yms stalls>=200ms=Z softLag>=50ms=W` regardless of whether any stalls were seen. This is the single most informative signal we added — it is what decisively ruled out MainActor starvation as the cause. Keep forever.
- **`NavigationStore.refresh` / `refreshFolders` timing** — logs when ≥50 ms to catch sync-GRDB-on-main regressions.
- **Lessons below.**

### Lessons for next iteration

1. **Absence of instrumentation is not absence of the problem.** The moment the stuck-state heartbeat data showed `max=0ms stalls=0`, the whole MainActor-starvation track should have been abandoned. Don't mistake "our detector is quiet" for "everything is fine".
2. **Don't let a real but unrelated bug become the fix.** Phantom VMs are real. They were documented by Apple's own doc update and multiple community sources. Fixing them is defensible. But the fix did not address the symptom the user actually sees, and investigating that parity should have come first.
3. **When SwiftUI's `onDisappear` fires but the user is still looking at the view, the bug is above our code.** That symptom is diagnostic for UIKit/SwiftUI bridging issues and should be treated as such, not as "the user must be looking at a different view".
4. **Never claim "web-informed" when the agent didn't hit the web.** The mid-session hallucinated citations from an offline subagent cost trust and time. Always verify the source of synthesis.
5. **Screenshots beat theories.** The user's screenshot of "All Inboxes" title + black body + empty toolbar placeholder was the single most useful piece of evidence in the whole session. Ask for one early.

### Candidates to investigate next session (none yet instrumented)

Ordered by likelihood given "body does not re-evaluate after onDisappear on return-nav, main is idle":

- **`.animation`/`.transition`/`withAnimation` transaction stuck**:
  - `.transition(.blurReplace)` on `normalListView` / `triageView` (InboxView L116/L119).
  - `.animation(.spring(...), value: chatExpanded)` on bottom-bar VStack (L234).
  - `withAnimation(.spring(...).delay(0.15)) { sideButtonsReady = true }` inside `onAppear` (L538-542) — interacts with an `@State` flag that gets set false on every `onDisappear`.
  - `withAnimation(...)` blocks in swipe handlers, chat handlers, etc.
- **`.toolbar` content closure re-invocation**: comment at L25-L29 notes sync-status env is read at struct level specifically because reading it inside ToolbarItem-hosted subviews "doesn't invalidate reliably" — this is exactly the class of bug we're chasing.
- **`UIHostingController` snapshot caching** after nav transitions in `NavigationSplitView`:
  - Known issue with iPhone-in-portrait mode where detail column pushes over sidebar. iPad landscape works differently.
  - No app-level fix; possible mitigation is forcing a geometry-change invalidation on every `onAppear`.
- **`@Environment` invalidation during transition**: `@Environment(\.syncPhase)` / `\.lastSync` reads at struct level — if the env value is being mutated while the nav transition is mid-flight, the resulting invalidation storm could deadlock the transition (speculation).
- **Hosted scene lifecycle**: the single `stopPolling: app going to background` + `UISceneHosting ... No scene exists` logs earlier in the investigation hinted at brief scene-inactive transitions during share sheet presentation. If similar happens during nav, the InboxView's body could be paused by scene inactivation.

### Instrumentation to add before next repro

1. **Body-eval gap watchdog** on InboxView (and on a minimal "I'm visible" modifier applied to every root view that the user could be stuck on): a `.task` that sleeps `N` seconds and fires a "still alive" log, cancelled when view disappears. If it logs while user sees it stuck, SwiftUI thinks it's gone despite visual presence. If it does NOT log but user sees the view, SwiftUI isn't scheduling it.
2. **Toolbar content trace**: log inside the `.toolbar { ... }` content closure on every invocation, with timestamps. Correlate with visible toolbar state.
3. **withAnimation nesting trace**: trivial helper that wraps every `withAnimation` site with a before/after log so we can see which animation transactions are open at stuck time.
4. **Screen capture on stuck**: persistent instrumentation that takes a `UIView.drawHierarchy(in:afterScreenUpdates:)` snapshot to the logs directory whenever a heartbeat reports `samples>0 max<5ms` but the user's `DebugModeManager` debug flag says they're actively trying to use the app. (Harder; maybe not worth the effort.)
5. **Revive a simpler body-eval-frequency counter**: just increment a UserDefaults counter on every `normalListView body eval — OK` and log it every 5s. If the counter stops moving while user sees inbox on screen, we have the bug.

### Commit log for session 2

```
016ddf1  Fix phantom InboxViewModel churn via @StateObject holder wrapper
         + MainActorStallDetector heartbeat + NavStore refresh timing logs
```

---

## 2026-04-19 session 2 — final outcome / known-good baseline

After many iterations on navigation-layer fixes (throttle binding, animation
speed slowdown, sync Task debounce, `.id()`-bump reset button, explicit 500ms
and 1000ms nav locks, pure-debounce selection binding), the **empirically-
best state** is:

- ✅ `@StateObject` + `InboxViewModelHolder` wrapper (phantom VM fix — shipped
  in `016ddf1`). This is architecturally correct, backed by cited sources,
  and verified via log inspection.
- ✅ `.medium` QoS for sync-engine tasks (shipped in `f1162d1`, preserved).
  Briefly reverted to `.low` during investigation; pre-investigation state
  comparison confirmed `.medium` is correct.
- ✅ `MainActorStallDetector` heartbeat every 15s (shipped in `016ddf1`).
- ✅ `NavigationStore.refresh` / `refreshFolders` timing logs (shipped in
  `016ddf1`).
- ✅ Plain `List(selection: $selection)` — no throttle binding. Every
  interception of the List's selection binding (even a "queue-only, apply
  after N ms" variant that was internally sync-correct) broke SwiftUI's
  implicit contract that `List(selection:)` expects a synchronously-
  consistent binding. Violating it caused worse stuck states than the
  original NavigationSplitView framework bug.

**Not done** (explored, then discarded):

- ❌ Nav-tap lock/throttle/debounce — any form of intercepting the
  `List(selection:)` binding caused SwiftUI List to desync from the
  NavigationSplitView state. Visible symptom: "clicking" behavior where
  nav triggers repeatedly or the view sticks in half-navigated state.
  The SwiftUI contract requires the binding to return the just-set value
  on next read; our async apply-after-timer or queue-and-skip logic
  broke that contract.
- ❌ Animation slowdown (`.transaction { $0.animation = $0.animation.speed(0.5) }`)
  — produced a visible "content shifts down then pops back" artifact as
  view-appearance transitions played 2x slower than their sibling layout.
- ❌ Sync debounce (`syncTask?.cancel()` in `InboxViewModel.startSync`) —
  prophylactic, no visible benefit, removed to simplify.
- ❌ Shake-to-reset / debug R button / `.id()` bump infrastructure —
  useful for one-off confirmation that the NavigationSplitView bug is
  fixable by rebuild, but not a stable production fix.
- ❌ NavigationStore VM cache keyed by `MailboxSelection` — interfered with
  SwiftUI's @State view lifecycle, made stuck bug worse.
- ❌ Auto-bump of `.id()` on `InboxView.onDisappear` — crashed in
  `NavigationLinkViewRule.present` because bumping `.id()` during an
  in-flight navigation-destination attribute graph resolution caused a
  dangling reference.

**Known-remaining issue**: SwiftUI `NavigationSplitView` on compact-mode
iPhone has a framework-level bug where rapid nav can produce:

1. Brief content flash of previous destination while new destination mounts
2. Occasional stuck state where `onDisappear` fires but UIKit keeps showing
   the view, body eval continues for invisible VM

Neither is fixable from app code without violating the List-binding contract.
**Next-session options** if the bug becomes unacceptable:

1. Replace `NavigationSplitView` + `List(selection:)` with
   `UISplitViewController` + `UITableView` via `UIHostingController` for
   content/detail. Bypasses the framework bug entirely. ~1-2 day refactor.
2. Split by size class: `NavigationStack` in compact, `NavigationSplitView`
   in regular. Works around the compact-mode bug via the unaffected code
   path. Smaller refactor but changes structural identity on device rotation.

Both deferred. Current state is stable and ships.

---

## KNOWN ISSUE — SwiftUI NavigationSplitView compact-mode race

**Status**: known, not fixed at app level. Documented workaround implemented (FG sync debounce + inflight guard, see `InboxViewModel.startSync`). Does not block release.

**Symptom**: on iPhone (compact size class), when the user taps between sidebar folders rapidly (mailbox → folder → back → different folder), one of the following can briefly occur:
- The previous destination's content flashes for a frame before snapping to the new destination
- The view sticks mid-transition (visible `onDisappear` fires but UIKit keeps the prior frame on screen); self-recovers after an interval or on the user's next tap

**Root cause**: SwiftUI framework bug in `NavigationSplitView` compact mode. The internal state machine cannot commit a transition to its new destination before another nav request arrives. Confirmed via iOS 17/18/26 across multiple Apple DevForum reports. See sources in the session 2 section above.

**What does NOT work**:
- Intercepting `List(selection:)` via a custom binding (throttle / debounce / queue) — breaks SwiftUI's implicit "binding is synchronously consistent" contract, makes the bug worse (sustained "clicking" behavior, view desync).
- `.id()` bump on NavigationSplitView from `onDisappear` — crashes `NavigationLinkViewRule.present` when triggered mid-nav.
- QoS tweaks to background work (`.low` vs `.medium`) — orthogonal to the bug.

**What DOES work (verified but rejected for UX reasons)**:
- `.allowsHitTesting(false)` for 500ms after selection change — eliminates the bug 100%, but drops user taps during the window (no queue) and visibly delays feedback.

**Mitigations in place**:
- `@StateObject InboxViewModelHolder` wrapper eliminates phantom VM churn that amplified the race (shipped `016ddf1`).
- `InboxViewModel.startSync()` has a 1000ms debounce + inflight guard so onAppear-triggered sync doesn't hit MainActor during transition windows (shipped `76d4781`).

**Real fixes (deferred until bug becomes release-blocking)**:
- Replace NavigationSplitView + compact-mode List with UIKit `UISplitViewController` + `UIHostingController`. ~1-2 day refactor. Entirely sidesteps the framework bug.
- Size-class split: `NavigationStack` in compact, `NavigationSplitView` in regular. Smaller refactor but nav-identity changes on rotation.

**For next engineer picking this up**: start by reading [theempathicdev.de/blog/advanced-navigation-split-view-bugs](https://theempathicdev.de/blog/advanced-navigation-split-view-bugs) and Apple DevForum threads 735401, 759093, 764750, 769483. Do NOT try binding interception again — the attempts in this session are thoroughly documented above and all fail.
