/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import BackgroundTasks
import UserNotifications
import WebKit
import TipKit
import GRDB

@main
struct TabMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var navigationStore = NavigationStore()
    @State private var storeKitManager = StoreKitManager()
    /// Drives the one-time "Updating…" migration splash. The DB (schema +
    /// data-repair migrations) is built here, off the synchronous init path,
    /// so a long migration no longer freezes launch (RC2 fix, PLAN_HANG_FIX).
    @State private var startup = AppStartup.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Detect fresh install: UserDefaults is cleared on reinstall, Keychain is not.
        // If this is a fresh install but Keychain has stale data, clear it.
        // GUARD: also check for existing GRDB database file. If the database exists,
        // the user has data — UserDefaults was reset spuriously (TestFlight update,
        // backup restore, etc.) and we must NOT clear the Keychain session.
        let hasLaunchedKey = "hasLaunchedBefore"
        let hadLaunchedBefore = UserDefaults.standard.bool(forKey: hasLaunchedKey)
        let hadSession = TabMailAuthService.hasSession()
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail/tabmail.sqlite").path
        let dbExists = FileManager.default.fileExists(atPath: dbPath)
        AuthDiagnostics.log("Launch: hasLaunchedBefore=\(hadLaunchedBefore), session=\(hadSession), dbExists=\(dbExists)")
        if !hadLaunchedBefore {
            if dbExists {
                // Database exists — this is NOT a fresh install. UserDefaults was cleared
                // spuriously (TestFlight, backup restore, etc.). Do NOT nuke the session.
                AuthDiagnostics.log("UserDefaults reset but database exists — skipping session clear (false fresh-install)")
            } else {
                // Truly fresh install — clear stale Keychain data
                AuthDiagnostics.log("Fresh install detected — clearing stale Keychain data")
                TabMailAuthService.clearSession()
            }
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
        }
        let hasSessionAfter = TabMailAuthService.hasSession()
        AuthDiagnostics.log("Post-init: session=\(hasSessionAfter)")

        // Record first launch date for overdue reminder suppression (v1.0.1).
        // Only on truly fresh installs (no prior launch, no existing DB). Upgrading
        // 1.0.0 users already have their reminders and should not be affected.
        if !hadLaunchedBefore && !dbExists {
            if UserDefaults.standard.object(forKey: "firstLaunchDate") == nil {
                UserDefaults.standard.set(Date(), forKey: "firstLaunchDate")
                print("[TabMailApp] Fresh install — recorded firstLaunchDate for overdue reminder suppression")
            }
        }

        // One-shot migration: enable proactive reminder notifications by default.
        // Earlier builds had a bug in TabMailSettingsView's UserDefaults sync that
        // could silently flip this to false even when the user had not changed it.
        // We do not track whether the user explicitly disabled it, so we re-enable
        // for everyone — they can always toggle it back off in Settings.
        let proactiveOnByDefaultMigrationKey = "didMigrateProactiveNotifyOnByDefault_v1"
        if !UserDefaults.standard.bool(forKey: proactiveOnByDefaultMigrationKey) {
            UserDefaults.standard.set(true, forKey: ProactiveNotifyService.enabledKey)
            UserDefaults.standard.set(true, forKey: proactiveOnByDefaultMigrationKey)
            print("[TabMailApp] Migration: proactive reminder notifications enabled by default")
        }


        // sqlite-vec is registered per-connection in SearchIndex.prepareDatabase
        // (not globally via auto_extension — global registration causes vec0 vtab
        // instances on AppDatabase's reader connections where vec0 is never used,
        // wasting resources and risking vtab lifecycle crashes).

        // DATABASE STARTUP MOVED OFF THE SYNCHRONOUS INIT PATH (RC2 fix,
        // PLAN_HANG_FIX). Constructing `AppDatabase` runs the GRDB schema
        // migrator + one-time data resets, and the O(mailbox-size) thread-repair
        // migrations (v9/v27/v47/v53/v54) can take minutes after a multi-version
        // jump — doing that here froze launch with no UI ("hang on boot"). It
        // now runs in `AppStartup.runIfNeeded` behind a gating "Updating…"
        // splash (see `body`). Everything that touches `AppDatabase` —
        // construction, demo wipe, NSE staging + mirror, `loadInitialData`, and
        // the detached FTS/tool/embedding tasks below — must wait for that:
        // `AppDatabase.dbPool` force-unwraps `AppDatabase.shared`, so any access
        // before the coordinator sets it would crash. UI is gated by the splash;
        // background entry points gate via `AppStartup.shared.awaitReady()`.


        // Register client-side tools for AI agent chat (matching TB's core.js TOOL_IMPL).
        // Task.detached avoids inheriting main actor context — eliminates 26 main-actor
        // round-trips that compete with post-splash UI layout. registerAll does a single actor hop.
        Task.detached {
            // Wait for the DB to finish migrating before any tool can touch it
            // (tools query GRDB when invoked; registration itself doesn't, but
            // gating here is cheap and keeps all DB-adjacent startup uniform).
            await AppStartup.shared.awaitReady()
            let registry = ToolRegistry.shared
            await registry.registerAll([
                InboxReadTool(),
                EmailReadTool(),
                EmailSearchTool(),
                EmailDeleteTool(),
                EmailArchiveTool(),
                EmailComposeTool(),
                EmailReplyTool(),
                EmailForwardTool(),
                MemorySearchTool(),
                MemoryReadTool(),
                KBAddTool(),
                KBDelTool(),
                ReminderAddTool(),
                ReminderDelTool(),
                // MARK: Scheduled Tasks — DISABLED on iOS (platform limitation)
                // Task tools require client-side execution (GRDB, FTS, multi-round LLM↔tool loop)
                // which cannot run reliably in background on iOS. Silent pushes are throttled overnight,
                // and NSE runs in a separate process without database access.
                // Scheduled tasks remain Thunderbird-only.
                // TaskAddTool(),
                // TaskDelTool(),
                // TaskEditTool(),
                ContactSearchTool(),
                ContactAddTool(),
                ContactEditTool(),
                ContactDeleteTool(),
                CalendarReadTool(),
                CalendarSearchTool(),
                CalendarEventReadTool(),
                CalendarEventCreateTool(),
                CalendarEventEditTool(),
                CalendarEventDeleteTool(),
                EmailOpenTool(),
                WebReadTool(),
                ChangeSettingTool(),
                TemplateReadTool(),
                TemplateCreateTool(),
                TemplateEditTool(),
                TemplateDeleteTool(),
                TemplateShareTool(),
                TemplateSearchTool(),
                TemplateDownloadTool(),
                TemplateToggleTool(),
            ])
            print("[TabMailApp] Registered \(await registry.registeredNames().count) client-side tools")
        }

        // Initialize FTS search index + embedding service (both async to avoid blocking launch).
        // Task.detached avoids inheriting main actor context — prevents FTS completion
        // callback from competing for main actor time right after splash dismissal.
        Task.detached {
            // FTS init reads from the main DB to seed/reconcile the index —
            // wait for migrations to finish (AppDatabase.dbPool is force-
            // unwrapped, see AppStartup).
            await AppStartup.shared.awaitReady()
            do {
                try await SearchIndex.shared.initialize()
            } catch {
                print("[TabMailApp] FTS index initialization failed: \(error)")
            }
        }
        Task.detached(priority: .utility) {
            await AppStartup.shared.awaitReady()
            EmbeddingService.initialize()
        }

        // Configure TipKit for onboarding hints
        if ScreenshotMode.isActive || ScreenshotMode.isSplashMode {
            // Suppress all tips in screenshot mode
            try? Tips.configure([
                .datastoreLocation(.applicationDefault)
            ])
            Tips.hideAllTipsForTesting()
        } else {
            try? Tips.configure([
                .displayFrequency(.daily),
                .datastoreLocation(.applicationDefault)
            ])
        }

        // Enable battery monitoring for power-aware backfill (BackfillProfile).
        UIDevice.current.isBatteryMonitoringEnabled = true

        // WebKit warm-up moved OUT of init — see `warmUpWebKitIfNeeded()`, kicked
        // off from `body.task` once `isReady` (the inbox is on screen). A fixed
        // delay from init fired mid-render on a cold boot (where the inbox takes
        // >1s to appear), so the first WKWebView's cold WebContent/GPU process
        // launch competed with cold-launch rendering.

        // Request push notification permission and register for remote notifications.
        // Silent push (content-available: 1) works without user permission,
        // but we request alert+sound+badge for future visible notifications.
        // Skip in screenshot mode to avoid permission dialog blocking screenshots.
        if !ScreenshotMode.isActive && !ScreenshotMode.isSplashMode {
            Task {
                await PushNotificationService.shared.requestPermissionAndRegister()
            }
        }

        // Register background sync task (Tier 2)
        // using: .main so the handler runs on the main queue — matches @MainActor
        // isolation and prevents _dispatch_assert_queue_fail when Apple's internal
        // _runTask:registration: asserts the handler queue.
        BackgroundSyncLogger.log("TabMailApp.init: registering BGTask handlers")
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncScheduler.backgroundTaskIdentifier,
            using: .main
        ) { task in
            BackgroundSyncLogger.log("BGAppRefresh HANDLER FIRED")
            Task { @MainActor in
                SyncScheduler.shared.handleBackgroundSync(task as! BGAppRefreshTask)
            }
        }

        // Register background AI processing task (Tier 3: long-running, up to ~10 min)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncScheduler.backgroundAITaskIdentifier,
            using: .main
        ) { task in
            BackgroundSyncLogger.log("BGProcessing HANDLER FIRED")
            Task { @MainActor in
                SyncScheduler.shared.handleBackgroundAIProcessing(task as! BGProcessingTask)
            }
        }

        // Start MainActor stall detector. Background timer that dispatches
        // onto main every 100ms and logs whenever the main-queue turnaround
        // exceeds 200ms — pinpoints UI hangs at the source (which main-actor
        // operation blocked). See MainActorStallDetector.swift for details.
        MainActorStallDetector.start()

        // Re-activate the demo-recording touch visualizer if it was left on.
        // Available in all builds (gated behind the hidden debug menu, not
        // #if DEBUG) so demos can be recorded from a TestFlight build. Inert
        // unless the toggle is on. Toggle: Settings → Debug.
        TouchVisualizer.shared.activateIfEnabled()
    }

    /// Guards the one-shot WebKit warm-up (`body.task` can re-run on scene changes).
    @MainActor private static var hasWarmedUpWebKit = false

    /// Prime the shared WKWebView process pool AFTER the inbox is on screen, so the
    /// first (cold) WebContent/GPU process launch never competes with cold-launch
    /// rendering. Eliminates ~300-500ms lag on the user's first message-open; the
    /// process pool is shared (iOS 15+) and persists, so the throwaway view can be
    /// released once `loadHTMLString` has kicked the content process off. Driven
    /// from `body.task` (the foreground UI path): a cold BACKGROUND launch has no
    /// UI and never opens a message, so it correctly skips warm-up entirely.
    @MainActor private static func warmUpWebKitIfNeeded() {
        guard !hasWarmedUpWebKit else { return }
        hasWarmedUpWebKit = true
        Task { @MainActor in
            // Brief settle so the inbox's first frame paints before we spin up
            // the (cold) WebKit content process.
            try? await Task.sleep(for: .milliseconds(500))
            let warmup = WKWebView(frame: .zero)
            warmup.loadHTMLString(" ", baseURL: nil)
            try? await Task.sleep(for: .milliseconds(500))
            _ = warmup
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let failure = startup.failureMessage {
                    // Catastrophic DB open/migration failure (rare). Relaunch
                    // retries — migrations are idempotent / flag-gated — so we
                    // surface a message instead of crashing.
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Couldn’t start TabMail")
                            .font(.headline)
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if startup.isReady {
                    RootView()
                        .environment(navigationStore)
                        .environment(storeKitManager)
                        .task { storeKitManager.start() }
                        .onOpenURL { url in
                            guard let request = MailtoRequest.parse(url) else { return }
                            NotificationCenter.default.post(
                                name: .contactPillComposeTapped,
                                object: nil,
                                userInfo: request.toUserInfo()
                            )
                        }
                        .onChange(of: scenePhase) { _, newPhase in
                            if newPhase == .active {
                                Task { await NotificationCleanupService.sweepOnForeground() }
                            }
                        }
                } else if startup.isMigrating {
                    // ONLY shown once we've confirmed real (and potentially slow)
                    // migration work on an existing database. The gating splash
                    // reads as honest progress, not a frozen launch (RC2 fix,
                    // PLAN_HANG_FIX).
                    SplashView(mode: .migrating)
                } else {
                    // Probing for pending migrations (fast) or running an instant
                    // already-migrated / fresh-install startup. Match the iOS
                    // launch screen (empty UILaunchScreen = system background) so
                    // there's no flash of the "Updating…" splash when nothing is
                    // actually migrating.
                    Color(.systemBackground)
                        .ignoresSafeArea()
                }
            }
            .preferredColorScheme(ScreenshotMode.isDarkMode ? .dark : nil)
            .task {
                // Build + migrate the DB OFF the main thread, then flip to the
                // inbox. Gating entry until this completes means there is no
                // window of half-repaired derived data (the app doesn't operate
                // mid-migration).
                await startup.runIfNeeded(navigationStore: navigationStore)
                // Inbox is now on screen — prime WebKit off the cold-launch
                // render path (no-op on a background launch: isReady stays false).
                if startup.isReady { Self.warmUpWebKitIfNeeded() }
            }
        }
    }
}

/// Coordinates the one-time, potentially-slow database startup so it runs OFF
/// the synchronous launch path, instead of freezing `TabMailApp.init` (RC2 fix —
/// see PLAN_HANG_FIX).
///
/// The GRDB schema migrator + one-time data resets include O(mailbox-size)
/// thread-repair migrations (v9/v27/v47/v53/v54) that can take minutes after a
/// multi-version jump. Doing that synchronously in init froze the app with no UI
/// ("hang on boot").
///
/// The build (`ensureDatabaseReady`) is `navigationStore`-independent and driven
/// from TWO launch paths so it runs no matter how the process starts:
///   • `AppDelegate.didFinishLaunchingWithOptions` — fires on EVERY launch,
///     including cold BACKGROUND launches (silent push / BGTask / notification
///     action) where the SwiftUI scene `.task` never runs.
///   • `TabMailApp.body.task` (via `runIfNeeded`) — the foreground path, which
///     additionally runs the UI-only sidebar load and flips `isReady`.
/// Relying solely on `body.task` was a regression: background launches left
/// `AppDatabase.shared` nil → BGTask handlers crashed and push/notification
/// handlers hung on `awaitReady()`.
///
/// It runs in two phases on a background task:
///   1. **Probe** — open the pool and cheaply check for pending migration work
///      (`AppDatabase.hasPendingMigrationWork`). While this runs the UI shows a
///      blank launch screen (matching the empty `UILaunchScreen`).
///   2. **Migrate + load** — run the migrations/resets and the DB-dependent
///      launch steps. ONLY if Phase 1 found real work on an existing DB do we
///      flip `isMigrating` to show `SplashView(mode: .migrating)`; otherwise the
///      blank launch screen holds until `isReady` flips straight to the inbox.
///      This keeps the migration splash from flashing on every normal launch.
///
/// CRITICAL invariant: until `ensureDatabaseReady()` completes, `AppDatabase.shared`
/// is nil and `AppDatabase.dbPool` (which force-unwraps it) MUST NOT be touched.
/// The UI is gated by the launch screen / splash; background / UIKit entry points
/// that can fire during this window (silent push, notification actions, BGTask
/// sync/AI) gate via `awaitReady()`.
@MainActor
@Observable
final class AppStartup {
    static let shared = AppStartup()

    /// True once the database is built + migrated and the initial sidebar load
    /// has run. Drives the splash → inbox transition.
    private(set) var isReady = false

    /// True once we've confirmed there is real, potentially-slow migration work
    /// to run on an EXISTING database — drives the one-time "Updating…" splash.
    /// Stays false on the common path (already-migrated DB) and on fresh
    /// installs, so the launch screen shows blank until the inbox is ready
    /// instead of flashing the migration splash on every launch.
    private(set) var isMigrating = false

    /// Set on a catastrophic DB open/migration failure; drives the failure view.
    private(set) var failureMessage: String?

    /// Guards against re-entry into the database build (the gating view's `.task`
    /// and the AppDelegate launch trigger can both call in).
    private var hasStarted = false

    /// True once the database pool is built, migrated, and published
    /// (`AppDatabase.shared`) and the non-UI DB-dependent launch steps have run.
    /// This — NOT `isReady` — is what background entry points wait on, because a
    /// cold BACKGROUND launch (silent push / BGTask / notification action) never
    /// runs `loadInitialData`/`isReady` (no UI), yet still needs a usable DB.
    private var dbReady = false

    /// Continuations parked by `ensureDatabaseReady()` while the DB is building.
    private var dbWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Builds + migrates the database (once) and runs the non-UI DB-dependent
    /// launch steps (screenshot seed, orphan demo wipe, NSE staging + mirror).
    /// Idempotent and `navigationStore`-independent so it can be driven from ANY
    /// launch path — the foreground `body.task` (via `runIfNeeded`) AND
    /// `AppDelegate.didFinishLaunchingWithOptions` (which always runs, including
    /// cold BACKGROUND launches where the SwiftUI scene `.task` never fires).
    /// Concurrent callers while a build is in flight park on `dbWaiters` rather
    /// than starting a second build.
    func ensureDatabaseReady() async {
        if dbReady { return }
        if hasStarted {
            // A build is already running (started by another launch path).
            // Park until it finishes — don't start a second one.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if dbReady { cont.resume() } else { dbWaiters.append(cont) }
            }
            return
        }
        hasStarted = true

        let t0 = CFAbsoluteTimeGetCurrent()

        // Whether the DB file pre-exists THIS launch — captured BEFORE
        // `makePool()` creates it. A fresh/empty DB migrates instantly, so we
        // never show the migration splash on first install (it would falsely
        // read "Updating…" with nothing to update).
        let dbExisted = FileManager.default.fileExists(atPath: AppDatabase.databaseURL.path)

        // Phase 1 (off main): open the pool + cheaply probe for pending migration
        // work. Fast — opens the connection and reads the migrator's applied set
        // + the one-time-reset flags. The heavy migration passes are Phase 2.
        let probe: (pool: DatabasePool, pending: Bool)? =
            await Task.detached(priority: .userInitiated) {
                do {
                    let pool = try AppDatabase.makePool()
                    let pending = try AppDatabase.hasPendingMigrationWork(pool)
                    return (pool, pending)
                } catch {
                    BackgroundSyncLogger.log("AppStartup: pool open/probe FAILED: \(error)")
                    return nil
                }
            }.value

        guard let probe else {
            failureMessage = "TabMail couldn’t open its local database. Please relaunch the app."
            resumeDBWaiters()
            return
        }

        // Only NOW — knowing there is real (and potentially slow) migration work
        // on an existing mailbox — switch from the blank launch screen to the
        // "Updating…" splash. The common case (already-migrated DB) skips this
        // and stays blank until `isReady` flips straight to the inbox.
        if probe.pending && dbExisted {
            isMigrating = true
            BackgroundSyncLogger.log("AppStartup: pending migration work on existing DB — showing migration splash")
        }

        // Phase 2 (off main): run schema + data-repair migrations + one-time
        // resets on the probed pool, then publish it. This is the work that used
        // to freeze launch; it now runs behind the gating splash (when shown).
        let pool = probe.pool
        let built = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                let db = try AppDatabase(pool: pool, runStartupResets: true)
                AppDatabase.shared.withLock { $0 = db }
                return true
            } catch {
                BackgroundSyncLogger.log("AppStartup: AppDatabase build FAILED: \(error)")
                return false
            }
        }.value

        guard built else {
            failureMessage = "TabMail couldn’t open its local database. Please relaunch the app."
            resumeDBWaiters()
            return
        }
        BackgroundSyncLogger.log("AppStartup: database ready in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")

        // DB-dependent NON-UI launch steps, in the same spirit/order as before
        // (all touch AppDatabase / shared UserDefaults). These previously lived
        // in `didFinishLaunchingWithOptions` (NSE staging + mirror) and run on
        // every launch type — restoring that by living here behind the trigger:
        //   • screenshot seeding (only under --screenshot-mode)
        //   • orphan demo-row wipe (demo state never persists across launches)
        //   • NSE staging DB creation + state mirror
        ScreenshotMode.seedIfNeeded()
        ScreenshotMode.seedChatSessionsIfNeeded()
        if let db = AppDatabase.shared.withLock({ $0 }) {
            do {
                // Async context → GRDB's async `write` overload (non-blocking).
                try await db.dbPool.write { conn in try DemoSeed.wipe(conn) }
            } catch {
                print("[AppStartup] Orphan demo wipe failed: \(error)")
            }
        }
        // DB is usable — unblock everything parked in `awaitReady()` (background
        // push / notification-action / BGTask handlers, detached startup tasks).
        // Flip this BEFORE the staging-DB upkeep below: that work is NOT needed to
        // present the inbox, so it must never sit in front of this gate.
        dbReady = true
        resumeDBWaiters()

        // NSE staging-DB schema upkeep + state mirror — OFF the launch gate.
        // Neither is needed to show the inbox: `mergeNSEStagingData` tolerates a
        // missing staging file, and `mirror*` only feeds the NSE's NEXT push.
        // The staging DB is a SEPARATE App-Group `DatabaseQueue` whose creation
        // takes a CROSS-PROCESS write lock — blocking up to 2s when an NSE is
        // mid-write on a fresh push (the intermittent post-push cold-launch
        // blank-screen case) — so it can never gate `isReady`. Now version-gated
        // (`createNSEStagingDBIfNeeded`) so the steady-state path is a no-op (no
        // lock taken at all); the rare first-run / schema-bump write lands behind
        // the already-shown inbox. Safe to detach un-awaited: the main app is the
        // sole schema creator, but the file already exists from a prior launch on
        // any device that has ever received a push (a push requires a prior
        // foreground sign-in launch, which created it), so no consumer here races
        // a missing schema. `mirrorAllState`'s main-DB reads also move off the
        // main actor as a bonus.
        Task.detached(priority: .utility) {
            AppDatabase.createNSEStagingDBIfNeeded()
            NSEDataBridge.mirrorAllState()
        }
    }

    /// Resume + clear all `ensureDatabaseReady` waiters. Called on success AND on
    /// catastrophic-failure exits so background callers never hang indefinitely.
    private func resumeDBWaiters() {
        let waiters = dbWaiters
        dbWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Foreground entry: build the DB (if not already) then run the UI-only step
    /// — the initial sidebar load — and flip `isReady` to route splash → inbox.
    /// Called from `TabMailApp.body.task`. Idempotent.
    func runIfNeeded(navigationStore: NavigationStore) async {
        await ensureDatabaseReady()
        // Build failed (failureMessage shown) or the sidebar already loaded.
        guard dbReady, !isReady else { return }
        navigationStore.loadInitialData()
        isReady = true
    }

    /// Suspends until the database is usable, kicking off the build if no launch
    /// path has yet. Used by UIKit push / notification / BGTask handlers that can
    /// fire on a cold BACKGROUND launch (where `body.task` never runs) or during
    /// the migration window — see `AppDelegate` / `SyncScheduler`.
    func awaitReady() async {
        await ensureDatabaseReady()
    }
}
