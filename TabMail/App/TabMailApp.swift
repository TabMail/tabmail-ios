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
    /// Flips true ~1s into a launch that hasn't reached the inbox yet, to show the
    /// branded loading splash. The delay means a fast resume (inbox in <1s) never
    /// flashes it — it goes blank-launch-screen straight to the inbox; only a slow
    /// cold boot crosses the 1s threshold and gets the splash.
    @State private var showDelayedSplash = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First app-code mark — its `+Nms` is the pre-main (dyld / runtime /
        // static-init) cost, usually the biggest single chunk of a cold launch.
        BootProfiler.mark("TabMailApp.init enter")
        let sessionStore = TabMailSessionStore.shared
        let sessionLaunchState = Self.prepareSessionStorageForLaunch(sessionStore: sessionStore)
        let hadLaunchedBefore = sessionLaunchState.hadLaunchedBefore
        let dbExists = sessionLaunchState.databaseExists

        if !sessionStore.isCleanupPending {
            do {
                try sessionStore.migrateLegacySession {
                    (try? JSONDecoder().decode(TabMailSession.self, from: $0)) != nil
                }
            } catch {
                AuthDiagnostics.log("Local session migration remains retryable (\(error))")
            }
            sessionStore.sweepInactiveGenerations()
        }
        let hasSessionAfter = TabMailAuthService.hasSession()
        AuthDiagnostics.log("Post-init: session=\(hasSessionAfter)")

        // Record first launch date for overdue reminder suppression (v1.0.1).
        // Only on truly fresh installs (no prior launch, no existing DB). Upgrading
        // 1.0.0 users already have their reminders and should not be affected.
        if !hadLaunchedBefore && !dbExists {
            if UserDefaults.standard.object(forKey: "firstLaunchDate") == nil {
                UserDefaults.standard.set(Date(), forKey: "firstLaunchDate")
                if DebugModeManager.isLoggingEnabled() { print("[TabMailApp] Fresh install — recorded firstLaunchDate for overdue reminder suppression") }
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
            if DebugModeManager.isLoggingEnabled() { print("[TabMailApp] Migration: proactive reminder notifications enabled by default") }
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
        // background entry points gate via `awaitLaunchReady(background: true)`.


        // Client-side AI tools are registered LAZILY on first tool use
        // (`ToolRegistry.ensureDefaultToolsRegistered`, called from
        // `BackendClient.sendCompletionsWithTools`) instead of at launch — keeps the
        // 35-tool allocation + actor hop off the cold-launch CPU burst that competes
        // with the inbox first render. Only the agent chat / reply-precompute / inline-
        // edit paths use tools, so the first such request pays the one-time cost.

        // EmbeddingService (CoreML, ~45MB) inits off the launch path at .utility.
        // It MUST land AFTER the first paint so it can't compete with the cold-boot
        // critical path (the privileged NSE staging merge + first render). Gating on
        // dbReady (`awaitLaunchReady(background: true)`) used to *empirically* achieve
        // that — the fast inbox render won the race and this `.utility` load got CPU
        // later — but
        // that's soft: once the merge runs BEFORE paint (`runIfNeeded`), a contended
        // merge stretches the pre-paint window and the CoreML load starves it (a
        // debug cold boot showed an 11s load running CONCURRENTLY with the merge,
        // turning a ~50ms merge into 10.5s and blocking first paint for 17.6s). So
        // gate HARD on first paint via `awaitLaunchReady(background: false)`. Background
        // launches never paint — its timeout lets the embedding backfill still load (the merge has
        // long finished, unburdened, by then). Consumers nil-guard
        // `EmbeddingService.shared` and degrade to keyword-only until it lands. Left
        // here (not in body.task) so a cold BACKGROUND launch still loads it.
        Task.detached(priority: .utility) {
            // background: false → wait for first paint (foreground) so the CoreML
            // load can't starve the pre-paint merge / first render. On a cold
            // BACKGROUND launch (no paint) the shorter `embeddingLoadGateTimeoutSeconds`
            // applies instead of the 8s herd default: just long enough for the
            // now-unburdened merge to win the CPU, then load — no wasted budget.
            await AppStartup.shared.awaitLaunchReady(
                background: false,
                firstPaintTimeoutSeconds: SyncConfig.embeddingLoadGateTimeoutSeconds
            )
            BootProfiler.mark("EmbeddingService.initialize() START (CoreML ~45MB, .utility, post-first-paint)")
            // Restored from `v2final` (`e28dd4edb`) — `EmbeddingStartupPolicy`.
            // An app-hosted XCTest launch would otherwise compile and load the
            // ~45 MB bundled CoreML model in every unit-test process, for tests
            // that never embed anything. RELEASE BUILDS HAVE NO SEAM AND NO
            // BRANCH: the `#else` arm is the plain call, so shipped behaviour is
            // byte-for-byte what it was.
            #if DEBUG
            let embeddingDecision = EmbeddingStartupPolicy.initializeForAppStartup()
            if embeddingDecision == .skippedUnitTestHost {
                BootProfiler.mark("EmbeddingService.initialize() SKIPPED (unit-test host)")
            }
            #else
            EmbeddingService.initialize()
            #endif
            BootProfiler.mark("EmbeddingService.initialize() DONE")
        }
        // SearchIndex's eager init is deliberately NOT here. Its 257k-doc FTS open
        // was landing IN the inbox first-render window (it fired at dbReady, before
        // the paint, per device logs: "Opening FTS database" mid-stall). Moved to
        // `deferredSearchIndexInitIfNeeded()`, kicked from body.task AFTER the inbox
        // renders. Safe: the FTS WRITE paths (`indexHeaders`/`updateBodies`/…) call
        // `ensureReady()`, so any earlier consumer — foreground sync indexing, and
        // background push/sync (which never runs body.task) — self-initializes the
        // index and can't silently drop a write (completion is gated on confirmed-
        // write return sets; `recoverIncompleteHeaders`/`selfHealFTSBodyMembership`
        // re-index any miss). The deferred init only makes foreground SEARCH ready
        // promptly without racing the first render.

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
        BootProfiler.mark("TabMailApp.init exit (sync work done; DB build is async)")
    }

    /// Resolves the session-storage decision made once per app-process launch.
    /// A durable failed cleanup is retried before the returning-user database
    /// heuristic can suppress fresh-install cleanup.
    @MainActor
    static func prepareSessionStorageForLaunch(
        sessionStore: TabMailSessionStore = .shared,
        launchDefaults: UserDefaults = .standard,
        databaseExists: () -> Bool = {
            let dbPath = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("TabMail/tabmail.sqlite").path
            return FileManager.default.fileExists(atPath: dbPath)
        }
    ) -> (hadLaunchedBefore: Bool, databaseExists: Bool) {
        // A failed fresh-install wipe is durable and outranks every heuristic.
        // Resolve it before consulting UserDefaults or the database: creating a
        // database during the failed launch must not turn the next launch into
        // a false "returning user" that adopts surviving credentials.
        if sessionStore.isCleanupPending,
           TabMailAuthService.completeSession(
               mode: .deleteAll,
               notify: false,
               sessionStore: sessionStore
           ) {
            sessionStore.clearCleanupPending()
            DebugModeManager.invalidateLoggingCache()
        }

        // Detect fresh install: UserDefaults is cleared on reinstall, Keychain is not.
        // If this is a fresh install but Keychain has stale data, clear it.
        // GUARD: also check for existing GRDB database file. If the database exists,
        // the user has data — UserDefaults was reset spuriously (TestFlight update,
        // backup restore, etc.) and we must NOT clear the Keychain session.
        let hasLaunchedKey = "hasLaunchedBefore"
        let hadLaunchedBefore = launchDefaults.bool(forKey: hasLaunchedKey)
        let dbExists = databaseExists()
        AuthDiagnostics.log("Launch: hasLaunchedBefore=\(hadLaunchedBefore), dbExists=\(dbExists)")

        guard !hadLaunchedBefore else {
            return (hadLaunchedBefore, dbExists)
        }

        if dbExists {
            // Database exists — this is NOT a fresh install. UserDefaults was cleared
            // spuriously (TestFlight, backup restore, etc.). Do NOT nuke the session.
            AuthDiagnostics.log("UserDefaults reset but database exists — skipping session clear (false fresh-install)")
        } else {
            // Truly fresh install. Persist the gate BEFORE destructive work;
            // both app and NSE fail closed until a verified zero-item cleanup.
            AuthDiagnostics.log("Fresh install detected — clearing stale Keychain data")
            sessionStore.markCleanupPending()
            if TabMailAuthService.completeSession(
                mode: .deleteAll,
                notify: false,
                sessionStore: sessionStore
            ) {
                sessionStore.clearCleanupPending()
                DebugModeManager.invalidateLoggingCache()
            }
        }
        launchDefaults.set(true, forKey: hasLaunchedKey)
        return (hadLaunchedBefore, dbExists)
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
        let kickedAt = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            // Brief settle so the inbox's first frame paints before we spin up
            // the (cold) WebKit content process.
            try? await Task.sleep(for: .milliseconds(500))
            // INSTRUMENTATION (2026-08-06): the post-paint window carried a
            // ~1320ms main-thread block with ~606ms of it holding no marks at
            // all, and this warm-up is the only @MainActor consumer kicked from
            // `body.task` that was completely unmarked. Both facts below are
            // needed to read the next capture:
            //   • `resumedAfter` — the sleep is 500ms but the continuation
            //     resumes ON THE MAIN ACTOR, so a value >500ms means the main
            //     actor was still busy (first render) when the warm-up came
            //     due, and the WebKit spin-up below therefore lands INSIDE that
            //     busy window instead of after it.
            //   • the per-step deltas — `WKWebView(frame:.zero)` on a cold
            //     process launches the WebContent/GPU/Networking processes and
            //     is synchronous main-thread work.
            let resumedAfter = Int((CFAbsoluteTimeGetCurrent() - kickedAt) * 1000)
            BootProfiler.mark("webkit warm-up: settle resumed on main actor after \(resumedAfter)ms (nominal 500ms — excess = main actor was busy)")
            let allocT0 = CFAbsoluteTimeGetCurrent()
            let warmup = WKWebView(frame: .zero)
            BootProfiler.mark("webkit warm-up: WKWebView(frame:.zero) init \(Int((CFAbsoluteTimeGetCurrent() - allocT0) * 1000))ms — @MainActor, cold WebContent/GPU process launch")
            let loadT0 = CFAbsoluteTimeGetCurrent()
            warmup.loadHTMLString(" ", baseURL: nil)
            BootProfiler.mark("webkit warm-up: loadHTMLString \(Int((CFAbsoluteTimeGetCurrent() - loadT0) * 1000))ms — @MainActor")
            try? await Task.sleep(for: .milliseconds(500))
            _ = warmup
            BootProfiler.mark("webkit warm-up DONE (\(Int((CFAbsoluteTimeGetCurrent() - kickedAt) * 1000))ms since the body.task kick, incl. two 500ms settles)")
        }
    }

    @MainActor private static var didDeferSearchInit = false

    /// Initialize the FTS search index AFTER the inbox first render, so its (large)
    /// 257k-doc open doesn't compete for CPU/IO with the first paint — it previously
    /// fired at `dbReady` (pre-render) and showed up mid-stall in device logs.
    /// Foreground-only (driven from `body.task`): a cold BACKGROUND launch never runs
    /// `body.task` and doesn't need this — SearchIndex's write methods call
    /// `ensureReady()`, so push/sync FTS indexing self-initializes the index there.
    @MainActor private static func deferredSearchIndexInitIfNeeded() {
        guard !didDeferSearchInit else { return }
        didDeferSearchInit = true
        Task.detached {
            // Settle past the inbox first-render stall before the FTS open.
            try? await Task.sleep(for: .milliseconds(500))
            // ISOLATION, stated explicitly so a boot capture is not misread
            // (2026-08-06): `SearchIndex` is a plain `actor` (no global-actor
            // annotation) reached from a `Task.detached`, so `initialize()` —
            // the 250k-doc / 17-shard FTS open — runs on the SearchIndex actor's
            // executor on the cooperative pool, NOT on the main actor. The Δ
            // between these two marks is therefore ELAPSED time, not main-thread
            // time: it overlaps the first render, it does not constitute it.
            BootProfiler.mark("SearchIndex.initialize() START (FTS open, post-paint +500ms; SearchIndex actor executor — NOT main actor)")
            do {
                try await SearchIndex.shared.initialize()
                BootProfiler.mark("SearchIndex.initialize() DONE (FTS ready; off-main — this Δ is elapsed, not main-thread, time)")
            } catch {
                if DebugModeManager.isLoggingEnabled() { print("[TabMailApp] FTS index initialization failed: \(error)") }
            }
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
                        .task {
                            // Post-paint @MainActor deferral (previously unmarked;
                            // its `[StoreKit] Loading products` line lands inside the
                            // post-first-paint main-thread block). `start()` itself is
                            // synchronous — it spawns the transaction listener and the
                            // product load — so this Δ is the main-actor cost only.
                            let storeKitT0 = CFAbsoluteTimeGetCurrent()
                            storeKitManager.start()
                            BootProfiler.mark("post-paint: storeKitManager.start() \(Int((CFAbsoluteTimeGetCurrent() - storeKitT0) * 1000))ms @MainActor (product load continues async)")
                        }
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
                        // Inbox appears instantly (no transition) so only the splash
                        // animates over it on the swap — keeps fast resumes snappy and
                        // avoids animating the inbox's ScrollViews.
                        .transition(.identity)
                } else if startup.isMigrating {
                    // ONLY shown once we've confirmed real (and potentially slow)
                    // migration work on an existing database. The gating splash
                    // reads as honest progress, not a frozen launch (RC2 fix,
                    // PLAN_HANG_FIX).
                    SplashView(mode: .migrating)
                } else if showDelayedSplash {
                    // The launch has crossed the 600ms threshold (see below) without
                    // reaching the inbox, so show the branded loading splash — a slow
                    // cold boot reads as "loading", not a frozen blank screen. Fades
                    // in (300ms) on insert and out (300ms) on the swap to the inbox so
                    // it blends rather than hard-cutting ("click-clack").
                    SplashView(mode: .loading)
                        .transition(.opacity)
                } else {
                    // First 600ms of launch: a blank screen matching the empty
                    // UILaunchScreen (system background), so a FAST resume shows
                    // nothing extra and flips straight to the inbox. If we're still
                    // not ready after 600ms, `showDelayedSplash` flips (with a 300ms
                    // ease-in) and the branded loading splash (above) takes over.
                    // (Probing for pending migrations / an instant already-migrated
                    // startup also lands here, briefly, before isReady.)
                    Color(.systemBackground)
                        .ignoresSafeArea()
                        .transition(.identity)
                        .task {
                            try? await Task.sleep(for: .milliseconds(600))
                            if !Task.isCancelled {
                                withAnimation(.easeIn(duration: 0.3)) { showDelayedSplash = true }
                            }
                        }
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
                if startup.isReady {
                    BootProfiler.mark("body.task: post-paint deferrals kicked (WebKit warm-up + FTS)")
                    Self.warmUpWebKitIfNeeded()
                    Self.deferredSearchIndexInitIfNeeded()
                }
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
/// handlers hung on `awaitLaunchReady()`.
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
/// sync/AI) gate via `awaitLaunchReady(background: true)`.
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
    // `private(set)` so the NSE merge's deferred-herd gate can tell a real,
    // booted foreground app (dbReady == true at merge time) from a unit test that
    // never boots AppStartup (false) — see `NSEDataBridge.flushNSEBatchToFTS`.
    private(set) var dbReady = false

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
        BootProfiler.mark("ensureDatabaseReady enter (dbExisted=\(dbExisted))")

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
        BootProfiler.mark("db.probe done (pendingMigration=\(probe.pending))")
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
        BootProfiler.mark("db.built+migrated (AppDatabase.shared published)")

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
                // Gate the orphan demo-row wipe on a CHEAP indexed existence
                // check first. `DemoSeed.wipe` is a series of DELETEs — several
                // are unindexed `LIKE 'demo-account:%'` full table scans over
                // messageHeader/messageBody — and it runs BEFORE `dbReady`, so on
                // a large mailbox it directly delayed FIRST PAINT (≈10s in the
                // 2026-06-26 cold-boot trace). A normal launch has no demo data,
                // so the single PK lookup short-circuits the scans entirely. Only
                // an actual seeded/interrupted-demo launch pays for the wipe — and
                // it stays on the gate there so no demo rows flash into the inbox.
                let hasDemo = try await db.dbPool.read { try DemoSeed.hasDemoData($0) }
                BootProfiler.mark("DemoSeed existence check (hasDemo=\(hasDemo))")
                if hasDemo {
                    try await db.dbPool.write { conn in try DemoSeed.wipe(conn) }
                    BootProfiler.mark("DemoSeed.wipe done")
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() { print("[AppStartup] Orphan demo wipe failed: \(error)") }
            }
        }
        // DB is usable — unblock everything parked in `awaitLaunchReady` (background
        // push / notification-action / BGTask handlers, detached startup tasks).
        // Flip this BEFORE the staging-DB upkeep below: that work is NOT needed to
        // present the inbox, so it must never sit in front of this gate.
        dbReady = true
        resumeDBWaiters()
        BootProfiler.mark("dbReady=true (push / NSE-merge / BGTask waiters unblocked)")

        // v1.7.1 one-shot epoch rebuild — OFF the launch gate, and it CANNOT sit in
        // `StartupMigrations` (which runs synchronously inside `AppDatabase.init`,
        // before `AppDatabase.shared` is published): the arm goes through
        // `uidValidityResetArmFlag`, the single writer of that column, which is
        // `async` and lives on `AccountManager`. The one-cycle delay costs nothing —
        // the flag is durable, the arm is idempotent, and a folder that syncs once
        // before being armed is simply purged and resynced on its next pass.
        Task.detached(priority: .utility) {
            await AccountManager.shared.armImapUidValidityResetForEpochRebuildIfNeeded()
        }

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
            BootProfiler.mark("NSE staging upkeep + mirrorAllState START (.utility, off-gate)")
            AppDatabase.createNSEStagingDBIfNeeded()
            NSEDataBridge.mirrorAllState()
            BootProfiler.mark("NSE staging upkeep + mirrorAllState DONE")
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
        // Debug-gated (no-op unless debug logging is unlocked): stamps
        // "⚠ MAIN THREAD STALL ~Xms" into the BootProfile timeline so a reported
        // main-actor stall can be correlated against the surrounding merge/sync/
        // EXEC marks instead of inferred.
        BootProfiler.startStallWatchdog()
        // Merge NSE staging BEFORE the first read/render so the inbox's FIRST PAINT
        // already contains pushed mail — but via the FAIL-FAST probe path
        // (`mergeIfStagingPending`, immediateError busyMode). If the NSE is still
        // mid-write — a slow-network AI keeps it (and its 1Hz lease heartbeat) busy
        // past notification delivery — the probe returns "not pending" and we SKIP
        // rather than block FIRST PAINT on the staging busy-timeout (2s→5s). The
        // post-paint read-through merge picks the row up the instant the NSE frees
        // the cross-process file (row stays populated=1, nothing lost). So the
        // common fast path (staging readable → NSE done) keeps "message in first
        // frame", while a busy NSE on a slow network no longer regresses cold-boot
        // time. Changed from the unconditional blocking `mergeNSEStagingData()`
        // 2026-06-29 after cold-boot-OOO reports — the pre-paint merge must never
        // wait on the NSE's lock (same principle as FIX 6d's probe). The later
        // foreground/push merges remain as belt-and-suspenders.
        //
        // PAINT GATE (2026-07-03): await only until the merge publishes its
        // IN-MEMORY staged snapshot — not the full merge. The fail-fast probe
        // protected paint from the NSE's *lock* but not from a slow *write*:
        // phase-1's header upsert measured 7.6s on a cold-I/O boot (boot_logs 5)
        // while the snapshot the first frame renders from was ready at +700ms.
        // `InboxViewModel.resetMessages` (VM init, at paint) seeds from
        // `latestStagedRows`, so paint needs only the snapshot; phase-1/phase-2
        // land post-paint exactly like every foreground merge (ADR-IOS-049).
        await NSEDataBridge.mergeIfStagingPendingPaintGate()
        BootProfiler.mark("runIfNeeded: NSE staging merge gate (snapshot-or-done, pre-first-paint)")
        BootProfiler.mark("loadInitialData (sidebar: accounts/folders/outbox) START — @MainActor sync read")
        navigationStore.loadInitialData()
        BootProfiler.mark("loadInitialData DONE (accounts=\(navigationStore.accounts.count) folders=\(navigationStore.folders.count))")
        // Animate the splash → inbox swap: the loading splash fades OUT (300ms)
        // while the inbox appears instantly beneath it (RootView uses .identity).
        // Visually a no-op on a fast resume (blank → inbox are both .identity).
        withAnimation(.easeOut(duration: 0.3)) { isReady = true }
        BootProfiler.mark("★ isReady=true → FIRST PAINT (inbox on screen)")
    }

    /// Suspends until the launch milestone appropriate for the caller, kicking off
    /// the DB build if no launch path has yet. ONE gate; the `background` flag
    /// picks the milestone:
    ///
    /// - `background: true` → resume at **`dbReady`** (DB built + migrated). For
    ///   cold BACKGROUND entry points (push / silent-push / notification action /
    ///   BGTask) that never paint and are budget-bound: they're the time-critical
    ///   reason the app woke and must run ASAP, NOT wait for a first paint that
    ///   will never come.
    /// - `background: false` → resume at **first paint** (`isReady`), or after
    ///   `firstPaintTimeoutSeconds` as a fallback. For the deferrable FOREGROUND
    ///   boot herd (NSE merge / sync / queue repopulation / CoreML embedding load):
    ///   "show the inbox" is the sole priority of the first frame, none of that
    ///   work is needed to draw it, and NSE-staged mail already merged pre-paint
    ///   via the read-through. The timeout only bounds the pathological
    ///   never-paints case — and lets a task that runs on BOTH launch kinds (the
    ///   CoreML load) still proceed on a background launch.
    ///
    /// Both paths first `await ensureDatabaseReady()`, so a `false` caller is also
    /// guaranteed a usable DB even if it hits the timeout. The paint wait is polled
    /// (no continuation bookkeeping) — every caller is a one-shot boot task, so
    /// ~100ms granularity is invisible. Acyclic: the work that flips `isReady` (the
    /// pre-paint merge + `loadInitialData`, driven from `runIfNeeded`) never calls
    /// this with `background: false`, so a foreground waiter can't gate its own
    /// signal.
    func awaitLaunchReady(
        background: Bool,
        firstPaintTimeoutSeconds: Double = SyncConfig.firstPaintGateTimeoutSeconds
    ) async {
        await ensureDatabaseReady()
        guard !background else { return }
        let step = Duration.milliseconds(100)
        var waited = Duration.zero
        let limit = Duration.seconds(firstPaintTimeoutSeconds)
        while !isReady, waited < limit {
            // Bail on cancellation rather than busy-iterating: a cancelled
            // `Task.sleep` throws immediately, so without this the loop would
            // burst through `limit/step` no-op iterations on the MainActor.
            if Task.isCancelled { return }
            do { try await Task.sleep(for: step) } catch { return }
            waited += step
        }
    }
}
