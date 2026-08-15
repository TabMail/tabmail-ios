# PLAN: Migrate iPhone navigation shell from `NavigationSplitView` to `NavigationStack`

**Branch:** `nav-stack-shell` (off `v1.1.0`)
**Owner:** solo dev + Claude Code
**Status:** Draft plan, not started
**Last updated:** 2026-04-20

---

## 1. Why we're doing this

`KNOWN_NAVIGATIONSPLITVIEW_BUG.md` documents a confirmed SwiftUI framework bug in `NavigationSplitView`'s compact-mode (iPhone) state machine. On rapid folder taps / foreground returns:

- Previous destination's content flashes for a frame before snapping to new.
- View sticks mid-transition (`onDisappear` fires but UIKit keeps the prior frame on screen); self-recovers after interval or next tap.

All in-container mitigations have been tried and either don't work or introduce worse regressions (binding interception breaks sync contract; `.id()` bump crashes; hit-testing block drops user taps). The fix has to be outside the container.

Per WWDC22 "SwiftUI cookbook for navigation" and Point-Free's published recommendation, the established workaround on iPhone-only apps is to **drop `NavigationSplitView` entirely on compact-class devices** and use `NavigationStack` directly. iPhone compact-mode `NavigationSplitView` is already *internally* collapsed to a stack by SwiftUI (confirmed WWDC22 quote: "SwiftUI can automatically adapt the split view to a single stack on iPhone … Changes to selection automatically translate into the appropriate pushes and pops on iPhone") — we're removing the buggy collapse/expand state machine by never entering it.

**Because this app is iPhone-only, we skip the size-class conditional and always use `NavigationStack`.**

## 2. Goal

Replace the three-column `NavigationSplitView` shell in `MailNavigationView` with a single `NavigationStack`, preserving all existing functionality. No behavior regressions. The compact-mode race bug goes away because the broken code path is no longer entered.

## 3. Non-goals

- iPad / Mac Catalyst support (app is iPhone-only per user directive)
- Runtime A/B gating (decided against — clean branch-based test)
- Any change to `InboxView`, `MessageDetailView`, or any column-content view
- Any change to sidebar banners, row visuals, unread-count logic, or expand/collapse state. The 12 sidebar `NavigationLink(value: MailboxSelection.foo)` call sites stay exactly as they are.
- Any change to the 3 `NavigationLink(value: snapshot.id)` sites in `InboxView` (normal row L783, thread child L867, triage row L967). They push `String` values, which the new shell handles via a dedicated `.navigationDestination(for: String.self)`. Each site is wrapped in `if !isDraftsContext { ... }` — tapping a draft row takes a separate fullScreenCover path (see §5 "Drafts-compose flow"), not a stack push.
- Changing any settings view's internals
- Changing sheet / fullScreenCover presentations anywhere
- Chat pill (`DynamicIslandChatButton`), compose flows, AI features, sync engine — all unchanged
- Test suite — 6180 tests should continue to pass without edits

## 4. Architecture change — before / after

### Before (current, `MailNavigationView.swift:102`)

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    List(selection: $selection) {
        Group {
            // banners, unified mailboxes, favorites, app sections,
            // per-account folders (all unchanged)
        }
    }
    .navigationTitle("Mailboxes")
    .navigationSubtitle(...)
} content: {
    MailContentColumn(selection: selection, selectedMessageId: $selectedMessageId)
} detail: {
    MessageDetailContainer(selectedMessageId: selectedMessageId)
}
// + .onChange(of: selection) { selectedMessageId = nil }
// + deep-link handlers writing (selection, selectedMessageId) in pairs
```

### After

```swift
@State private var path = NavigationPath()
@State private var selectedMessageId: String?  // kept — drives List(selection:) row highlight in InboxView

NavigationStack(path: $path) {
    List {
        // EXACT same banners + sections + folders as before.
        // Sidebar rows stay as NavigationLink(value: MailboxSelection.foo) { ... } — UNCHANGED.
    }
    .navigationTitle("Mailboxes")
    .navigationSubtitle(...)
    .navigationDestination(for: MailboxSelection.self) { sel in
        switch sel {
        case .unified, .folder:          InboxColumnResolver(selection: sel, selectedMessageId: $selectedMessageId)
        case .outbox:                    OutboxView(accountId: nil)
        case .outboxForAccount(let aid): OutboxView(accountId: aid)
        case .account:                   AccountDashboardView()
        case .planPicker:                PlanPickerView()
        case .prompts:                   TabMailSettingsView()
        case .settings:                  SettingsView()
        case .scheduledTasks:            ScheduledTasksSettingsView()
        case .reminders:                 RemindersSettingsView()
        case .calendar:                  CalendarPickerView()
        case .contacts:                  ContactContainerPickerView()
        case .debug:                     DebugMenuView()
        }
    }
    .navigationDestination(for: String.self) { id in
        MessageDetailContainer(selectedMessageId: id)
            .id(id)
            .onDisappear {
                // Clear selectedMessageId on pop-back so InboxView's internal
                // checks (`selectedMessageId == nil` at L383, `selectedMessageId
                // != messageId` at L698) see fresh state. Guarded by id equality
                // so a detail→detail swap (deep-link changing the message) does
                // NOT clear the new value: by the time onDisappear fires for the
                // outgoing id, the incoming handler has already set
                // selectedMessageId = <newId>, so `selectedMessageId == id`
                // (the old id) is false and we skip the clear.
                if selectedMessageId == id { selectedMessageId = nil }
            }
    }
}
// deep-link handlers write `path` atomically (NavigationPath builder).
// selectedMessageId is a local @State owned by the shell; InboxView still receives
// it as @Binding. Its 3 NavigationLink(value: snapshot.id) sites (guarded by
// `if !isDraftsContext`) push strings onto the same NavigationStack; row highlight
// is driven by the existing explicit .tag(snapshot.id) / .tag(child.id) modifiers
// on each row (L800, L888) combined with `List(selection: listSelectionBinding)`.
// Nothing in InboxView changes — the drafts-compose fullScreenCover flow (§5)
// is already self-contained in InboxView and is nav-independent.
```

### Key data-flow shifts

| Shell concern | Before | After |
|---|---|---|
| Sidebar selection | `@State selection: MailboxSelection?` drives `List(selection:)` + split-column rendering | `@State selection` removed. Sidebar `NavigationLink(value: MailboxSelection.foo)` pushes the value onto the `NavigationStack`; `.navigationDestination(for: MailboxSelection.self)` renders it. No `List(selection:)` on the sidebar. |
| Message detail | `@State selectedMessageId` drives detail column rendering via `MessageDetailContainer` | `@State selectedMessageId` survives (it's what InboxView's `List(selection:)` writes). Rendering is driven by `.navigationDestination(for: String.self)` — InboxView's existing `NavigationLink(value: snapshot.id)` pushes the String and the destination modifier renders `MessageDetailContainer`. `selectedMessageId` is now only load-bearing for row highlight, not detail rendering. |
| Detail clearing on selection change | `.onChange(of: selection) { selectedMessageId = nil }` | Gone. In the stack model, the inbox view unmounts when a different root destination is pushed, so stale highlight state can't be visible. |
| Deep-link race flag | `isHandlingNotificationDeepLink` guards the two-step `selection → selectedMessageId` write | Gone. Deep-link handlers build a `NavigationPath` and assign once (`path = ...`), so there's no interleaved state for `.onChange` to trip on. |
| `columnVisibility` | `@State columnVisibility` bound to `NavigationSplitView` | Gone. `NavigationStack` has no column-visibility concept. |

## 5. Exhaustive file inventory

### Files CHANGED

| File | Change | Est. LOC |
|---|---|---|
| `TabMail/Views/MailNavigationView.swift` | Replace body with `NavigationStack(path: $path)` + two `.navigationDestination` modifiers (`for: MailboxSelection.self` and `for: String.self`). The String destination wraps `MessageDetailContainer` with an `.onDisappear { if selectedMessageId == id { selectedMessageId = nil } }` so a pop-back clears the stale id (see §4 code and §9 risk #6). Replace `@State selection`/`@State columnVisibility` with `@State path = NavigationPath()`. Keep `@State selectedMessageId` (now only drives InboxView row highlight, not detail rendering). Delete `@State isHandlingNotificationDeepLink` and `.onChange(of: selection) { selectedMessageId = nil }`. Delete `MailContentColumn` + `SettingsContentColumn` (switch logic folds into the `MailboxSelection` destination). Keep `InboxColumnResolver` + `MessageDetailContainer`. Port deep-link handlers to `NavigationPath` builds (§6). | ~100 delta |

### Files NOT changed

- `TabMail/Views/Inbox/InboxView.swift` — zero changes. The 3 `NavigationLink(value: snapshot.id)` sites (normal row L783, thread child L867, triage row L967) push `String` values that the shell's new `.navigationDestination(for: String.self)` handles. Each is wrapped in `if !isDraftsContext { ... }` — in drafts context the NavigationLink is omitted entirely (see "Drafts-compose flow" below). The `@Binding var selectedMessageId: String?` init signature and all internal sites (L377/L383/L698/L770/L959/L970) behave identically. Row highlight is driven by the existing explicit `.tag(snapshot.id)` at L800 (normal row) and `.tag(child.id)` at L888 (thread child) combined with `List(selection: listSelectionBinding)` at L770/L959 — these modifiers stay; nothing to add. Triage row highlight continues to come from the explicit `isSelected: selectedMessageId == snapshot.id` param at L970.
- Exactly 10 `Views/Previews/Tooltips/*+Preview.swift` files construct `InboxView(...)` and pass `selectedMessageId: .constant(nil)` — signature unchanged, so they continue to compile and render with zero edits.

### Drafts-compose flow (InboxView-internal, nav-independent — confirmed unchanged)

InboxView has a dedicated in-file path for tapping a row when the user is inside a Drafts folder (unified `.drafts` or per-account drafts), introduced before this migration to sidestep exactly the same iPhone-compact NavigationSplitView glitch this plan is designed to kill. The plan inherits it as-is:

- `isDraftsContext: Bool` at L88 — true when `selection` resolves to `.drafts`.
- `listSelectionBinding: Binding<String?>` at L102 — wraps `$selectedMessageId`. Setter inspects `isDraftsContext`: if true, writes `draftIdToOpen = newId` instead of `selectedMessageId = newId`, leaving `selectedMessageId` nil so no stack push happens.
- `@State draftIdToOpen: String?` at L129 — drives the draft fullScreenCover.
- `.fullScreenCover(isPresented: draftIdToOpen != nil)` at L493-501 — presents `ServerDraftComposeLoader(header:)` modally. The cover dismisses via standard fullScreenCover dismissal; no nav path involvement.
- The 3 conditional NavigationLink wrappers (`if !isDraftsContext { NavigationLink(...) }` at L782-785, L866-869, L966-969) ensure that in drafts context the tap doesn't ALSO push a detail — only the fullScreenCover opens.

Under the new stack shell this flow continues to work identically: tapping a draft row runs the `listSelectionBinding` setter (setting `draftIdToOpen`, not `selectedMessageId`), no value is pushed onto the NavigationStack path, and the fullScreenCover renders over the inbox. Closing the cover returns to the Drafts list with the stack path unchanged.

Secondary path — `MessageDetailContainer` (at `MailNavigationView.swift:847`) still contains an inline draft-check branch (L852-866) that renders `ServerDraftComposeLoader` when a message pushed via `selectedMessageId` turns out to be in a Drafts folder. This is reached only when `selectedMessageId` is set from *outside* the drafts-context interception path — e.g., a push notification deep link that lands on a draft, or a chat-pill email reference to a draft. It's a low-traffic fallback, preserved unchanged. Under the new shell it renders inside the String destination (nested `NavigationStack`s, since `ComposeView` L95 hosts its own); this same nesting exists today under the split view's detail column and is not a regression.

### Files NOT changed (explicitly in scope of the migration but confirmed unchanged)

- All sidebar row types (`UnifiedFolderRow`, `FolderRow`, `OutboxSidebarRow`)
- All banner buttons (Free Trial, Fix Smart Notifications)
- All section expand/collapse logic (`expandedAccounts`)
- `NavigationStore`, `AccountManagerState`, `AISubscriptionGate`, `PromptStore`, `DeviceSyncService`
- Every pushed destination's *body* (`SettingsView`, `TabMailSettingsView`, `AccountDashboardView`, `RemindersSettingsView`, etc.) — they don't contain a `NavigationStack` wrapper, they just use `NavigationLink { }` internally which pushes onto whatever stack is enclosing. They currently enclose under the split's content column; they'll enclose under the root stack. Behavior-preserving.
- Every sheet/fullScreenCover presentation — independent of nav shell
- Compose flow (`ComposeView`, `DraftComposePresenter`, `ServerDraftComposeLoader`)
- Chat pill (`DynamicIslandChatButton`), agent chat sheet, toolbars, swipe actions, context menus
- Keyboard dismiss, `.dismissKeyboardOnTap()`, scroll behavior
- Sync engine, GRDB, AI pipelines, push/background tasks — zero dependence on nav shell
- `RootView.swift` — continues to mount `MailNavigationView` at two sites (email-only mode, full mode); no change to its call signature

## 6. Deep-link handler ports (each must be verified on real device)

7 nav-affecting entry points in `MailNavigationView.swift`. Each writes a freshly-built `NavigationPath` in one assignment. Two additional `.onReceive` handlers (#8, #9) only touch banner/alert state and are listed for completeness.

Helper for building paths (private to MailNavigationView — **must be `static`** so it can be called from `init` before `self` is fully initialized):

```swift
private static func pathTo(_ sel: MailboxSelection, message: String? = nil) -> NavigationPath {
    var p = NavigationPath()
    p.append(sel)
    if let message { p.append(message) }
    return p
}
```

Call sites from within the view reference it as `Self.pathTo(...)`.

| # | Entry point | Current location | Current behavior | New behavior |
|---|---|---|---|---|
| 1 | `.navigateToSettings` NotificationCenter | L398 | `selection = .settings` | `path = Self.pathTo(.settings)` (reset root). |
| 2 | `.navigateToAccount` NotificationCenter | L401 | `selection = .account` | `path = Self.pathTo(.account)`. |
| 3 | `.emailPillTapped` NotificationCenter | L426 | `selectedMessageId = realId` | `path = Self.pathTo(.unified(.inbox), message: realId)` — atomic set to inbox+detail. |
| 4 | `.proactiveNotificationTapped` NotificationCenter | L433 → `handleNotificationDeepLink` | `selection = .unified(.inbox); selectedMessageId = id` (flag-guarded). Side effect: `_ = PendingDeepLinkStore.consume()` first to de-dupe with `.onAppear`. | `path = Self.pathTo(.unified(.inbox), message: compositeId)` (compositeId may be nil). Preserve the `PendingDeepLinkStore.consume()` de-dupe call. Flag deleted. |
| 5 | Cold-start `PendingDeepLinkStore` consume | L505 `.onAppear` | Sets `selection = .unified(.inbox)`; for `.message(id)` also sets `selectedMessageId` if `MessageHeader.fetchOne` confirms existence. `.taskResult` and `.inbox` do nothing extra. | All 3 types: `path = Self.pathTo(.unified(.inbox))`; for `.message(id)` and existence confirmed: `path = Self.pathTo(.unified(.inbox), message: id)`. |
| 6 | `pending_plan_navigation` UserDefaults | L416 `.task` | `selection = .planPicker` after 100ms delay | `path = Self.pathTo(.planPicker)`. |
| 7 | Free-trial banner tap (signed-in) | L117 | `selection = .planPicker` | `path = Self.pathTo(.planPicker)`. |
| 8 | `.pushConsentErrorsDetected` | L436 | Updates banner state only (no nav change) | unchanged — not a nav deep-link |
| 9 | `.pushConsentExplainerNeeded` | L452 | Updates alert state (no nav change) | unchanged — not a nav deep-link |

**Atomicity note for #3, #4, #5-message:** Current code does a two-step write (`selection` then `selectedMessageId`) with a guard flag (`isHandlingNotificationDeepLink`) to prevent `.onChange` from wiping the second value between the two. The new model replaces the pair with one `path = Self.pathTo(...)` assignment — naturally atomic, flag deleted.

**Row-highlight parity for #3, #4, #5-message:** These handlers push a message detail AND, in the old model, also set `selectedMessageId` (which both rendered the detail AND highlighted the row in the inbox). In the new model, `selectedMessageId` is no longer load-bearing for detail rendering — but InboxView still reads it for row highlight. To preserve the "when user pops back from a deep-linked message, that row stays highlighted" behavior, each of these three handlers MUST also write `selectedMessageId = <messageId>` (or `nil` when no message resolved) alongside the `path = Self.pathTo(...)` assignment. Two writes, but each targets independent state, so no flag is needed.

**Initial path:** `init(initialSelection:)` sets the initial `NavigationPath`: `NavigationPath()` if `pending_plan_navigation` is set (empty; `.task` pushes planPicker after 100ms), otherwise `Self.pathTo(initialSelection)` when non-nil or `NavigationPath()` when nil. `MailNavigationView(initialSelection: .unified(.inbox))` starts pushed into inbox (same UX as today's auto-select in the split-view content column).

## 7. Sidebar destinations — exhaustive routing table

All 13 `MailboxSelection` cases must be tested end-to-end. One row per case, all must route correctly under the new stack, with toolbar/back-button behavior preserved.

| # | Selection case | Navigates to | Current inner container | New container | Notes |
|---|---|---|---|---|---|
| 1 | `.unified(.inbox)` | `InboxView` (filtered by role) | split content column | pushed on stack | All 6 unified role filters share this case via `.unified(FolderRole)`: inbox/archive/sent/drafts/trash/spam (exposed via `unifiedRoles` at L92). `.unified(.custom)` is routed in `unifiedTitle` as "All Folders" but not reachable from the sidebar today. |
| 2 | `.folder(Folder)` | `InboxView` (single folder) | split content column | pushed on stack | Same destination as `.unified` but filtered to one folder |
| 3 | `.outbox` | `OutboxView(accountId: nil)` | split content column | pushed on stack | No inner NavigationStack |
| 4 | `.outboxForAccount(String)` | `OutboxView(accountId: aid)` | split content column | pushed on stack | |
| 5 | `.account` | `AccountDashboardView` | split content column | pushed on stack | Contains NavigationLinks to PlanPickerView, AccountDeletionView — both push cleanly on outer stack |
| 6 | `.planPicker` | `PlanPickerView` | split content column | pushed on stack | |
| 7 | `.prompts` | `TabMailSettingsView` | split content column | pushed on stack | Contains NavigationLinks to CompositionPromptView, ActionRulesView, KnowledgeBaseView, TemplatesListView, ChatHistoryView, PromptHistoryView — all push onto outer stack. Confirmed: neither `TemplatesListView` nor `PromptHistoryView` has an outer `NavigationStack` wrapper (both only have sheet-scoped inner stacks), so nothing to strip. |
| 8 | `.settings` | `SettingsView` | split content column | pushed on stack | Contains NavigationLinks to AccountDetailView, AccountSetupView. `.fullScreenCover` to FastSyncView unchanged. |
| 9 | `.scheduledTasks` | `ScheduledTasksSettingsView` | split content column | pushed on stack | Currently commented out in sidebar but case exists |
| 10 | `.reminders` | `RemindersSettingsView` | split content column | pushed on stack | Contains a NavigationLink to MessageDetailView — will also push. Works in both shells. |
| 11 | `.calendar` | `CalendarPickerView` | split content column | pushed on stack | |
| 12 | `.contacts` | `ContactContainerPickerView` | split content column | pushed on stack | |
| 13 | `.debug` | `DebugMenuView` | split content column (debug-mode only) | pushed on stack | |

## 8. EXHAUSTIVE TEST MATRIX

**Every single item must be verified on a physical iPhone running iOS 26 before merge.** Simulator is insufficient — the original bug is most reliably reproduced on device, and iOS 26 compact-mode NavigationStack behavior has not been validated in this codebase before.

### 8.1 Nav shell — core behavior

- [ ] Cold launch → lands on sidebar root with `initialSelection = .unified(.inbox)` auto-pushing into inbox (currently the expected behavior)
- [ ] Cold launch with `pending_plan_navigation = true` → lands on sidebar root → after 100ms auto-pushes to PlanPicker
- [ ] Cold launch with `PendingDeepLinkStore.message(id)` stashed → auto-navigates to inbox + message detail
- [ ] Cold launch with `PendingDeepLinkStore.inbox` stashed → auto-navigates to inbox
- [ ] Cold launch with `PendingDeepLinkStore.taskResult(hash)` stashed → auto-navigates to inbox (chat pill expansion handled by InboxView)
- [ ] Tap back from message → returns to inbox (with previous scroll position preserved — verify)
- [ ] Tap back from inbox → returns to sidebar
- [ ] Long-press back chevron from message → shows "Inbox" and "Mailboxes" ancestor menu → tap "Mailboxes" → pops all the way
- [ ] Swipe-from-left-edge on message detail → pops to inbox (default gesture works)
- [ ] Swipe-from-left-edge on inbox → pops to sidebar

### 8.2 Bug repro — the whole reason for this migration

- [ ] On `nav-stack-shell`: force-quit app → launch → immediately tap rapidly between Inbox → Archive → Inbox → different folder → back during cold-start sync window. Confirm NO stuck-blank, NO flash, NO delayed commit.
- [ ] Leave app idle 30+ seconds → return to foreground → navigate rapidly → confirm no stuck state.
- [ ] Run on both debug and TestFlight builds (bug was more frequent in debug under the old shell; verify both).

### 8.3 Sidebar rows

For each row type, tap once, verify correct destination pushes, verify back button returns to sidebar:

- [ ] "Start Your Free Trial" banner (signed in, no subscription) → pushes PlanPickerView
- [ ] "Start Your Free Trial" banner (signed out) → opens sign-in sheet (sheet, not push)
- [ ] "Fix Smart Notifications" banner → runs OAuth flow (no nav push)
- [ ] Unified row: All Inboxes, All Archive, All Sent, All Drafts, All Trash, All Spam (one tap each)
- [ ] Outbox (unified) when outbox has messages → pushes OutboxView
- [ ] Favorite folder row → pushes InboxView(folder)
- [ ] Long-press favorite row → context menu "Remove from Favorites" works
- [ ] "TabMail Account" → pushes AccountDashboardView
- [ ] "TabMail Settings" → pushes TabMailSettingsView
- [ ] "Sign in to TabMail" (signed out) → opens sign-in sheet
- [ ] "Email Accounts" → pushes SettingsView
- [ ] Email Accounts row shows isLargeInbox warning indicator when flag set — verify still renders
- [ ] Backfill progress bar on Email Accounts row during active backfill — verify still renders
- [ ] "Reminders" → pushes RemindersSettingsView (popoverTip shows)
- [ ] "Calendar" → pushes CalendarPickerView
- [ ] "Contacts" → pushes ContactContainerPickerView
- [ ] "Debug" (debug mode unlocked) → pushes DebugMenuView
- [ ] Per-account folder row → pushes InboxView(folder)
- [ ] Long-press per-account folder row → context menu "Add to Favorites"/"Remove from Favorites" works
- [ ] Per-account outbox row (when account has outbox items) → pushes OutboxView(accountId:)
- [ ] Account section expand/collapse chevron → state persists across app backgrounding

### 8.4 Sidebar auxiliary state

- [ ] Sidebar title = "Mailboxes"
- [ ] Sidebar subtitle shows sync status (synced / syncing / error) and updates live during sync
- [ ] Sidebar subtitle formatting matches current (SyncStatusFormatter.statusText)
- [ ] Sync status env values (`\.syncPhase`, `\.lastSync`, `\.syncFailed`, `\.syncNow`) propagate to sidebar from RootView
- [ ] Banner flash prevention: on first-ever launch (fresh install), neither subscription banner nor consent banner flashes during whoami/scan wait
- [ ] Banner flash prevention: on returning user launch, last-known banner state surfaces immediately without flicker
- [ ] `AISubscriptionGate` state sync: when gate opens/closes, Free Trial banner appears/disappears correctly
- [ ] `hasCompletedFirstConsentScan` gating: consent banner stays hidden until first authoritative scan result

### 8.5 Inbox → Message → back flow

- [ ] Tap message in inbox → pushes MessageDetailView (NavigationLink(value: snapshot.id) fires the shell's `.navigationDestination(for: String.self)`)
- [ ] Tap back → pops to inbox, row highlight clears. (Clearing is driven by the `.onDisappear { if selectedMessageId == id { selectedMessageId = nil } }` attached to `MessageDetailContainer` in the String destination — see §9 risk #6.)
- [ ] Scroll position in inbox preserved across push/pop
- [ ] Unread count in sidebar updates live while in detail
- [ ] Swipe actions in inbox (archive, delete, flag) still work
- [ ] Swipe-to-zap animation correct
- [ ] Context menu on message row (Tag as Reply/Archive/Delete, Remove Tag) still works
- [ ] Open a message → swipe delete from detail → pops back to inbox correctly
- [ ] Open a message → archive from detail toolbar → pops back to inbox
- [ ] Open a message → move to folder → folder-picker sheet presents → pick folder → sheet dismisses → detail pops → inbox stays on previous folder
- [ ] Navigate to Drafts folder (unified All Drafts or per-account Drafts). Tap a draft row → opens ComposeView as a **fullScreenCover** (via InboxView's `listSelectionBinding` → `draftIdToOpen` → `ServerDraftComposeLoader` → `DraftComposePresenter`). Verify: no detail pushed onto the navigation stack, `selectedMessageId` stays nil, the draft compose sits OVER the inbox.
- [ ] Close the draft compose (dismiss fullScreenCover) → returns to the Drafts list with the nav path unchanged (still at Drafts inbox, no orphan detail pushed).
- [ ] Tap a non-drafts row (e.g., in All Inbox) → pushes MessageDetailView normally (confirms the `if !isDraftsContext` guard gates correctly).
- [ ] Deep-link / chat-pill email reference that resolves to a draft message ID (rare, fallback path) → `MessageDetailContainer`'s inline draft branch renders `ServerDraftComposeLoader` inside the String destination. Verify it still works (nested NavigationStack inside ComposeView is acceptable).
- [ ] Undo-Send reopen: send an email, tap Undo → `RootView`'s `fullScreenCover` presents `UndoReopenCompose`. Verify it opens and dismisses cleanly, nav path unchanged.
- [ ] Triage mode swipe: enter triage → swipe → exit triage → confirm no nav corruption

### 8.6 Deep links — each must atomically land on correct state

- [ ] Notification tap while app in background, message still exists → app foregrounds → lands on inbox + detail of tapped message. No flash of empty inbox.
- [ ] Notification tap while app in background, message deleted → lands on inbox, no detail.
- [ ] Notification tap while app killed (cold start) → same behavior as above via `PendingDeepLinkStore`.
- [ ] Notification tap with `taskResult` → lands on inbox, chat pill auto-expands to show task result.
- [ ] Notification tap with consent_error → lands wherever, consent banner shows.
- [ ] Email pill tap in chat → navigates to that message's detail from any context (inbox, another message, settings)
- [ ] `.navigateToSettings` deep link (via URL scheme / tool call) → pushes SettingsView
- [ ] `.navigateToAccount` deep link → pushes AccountDashboardView
- [ ] Two rapid deep links in sequence — last one wins, no mid-state stuck

### 8.7 Settings navigation (pushed destinations with inner NavigationLinks)

For each, verify the nested NavigationLink push works correctly, toolbar renders, swipe-back works:

- [ ] TabMailSettingsView → Compositions → push → back
- [ ] TabMailSettingsView → Action Rules → push → back
- [ ] TabMailSettingsView → Knowledge Base → push → back
- [ ] TabMailSettingsView → Templates → push → back
  - [ ] Templates → sheet "My Shared Templates" → open → dismiss
  - [ ] Templates → sheet "Marketplace" → open → dismiss
  - [ ] Templates → sheet Template detail → open → dismiss
- [ ] TabMailSettingsView → Chat History → push → back
- [ ] TabMailSettingsView → Prompt History → push → back
- [ ] TabMailSettingsView → sheet Acknowledgments → open → dismiss
- [ ] SettingsView → Account Detail → push → back
- [ ] SettingsView → Add Account → push → back
- [ ] SettingsView → fullScreenCover FastSync → open → dismiss
- [ ] AccountDashboardView → Plan Picker → push → back
- [ ] AccountDashboardView → Account Deletion → push → back
- [ ] RemindersSettingsView → tap reminder → MessageDetailView pushes → back returns to reminders
- [ ] CalendarPickerView → calendar flows
- [ ] ContactContainerPickerView → contact flows
- [ ] DebugMenuView (if unlocked) → DebugLogView, other debug sub-screens

### 8.8 Sheets, fullScreenCovers, alerts (nav-independent — spot-check)

Modals don't sit on the nav chain, so none of them are affected by the shell rewrite in principle. Spot-check 2–3 to confirm the shell's modifier chain still hosts them correctly:

- [ ] Compose fullScreenCover (from inbox toolbar or reply) opens and dismisses
- [ ] Agent chat sheet (from chat pill) opens and dismisses
- [ ] Any one folder/label picker sheet opens and dismisses

If those work, the rest (EML preview, Report Concern, iCloud prompt, sign-in sheet, push consent alerts, QuickLook, ICS import) follow the same modifier pattern and are unaffected.

### 8.9 Chat pill (nav-independent — spot-check)

Chat pill is overlaid on InboxView and MessageDetailView; it has no nav-shell dependency. Spot-check:

- [ ] Chat pill visible on both inbox and message detail
- [ ] Expand / send / collapse works
- [ ] Chat pill persists visually across inbox → detail → back

### 8.10 Toolbars (confirm each pushed view's toolbar still renders correctly on the stack)

- [ ] Sidebar "Mailboxes" title + subtitle
- [ ] Inbox title ("All Inboxes" / "All Archive" / etc. / folder name)
- [ ] Inbox toolbar items (compose, filter, sort, triage toggle, etc.)
- [ ] Inbox large-title scrolling behavior (inline when scrolled, large at top) — watch for the original "large title instead of inline" symptom of the framework bug
- [ ] Message detail toolbar (archive, delete, tag, reply, forward, move, flag, mark unread)
- [ ] Settings view toolbars
- [ ] Back chevron labeled with previous screen title (iOS 14+ default long-press menu)

### 8.11 Swipe-back gesture

- [ ] From message detail → swipe-back works (interactive gesture, can drag + cancel)
- [ ] From inbox → swipe-back to sidebar works
- [ ] From TabMailSettingsView → swipe-back to sidebar
- [ ] From a nested push (TabMailSettings → Templates) → swipe-back goes one level (to TabMailSettings)
- [ ] Swipe-back during a sync in progress → not interrupted
- [ ] Swipe-back with compose sheet present → does nothing (sheet is modal)

### 8.12 Rapid interaction (regression guard — this is where the old bug lived)

- [ ] Tap 10 folders in rapid succession → final destination correct, no stuck blank
- [ ] Tap folder → tap message → tap back → tap different folder → tap message → repeat 5x rapidly → no stuck state
- [ ] Force-quit → relaunch → tap rapidly during cold-start sync → no stuck state
- [ ] Foreground-return from 1hr idle → tap rapidly → no stuck state
- [ ] Device rotation during rapid nav → no stuck state. Note: `Info.plist` declares all 4 orientations (`UIInterfaceOrientationPortrait`/`PortraitUpsideDown`/`LandscapeLeft`/`LandscapeRight`), so rotation is an active test surface — verify nav-stack push/pop animations land cleanly across orientation changes mid-transition.

### 8.13 Cross-feature integration (spot-check — most of these are nav-independent)

- [ ] Open message → receive new mail notification → tap → navigates correctly
- [ ] Archive via toolbar → detail pops → inbox reflects state
- [ ] Undo toast on archive → tap undo → message returns, detail does NOT re-open
- [ ] Multi-account: folder from Account A → back → folder from Account B → both render correctly
- [ ] GRDB ValueObservation firing during navigation (unread count update) → no flicker

The rest (Gmail vs IMAP parity, background-return detail state, kill-and-relaunch, AI summary arrival, outbox drain, Device Sync updates) don't touch the nav shell; if the above are clean, they're clean.

### 8.14 Accessibility / system integration

- [ ] VoiceOver: sidebar rows announced with correct labels and unread counts
- [ ] VoiceOver: navigation push announces destination title
- [ ] Dynamic Type: sidebar rows wrap correctly at largest type sizes
- [ ] Dark mode: sidebar palette, title, subtitle all render correctly
- [ ] Focus engine (keyboard attached): arrow keys navigate sidebar rows
- [ ] iPad in Stage Manager / multi-window — **not tested**, iPhone-only app

### 8.15 Test suite

- [ ] iOS test suite (`xcodebuild test -scheme TabMail` against the `TabMailTests` target) passes 6180 / 6180 — should be unaffected since nav shell is not test-covered
- [ ] All 10 InboxView tooltip previews build and render (no InboxView changes, so parity is automatic; a build pass is sufficient)
- [ ] `RemindersMenuTip+Preview.swift` (mounts `MailNavigationView()` directly to show the sidebar tip): verify the sidebar is visible in the preview canvas after the shell rewrite. Under the new shell, `MailNavigationView()` defaults to `initialSelection = .unified(.inbox)` and starts pushed into inbox, hiding the sidebar. If the preview no longer shows the tip, change the preview to `MailNavigationView(initialSelection: nil)` so the stack starts empty and the sidebar is the visible root.

## 9. Known risks during migration

1. **iOS 26 `NavigationStack` itself might have compact-mode bugs we haven't seen.** WWDC22 + Point-Free consensus says `NavigationStack` is the stable path and no bugs of this class have been reported, but we've only validated the current bug lives in `NavigationSplitView`. **Mitigation:** §8.2 is the decisive test. If `NavigationStack` has its own issue, abandon the branch.

2. **`.navigationSubtitle` on the stack root.** Works in theory on `NavigationStack`-hosted `List`, but the API is newer and has had rendering quirks. **Mitigation:** verify on device; if broken, fall back to `.navigationTitle` only (minor UX regression acceptable).

3. **Deeper stack for Settings chains.** In the split view, tapping a sidebar item like "TabMail Settings" rendered in the content column (depth 1 from sidebar), and further `NavigationLink`s inside pushed onto the content-column stack. In the new model, the sidebar is the root, so the same chain is depth 2+ (sidebar → TabMailSettings → Templates → nested). No functional risk; the back-chevron long-press shows ancestors. Verify UX is acceptable.

4. **`.onChange(of: selection) { selectedMessageId = nil }` is deleted.** In the old split-view world this cleared the detail when the sidebar selection changed. In the stack model, switching sidebar items requires being on the sidebar (you have to back out first), so the scenario can't arise. Verify no test depends on it.

5. **Path persistence.** `NavigationPath` does NOT need to survive app kills — cold-start deep links come through `PendingDeepLinkStore` which is persisted separately and consumed in `.onAppear`. Do not add `@SceneStorage`/`Codable` plumbing for `path`.

6. **`selectedMessageId` staleness after pop-back.** In the old split-view model, `selectedMessageId` and "detail is on screen" were the same thing (detail column observed the binding). In the new stack model they decouple: path drives what's on screen, `selectedMessageId` only drives the inbox row highlight. Two places in InboxView read `selectedMessageId` to infer "is a detail on screen right now?" — `guard selectedMessageId == nil` at L383 (contactPillComposeTapped: skip if MessageDetailView's listener should handle it) and `if selectedMessageId != messageId` at L698 (handleAgentToastTap: skip the re-navigation). Without mitigation, after a pop-back the stale `selectedMessageId` makes both checks wrong: L383 would skip when it shouldn't (compose never opens), L698 would skip navigation when the user has already left that message. **Mitigation (adopted in §4 / §5):** the `.navigationDestination(for: String.self)` closure attaches an `.onDisappear { if selectedMessageId == id { selectedMessageId = nil } }` to `MessageDetailContainer`. On pop the clear runs and L383/L698 see fresh nil. On a detail→detail swap (deep-link changes the open message) the id-equality guard prevents the outgoing view's `onDisappear` from clobbering the incoming `selectedMessageId`.

## 10. Execution order

1. Branch off `v1.1.0` → `nav-stack-shell`.
2. Confirmed: no sidebar destination contains an outer `NavigationStack` wrapper. All `NavigationStack` occurrences in the codebase are sheet/fullScreenCover-scoped (`FastSyncView`, `AcknowledgmentsView`, `TemplateMarketplaceView`, `TemplatesListView` ×2, `PromptHistoryView`, `LabelFilterPickerView`, `UserLabelMenuView`, `EmlAttachmentPreview`, `ICloudSetupPromptView`, `ComposeView`, `ReportConcernModifier`, `AgentChatSheet`, `SearchView`, the Move-folder picker inside `InboxView` L1279) or in tooltip previews under `Views/Previews/`. None need touching.
3. Rewrite `MailNavigationView` body to `NavigationStack(path: $path)` with two `.navigationDestination` modifiers (for `MailboxSelection` and for `String`). Keep the sidebar `List` content, banners, `.navigationTitle("Mailboxes")`, `.navigationSubtitle(...)` — all unchanged. Delete `MailContentColumn` + `SettingsContentColumn` (their switch logic folds into the `MailboxSelection` destination). Keep `InboxColumnResolver` and `MessageDetailContainer` as-is.
4. Replace `@State selection: MailboxSelection?` with `@State path = NavigationPath()`. Delete `@State columnVisibility`, `@State isHandlingNotificationDeepLink`, and `.onChange(of: selection) { selectedMessageId = nil }`. Keep `@State selectedMessageId: String?` — it's now just a shell-local @State that drives InboxView's `@Binding` (and therefore its `List(selection:)` row highlight).
5. Add the `private static func pathTo` helper (§6). **Static** is required so it can be called from `init` before `self` is initialized.
6. Rewrite `init(initialSelection:)` to set the initial `NavigationPath` — empty when `pending_plan_navigation` is set, `Self.pathTo(initialSelection)` when non-nil, empty otherwise.
7. Port the 7 nav-affecting deep-link handlers (§6 rows 1-7) to one-line `path = Self.pathTo(...)` assignments. For rows 3 / 4 / 5-message, also write `selectedMessageId = <messageId or nil>` alongside the path assignment, so row highlight survives pop-back from the deep-linked detail (§6 row-highlight parity note).
8. Build. Verify zero compile errors and zero new warnings.
9. Run full iOS test suite (`xcodebuild test -scheme TabMail` against `TabMailTests`). All 6180 must pass.
10. Fire up simulator, quick smoke test of §8.1 + §8.3.
11. Deploy to personal device via Fastlane + TestFlight or direct Xcode run.
12. Exhaustively work through §8 on real device. Any regression blocks merge.
13. If all green: commit (or split into commits as convenient — there's no hard coupling), merge branch into main, tag `v1.2.0`, update `TODO.md` and `KNOWN_NAVIGATIONSPLITVIEW_BUG.md` with resolution.
14. If blocking issue found: document findings on this plan, abandon branch, keep main unchanged.

## 11. Merge criteria

- [ ] All of §8 green on physical iPhone iOS 26
- [ ] Bug repro (§8.2) confirmed **fixed** (not "less frequent" — fully gone across 20 attempts)
- [ ] No new regressions observed across §8.3 through §8.14
- [ ] Full test suite 6180 / 6180
- [ ] No new compiler warnings

## 12. Rollback

If merge criteria not met:
- Branch stays on GitHub for reference / future resumption.
- `main` stays on v1.1.0 with documented known-issue state.
- Update `KNOWN_NAVIGATIONSPLITVIEW_BUG.md` with findings (what worked, what new issues surfaced, estimated cost of continuing).
- Consider alternative: UIKit `UISplitViewController` hybrid (ADR-quality decision — much larger effort, documented as Tier 2 in KNOWN_NAVIGATIONSPLITVIEW_BUG.md).

## 13. Post-merge cleanup

Post-merge follow-ups are tracked in `TODO.md` rather than this plan. Required entries:

- Write ADR-IOS-032 in `DECISIONS.md` documenting the migration.
- Delete `KNOWN_NAVIGATIONSPLITVIEW_BUG.md` and move its contents into `DONE.md` under this migration's dated entry.

Optional triage items (decide post-merge whether any are now pure overhead): `MainActorStallDetector`, `NavigationStore.refresh`/`refreshFolders` ≥50ms timing logs, `InboxViewModel.startSync` 1000ms debounce, and the `NavigationStack(path: .constant([scenario.inbox])) { InboxView(...) }` scaffolding in tooltip previews.

---

**End of plan.**
