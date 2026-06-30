/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
import UserNotifications
import Synchronization
import GRDB

/// Deep link payload from a tapped notification.
/// Stored in `PendingDeepLink.pending` so cold-start taps (before views mount)
/// are not lost — `MailNavigationView` consumes on appear.
enum PendingDeepLink: Sendable {
    case message(id: String)
    case inbox
    case taskResult(taskHash: String)
}

/// Thread-safe storage for deep links that arrive before the UI is ready.
enum PendingDeepLinkStore {
    static let pending = Mutex<PendingDeepLink?>(nil)

    static func store(_ link: PendingDeepLink) {
        pending.withLock { $0 = link }
    }

    static func consume() -> PendingDeepLink? {
        pending.withLock { value in
            let copy = value
            value = nil
            return copy
        }
    }
}

/// Cold-start-safe queue for consent-error notification taps. When the user
/// taps a `provider=consent_error` notification from the lock screen (app
/// terminated), `NotificationDelegate.didReceive` posts
/// `.pushConsentErrorsDetected` before `MailNavigationView` has mounted
/// its `.onReceive` — the NotificationCenter event is lost. AppDelegate
/// stores the affected emails here first; the view drains on `.onAppear`.
enum PendingConsentErrorStore {
    private static let pending = Mutex<[String]>([])

    static func store(_ emails: [String]) {
        pending.withLock { $0 = emails }
    }

    static func consume() -> [String] {
        pending.withLock { value in
            let copy = value
            value = []
            return copy
        }
    }
}

/// Separate delegate for UNUserNotificationCenter — must NOT be @MainActor
/// because the delegate methods are called on arbitrary threads by iOS.
/// AppDelegate is implicitly @MainActor (via UIApplicationDelegate), so
/// conforming to UNUserNotificationCenterDelegate on AppDelegate causes
/// Swift 6 isolation errors.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Handle notification while app is in foreground.
    /// For NSE pushes (email/task): suppress and trigger immediate sync.
    /// For other notifications (proactive, local): show normally.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let provider = userInfo["provider"] as? String
        print("[NotificationDelegate] willPresent notification: \(notification.request.identifier) provider=\(provider ?? "nil")")

        // NSE email/task pushes: suppress in foreground, trigger sync instead.
        // Fan-out chain stops naturally — app's sync discovers all new messages.
        if let provider, ["gmail", "outlook", "imap_new_mail", "task_alarm"].contains(provider) {
            Task { @MainActor in
                // A push can arrive during the one-time migration window; wait
                // for the DB before touching it (AppStartup / PLAN_HANG_FIX).
                await AppStartup.shared.awaitLaunchReady(background: true)
                await NSEDataBridge.mergeNSEStagingData()
                // willPresent only fires while the app is foreground-active, so request the
                // fast-path: syncStartup still cancels in-flight AI if the oracle detects any
                // background/suspension since the last recovery — it only skips when the app
                // is provably continuous-foreground (connections live, nothing to recover).
                await SyncScheduler.shared.syncStartup(inboxOnly: true, foregroundFastPath: true)
            }
            return []  // Suppress — user is already in the app
        }

        return [.banner, .sound, .list]
    }

    /// Handle notification tap — deep link to relevant message or chat.
    /// Uses completion-handler variant (NOT async) because UIKit's internal
    /// post-completion code (_updateSnapshotAndStateRestorationWithAction)
    /// asserts main thread. The async variant returns on a cooperative pool
    /// thread, causing "Call must be made on main thread" crashes.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        print("[NotificationDelegate] didReceive notification: \(response.notification.request.identifier)")

        // ObjC completion handler — inherently thread-safe one-shot callback,
        // but not marked @Sendable. Safe to send to main queue.
        nonisolated(unsafe) let finish = completionHandler

        // Handle notification actions (archive, mark read, delete) from NSE notifications
        let actionId = response.actionIdentifier

        // MARK_READ wires through AccountManager.markRead so the local
        // MessageHeader.isRead + folder.unreadCount flip optimistically, the
        // optimistic overlay registers, sibling rfc822 rows expand, the
        // delivered notification clears, and drainPendingQueue auto-kicks.
        // Direct PendingOperation INSERT bypasses all of that and leaves the
        // local row stale for up to 30s past drain (recentlyCompleted guard).
        if actionId == "MARK_READ" {
            guard let messageId = userInfo["messageId"] as? String,
                  let accountId = userInfo["accountId"] as? String else {
                finish()
                return
            }
            Task { @MainActor in
                // Notification actions run the app in the BACKGROUND (no
                // .foreground option) — databases may still be suspended from
                // the last quiesce (ADR-IOS-041). Resume or the user's action
                // write would abort: NEVER DROP USER INTENTION.
                DatabaseSuspension.shared.beginBackgroundWork("notification-action")
                defer { DatabaseSuspension.shared.endBackgroundWork("notification-action") }
                // A notification action can fire during the one-time migration
                // window; wait for the DB before touching it (AppStartup).
                await AppStartup.shared.awaitLaunchReady(background: true)
                let header: MessageHeader?
                do {
                    header = try await AppDatabase.dbPool.read { db -> MessageHeader? in
                        try MessageHeader.fetchOne(db, sql: """
                            SELECT * FROM messageHeader
                            WHERE messageId = ? AND accountId = ? AND folderId != ''
                            LIMIT 1
                            """, arguments: [messageId, accountId])
                    }
                } catch {
                    print("[NotificationDelegate] markRead lookup failed: \(error)")
                    header = nil
                }
                if let header {
                    await AccountManager.shared.markRead([header])
                    print("[NotificationDelegate] markRead via manager for \(messageId)")
                } else {
                    // Fallback: header not local yet (push arrived but sync hasn't landed).
                    // Queue raw PendingOperation; sync reconciles local state when message arrives.
                    do {
                        try await AppDatabase.dbPool.write { db in
                            let messageIdsJSON = (try? JSONSerialization.data(withJSONObject: [messageId]))
                                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                            try db.execute(sql: """
                                INSERT INTO pendingOperation (id, type, messageIds, accountId, status, retryCount)
                                VALUES (?, ?, ?, ?, 'queued', 0)
                                """, arguments: [UUID().uuidString, "markRead", messageIdsJSON, accountId])
                        }
                        print("[NotificationDelegate] markRead header not local — queued PendingOperation for \(messageId)")
                    } catch {
                        print("[NotificationDelegate] markRead fallback insert failed: \(error)")
                    }
                }
                finish()
            }
            return
        }

        if actionId == "ARCHIVE" || actionId == "DELETE" {
            if let messageId = userInfo["messageId"] as? String,
               let accountId = userInfo["accountId"] as? String {
                // Queue PendingOperation — drain loop processes on next sync (ADR-IOS-018)
                Task { @MainActor in
                    // Background notification action — same resume rationale as
                    // MARK_READ above (ADR-IOS-041).
                    DatabaseSuspension.shared.beginBackgroundWork("notification-action")
                    defer { DatabaseSuspension.shared.endBackgroundWork("notification-action") }
                    // Can fire during the one-time migration window — wait for
                    // the DB before touching it (AppStartup).
                    await AppStartup.shared.awaitLaunchReady(background: true)
                    do {
                        // Async context (awaitLaunchReady above) → GRDB async write overload.
                        try await AppDatabase.dbPool.write { db in
                            let opType: String
                            switch actionId {
                            case "ARCHIVE": opType = "archive"
                            case "DELETE": opType = "delete"
                            default: return
                            }
                            let messageIdsJSON = (try? JSONSerialization.data(withJSONObject: [messageId]))
                                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                            try db.execute(sql: """
                                INSERT INTO pendingOperation (id, type, messageIds, accountId, status, retryCount)
                                VALUES (?, ?, ?, ?, 'queued', 0)
                                """, arguments: [UUID().uuidString, opType, messageIdsJSON, accountId])
                        }
                        print("[NotificationDelegate] Queued \(actionId) for \(messageId)")
                    } catch {
                        print("[NotificationDelegate] Failed to queue action: \(error)")
                    }
                    finish()
                }
            } else {
                finish()
            }
            return
        }

        // Handle consent-error notification tap — posted by the push worker
        // when server-side inbox-add classification fails (refresh revoked,
        // Gmail 401/404/5xx). Route through the same Notification so any
        // active banner UI can also drive the re-consent flow.
        if let provider = userInfo["provider"] as? String, provider == "consent_error" {
            let email = userInfo["accountEmail"] as? String
            let emails: [String] = email.map { [$0] } ?? []
            // Stash for cold-start: when the tap launches the app, the view
            // hierarchy hasn't mounted yet, so an immediate Notification
            // post is lost. MailNavigationView drains this on .onAppear.
            PendingConsentErrorStore.store(emails)
            DispatchQueue.main.async {
                // Also post for the already-running case — live subscribers
                // see the update immediately; cold-start consumers pick up
                // the stashed list on first appear.
                NotificationCenter.default.post(
                    name: .pushConsentErrorsDetected,
                    object: nil,
                    userInfo: ["emails": emails]
                )
                finish()
            }
            return
        }

        // Handle NSE notification tap — deep link to message
        if let messageId = userInfo["messageId"] as? String,
           userInfo["provider"] != nil {  // NSE notification (has provider field)
            PendingDeepLinkStore.store(.message(id: messageId))
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .proactiveNotificationTapped,
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
                finish()
            }
            return
        }

        if let hash = userInfo["hash"] as? String {
            ReachedOutStore.markNotified(hash: hash)

            let messageId = userInfo["messageId"] as? String
            let source = userInfo["source"] as? String
            let taskHash = userInfo["sessionId"] as? String
            let deepLink: PendingDeepLink
            if source == "task", let taskHash {
                deepLink = .taskResult(taskHash: taskHash)
            } else if let messageId, !messageId.isEmpty, source == "message" {
                deepLink = .message(id: messageId)
            } else {
                deepLink = .inbox
            }

            // Store for cold-start consumption (view may not be mounted yet)
            PendingDeepLinkStore.store(deepLink)

            DispatchQueue.main.async {
                switch deepLink {
                case .message(let id):
                    NotificationCenter.default.post(
                        name: .proactiveNotificationTapped,
                        object: nil,
                        userInfo: ["messageId": id]
                    )
                case .taskResult(let taskHash):
                    NotificationCenter.default.post(
                        name: .proactiveNotificationTapped,
                        object: nil,
                        userInfo: ["taskHash": taskHash, "expandChat": true]
                    )
                case .inbox:
                    NotificationCenter.default.post(
                        name: .proactiveNotificationTapped,
                        object: nil,
                        userInfo: ["expandChat": true]
                    )
                }
                finish()
            }
        } else {
            finish()
        }
    }
}

/// UIApplicationDelegate for remote notification callbacks.
/// Required because SwiftUI's @main App struct cannot directly receive
/// APNs device tokens or silent push notifications.
class AppDelegate: NSObject, UIApplicationDelegate {

    /// Retained so the delegate isn't deallocated.
    private let notificationDelegate = NotificationDelegate()

    /// Per-screen orientation lock. Defaults to `.all` so the rest of the
    /// app behaves as it always has. Consent screens push `.portrait` on
    /// `onAppear` (via `.lockOrientation(.portrait)`) and reset to `.all`
    /// on `onDisappear`. Reads happen on the main thread from
    /// `application(_:supportedInterfaceOrientationsFor:)`, so no lock
    /// is needed.
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BootProfiler.mark("AppDelegate.didFinishLaunching enter")
        // CRITICAL: Migrate keychain to shared access group FIRST — before anything
        // reads tokens. All keychain queries now include kSecAttrAccessGroup, so old
        // items (without access group) are invisible until migrated. If this runs
        // after a session read, the app thinks the user is logged out.
        KeychainHelper.migrateAccessibility()

        UNUserNotificationCenter.current().delegate = notificationDelegate
        registerNotificationCategories()
        // 0xdead10cc defense: suspend GRDB databases just before process
        // suspension, resume on foreground/push/BGTask (ADR-IOS-041).
        DatabaseSuspension.shared.start()
        // Build the database OFF the synchronous launch path, on EVERY launch
        // type. `didFinishLaunching` always runs — including cold BACKGROUND
        // launches (silent push / BGTask / notification action) where the
        // SwiftUI `WindowGroup` body (and its `.task`, the foreground trigger)
        // never fires. Without this, those background handlers would touch a nil
        // `AppDatabase.shared` (force-unwrapped in `dbPool`) → crash/hang.
        // Async so it doesn't refreeze launch (RC2 fix, PLAN_HANG_FIX); it's
        // idempotent with `body.task`'s `runIfNeeded`. NSE staging DB creation +
        // state mirror live inside `ensureDatabaseReady` (they touch AppDatabase),
        // so they still run on every launch as they did before the splash work.
        Task { await AppStartup.shared.ensureDatabaseReady() }
        migrateOptOutFlagToSharedSuite()
        BootProfiler.mark("AppDelegate.didFinishLaunching exit (DB build kicked async)")
        return true
    }

    /// One-time migration: copy the AI privacy opt-out flag from the main
    /// app's `UserDefaults.standard` (where it used to live) into the shared
    /// App Group suite (where it now lives so the NSE can read it). Idempotent:
    /// if the shared suite already has the key, we assume it's authoritative
    /// and leave it alone. Without this, an existing opt-out user whose flag
    /// lived only in `.standard` would silently re-enable AI on first launch
    /// of this version.
    private func migrateOptOutFlagToSharedSuite() {
        let key = AIService.optOutAllAIKey
        let shared = AIService.optOutStore
        guard shared.object(forKey: key) == nil else { return }
        if let legacy = UserDefaults.standard.object(forKey: key) as? Bool {
            shared.set(legacy, forKey: key)
            print("[AppDelegate] Migrated opt-out flag to shared suite: \(legacy)")
        }
    }

    private func registerNotificationCategories() {
        let archiveAction = UNNotificationAction(
            identifier: "ARCHIVE", title: "Archive", options: [.destructive])
        let readAction = UNNotificationAction(
            identifier: "MARK_READ", title: "Mark Read")
        let deleteAction = UNNotificationAction(
            identifier: "DELETE", title: "Delete", options: [.destructive])
        let emailCategory = UNNotificationCategory(
            identifier: "EMAIL",
            actions: [archiveAction, readAction, deleteAction],
            intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([emailCategory])
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushNotificationService.shared.didReceiveDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationService.shared.didFailToRegisterForRemoteNotifications(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // Databases may be suspended from a previous quiesce (ADR-IOS-041) —
        // resume for the duration of the push handling, then re-arm the
        // quiesce window if we're still backgrounded when done.
        DatabaseSuspension.shared.beginBackgroundWork("silent-push")
        defer { DatabaseSuspension.shared.endBackgroundWork("silent-push") }
        // A silent push can arrive during the one-time migration window; wait
        // for the DB to finish building before any handler touches it
        // (AppDatabase.dbPool force-unwraps AppDatabase.shared). See AppStartup.
        await AppStartup.shared.awaitLaunchReady(background: true)

        let appState = application.applicationState
        let stateStr = appState == .active ? "active" : appState == .background ? "background" : "inactive"
        // Copy to Sendable dict — [AnyHashable: Any] is not Sendable across isolation
        let info: [String: String] = [
            "provider": userInfo["provider"] as? String ?? "",
            "accountEmail": userInfo["accountEmail"] as? String ?? ""
        ]
        BackgroundSyncLogger.log("didReceiveRemoteNotification: provider=\(info["provider"] ?? "?") email=\(info["accountEmail"] ?? "?") appState=\(stateStr)")

        // Opportunistic delivered-notification cleanup.
        Task { await NotificationCleanupService.sweepExpired() }

        // Mirror NSE: stamp PushHealthStore for non-error pushes so any stale
        // imap_reconnect warning notifications for this account get released
        // by the next sweep.
        let nonHealthProviders: Set<String> = ["imap_reconnect", "consent_error"]
        let provider = info["provider"] ?? ""
        let accountEmail = info["accountEmail"] ?? ""
        if !nonHealthProviders.contains(provider), !accountEmail.isEmpty {
            PushHealthStore.recordPush(accountEmail: accountEmail)
        }

        return await PushNotificationService.shared.handleSilentPush(provider: info["provider"], accountEmail: info["accountEmail"])
    }
}

extension Notification.Name {
    static let proactiveNotificationTapped = Notification.Name("proactiveNotificationTapped")
}
