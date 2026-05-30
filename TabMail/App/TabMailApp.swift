/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import BackgroundTasks
import UserNotifications
import WebKit
import TipKit

@main
struct TabMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var navigationStore = NavigationStore()
    @State private var storeKitManager = StoreKitManager()
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

        // Initialize GRDB database
        do {
            let db = try AppDatabase()
            AppDatabase.shared.withLock { $0 = db }
            print("[TabMailApp] AppDatabase created successfully")
        } catch {
            fatalError("[TabMailApp] Failed to create AppDatabase: \(error)")
        }

        // Seed demo data for App Store screenshots (only when launched with --screenshot-mode)
        // MUST be after AppDatabase init since it writes to GRDB.
        ScreenshotMode.seedIfNeeded()
        ScreenshotMode.seedChatSessionsIfNeeded()

        // Demo state never persists across launches.
        // If the previous session was force-quit during demo (or otherwise
        // failed to call DemoModeService.exit), demo rows linger in GRDB
        // and would make navigationStore think a real account exists,
        // routing past the login screen. Wipe synchronously before
        // navigationStore reads. Idempotent — no-op when no demo rows exist.
        if let db = AppDatabase.shared.withLock({ $0 }) {
            do {
                try db.dbPool.write { conn in try DemoSeed.wipe(conn) }
            } catch {
                print("[TabMailApp] Orphan demo wipe failed: \(error)")
            }
        }

        // Eagerly load accounts/folders from GRDB so RootView's first render
        // skips the splash (isInitialLoadComplete is true before body evaluates).
        // This is a fast synchronous read (~20-50ms) — safe in init.
        navigationStore.loadInitialData()


        // Register client-side tools for AI agent chat (matching TB's core.js TOOL_IMPL).
        // Task.detached avoids inheriting main actor context — eliminates 26 main-actor
        // round-trips that compete with post-splash UI layout. registerAll does a single actor hop.
        Task.detached {
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
            do {
                try await SearchIndex.shared.initialize()
            } catch {
                print("[TabMailApp] FTS index initialization failed: \(error)")
            }
        }
        Task.detached(priority: .utility) {
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

        // Warm up WebKit — eliminates ~300-500ms cold-start lag when user
        // opens their first message. Since iOS 15+ all WKWebViews share a
        // single process pool automatically, so any warmup view primes them all.
        // Deferred by 1s so it doesn't compete with main thread during inbox render.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let warmup = WKWebView(frame: .zero)
            warmup.loadHTMLString(" ", baseURL: nil)
            try? await Task.sleep(for: .milliseconds(500))
            _ = warmup
        }

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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(navigationStore)
                .environment(storeKitManager)
                .preferredColorScheme(ScreenshotMode.isDarkMode ? .dark : nil)
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
        }
    }
}
