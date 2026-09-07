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
    /// `id` is the PROVIDER message id (Gmail id / Graph id / IMAP UID) from the
    /// push payload. `accountId` is the local `Account.id` the NSE stamped into
    /// the notification (`EmailNotificationBuilder`), carried so the tap resolve
    /// can disambiguate a provider id that collides across accounts (IMAP UIDs).
    case message(id: String, accountId: String?)
    case inbox
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

/// Routes notification action-button taps (ARCHIVE, DELETE, MARK_READ) from
/// `NotificationDelegate.didReceive` to the REAL production action paths.
/// Extracted into a pure, testable, nonisolated helper — no raw SQL, no
/// direct `pendingOperation` INSERTs.
///
/// Lookup order mirrors `InboxViewModel.lookupMessage` / `AccountManager.
/// resolveHeaderForAction` (ADR-IOS-049): durable GRDB row first — scoped to
/// `isInInbox = 1`, because IMAP UIDs are folder-scoped (`MessageIdentity
/// .headerId` embeds `folderPath` for exactly this reason). An unscoped
/// lookup could match an unrelated message that happens to share the same
/// UID in another folder; notification actions are inbox-arrival semantics
/// (the push this notification came from landed FOR the inbox), so the
/// durable lookup is restricted to the inbox row. Then the staged-row
/// synthesis for a push that landed but hasn't merged yet. If BOTH miss (the
/// NSE staged the row to the on-disk staging table but nothing has drained it
/// into GRDB yet — a cold-launch gap, not the "message not local yet" cold
/// fallback below), one `NSEMergeCoordinator.shared.merge()` pass — the same
/// call `AccountManager.ensureDurable` uses — is run and the durable lookup
/// is retried before giving up.
///
/// When a header resolves, MARK_READ dispatches via `AccountManager
/// .markRead` (the batch API deliberately lives outside the ADR-IOS-057
/// intent register — see that ADR). ARCHIVE/DELETE dispatch via
/// `AccountManager.performCoordinatedRoleMove` — the same overlay + FIFO +
/// fresh-re-resolve path agent tools use (`EmailArchiveTool`/
/// `EmailDeleteTool`) — instead of calling `archive`/`delete` directly, so a
/// notification tap gets the same role-folder resolution, optimistic local
/// write, and F6 tag clear as gesture actions, plus the staleness guard of
/// re-resolving the header inside the queued write.
///
/// Only when NO header is resolvable anywhere — even after the merge retry —
/// does this fall back to directly queuing a `PendingOperation` — via the
/// RECORD TYPE (never raw SQL) — so the drain reconciles once the message
/// syncs. MARK_READ queues `.markRead` against the account's inbox-role
/// folder; ARCHIVE/DELETE queue `.move` with `destinationPath` set to the
/// account's archive-/trash-role folder (`.archive`/`.delete` are legacy
/// no-op `OperationType`s in the drain — see `AccountManagerQueue
/// .executeOperation` — so the cold path must never queue those). That
/// queued `.move` carries a raw numeric UID plus the source folder's admitted
/// UIDVALIDITY. The drain applies it only while that epoch still matches; an
/// absent or changed epoch fails closed and sync reconciles the local state.
///
/// A THROWN durable read is uncertainty, never proof of absence. The lookup is
/// three-state (`.found` / `.absent` / `.readFailed`): a read that threw never
/// dispatches a mutation (the message it could not read may contradict what the
/// staged cache shows), and it never claims the clean-miss path either. It
/// preserves the user's intention durably — the never-drop contract — scoped to
/// the exact folder the message was observed in when that evidence exists,
/// instead of addressing a bare UID against the canonical inbox where the same
/// UID may belong to a different message.
enum NotificationActionRouter {
    #if DEBUG
    private struct DurableLookupFault: Sendable {
        var remaining = 0
        var attempts = 0
    }

    private static let durableLookupFaultForTesting = Mutex(DurableLookupFault())

    /// Test seam: make the next `count` durable lookups throw, so the
    /// thrown-read path is reachable without corrupting a real database.
    /// Absence (the default, `remaining == 0`) injects nothing — the seam's
    /// unset state is exactly production behavior.
    static func armDurableLookupFailuresForTesting(_ count: Int) {
        durableLookupFaultForTesting.withLock {
            $0.remaining = max(0, count)
            $0.attempts = 0
        }
    }

    static var durableLookupAttemptsForTesting: Int {
        durableLookupFaultForTesting.withLock { $0.attempts }
    }

    private static func consumeDurableLookupFailureForTesting() -> Bool {
        durableLookupFaultForTesting.withLock {
            $0.attempts += 1
            guard $0.remaining > 0 else { return false }
            $0.remaining -= 1
            return true
        }
    }
    #endif

    /// Three-state local lookup result. `.readFailed` is NOT `.absent`: the
    /// database could not answer, so neither dispatch nor the clean-miss cold
    /// path is authorized. `stagedHeader` carries the row observed in the
    /// in-memory staging cache during the failed attempt — evidence of the
    /// message's source folder only, never a dispatch target.
    private enum HeaderResolution {
        case found(MessageHeader)
        case absent
        case readFailed(stagedHeader: MessageHeader?)
    }

    /// Which folder a cold/retained `PendingOperation` is scoped to.
    private enum ColdSourceScope {
        case canonicalInbox
        case exactFolder(String)
    }

    private static func log(_ message: @autoclosure () -> String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print(message())
    }

    /// Durable lookup scoped to the account's inbox — see the enum doc for why.
    ///
    /// R16-F1 (ADR-IOS-061), the FOLDER-NATIVE guard: address ≠ identity. An
    /// `(messageId, accountId, isInInbox)` match can be a DIFFERENT message that
    /// was optimistically moved INTO the inbox. `AccountManager
    /// .optimisticMoveToFolder` rewrites `folderId`/`folderPath`/`isInInbox` to
    /// the DESTINATION but deliberately keeps the SOURCE folder's primary key
    /// (`SyncEngine.canonicalizeLocalRows`'s doc states this outright, and notes
    /// the stale PK can survive indefinitely on stable-id
    /// providers). So such a row carries the source folder's UID while claiming
    /// inbox membership: at a coinciding UID it becomes the UNIQUE address match,
    /// and a durable archive/delete/mark-read would land on a message the user
    /// never tapped (C3).
    ///
    /// Every NSE-built notification's true target is FOLDER-NATIVE by
    /// construction — the NSE mints the row id as `MessageIdentity.headerId(
    /// accountId, inboxPath, uid)` — so requiring the row's own PK to be native
    /// to its CURRENT `(accountId, folderPath, messageId)` excludes moved-in
    /// impostors with zero false negatives. The predicate is expressed through
    /// `MessageIdentity.headerId` itself rather than re-concatenated in SQL, so
    /// there is exactly one definition of the key format to drift from.
    ///
    /// A rejection returns `.absent`, which is the existing clean-miss path: one
    /// merge + retry, then `queueColdPendingOperation(source: .canonicalInbox)`.
    /// The user's intention is retained, addressed at the mailbox the push was
    /// FOR — never dispatched against the impostor.
    private static func resolveDurableInboxHeader(messageId: String, accountId: String) async -> HeaderResolution {
        do {
            #if DEBUG
            if consumeDurableLookupFailureForTesting() {
                throw DatabaseError(
                    resultCode: .SQLITE_IOERR,
                    message: "injected notification durable-lookup failure"
                )
            }
            #endif
            return try await AppDatabase.dbPool.read { db -> HeaderResolution in
                // No LIMIT: the folder-native filter runs in Swift (single
                // source of truth for the key format), so an impostor must not
                // be able to occupy the one row a `LIMIT 1` would return.
                // Cardinality is bounded by the account's folder count —
                // `messageHeader_messageId_accountId` covers the predicate.
                let candidates = try MessageHeader.fetchAll(db, sql: """
                    SELECT * FROM messageHeader
                    WHERE messageId = ? AND accountId = ? AND folderId != '' AND isInInbox = 1
                    """, arguments: [messageId, accountId])
                let native = candidates.first { row in
                    row.id == MessageIdentity.headerId(
                        accountId: row.accountId,
                        folderPath: row.folderPath,
                        messageId: row.messageId
                    )
                }
                return native.map(HeaderResolution.found) ?? .absent
            }
        } catch {
            log("[NotificationActionRouter] header lookup failed: \(error)")
            return .readFailed(stagedHeader: nil)
        }
    }

    private static func resolveStagedInboxHeader(messageId: String, accountId: String) -> MessageHeader? {
        NSEDataBridge.latestStagedRows.withLock { rows in
            rows.first(where: { $0.messageId == messageId && $0.accountId == accountId })
        }?.toMessageHeader()
    }

    /// Durable tier first, staged tier only on a durable non-hit — the same
    /// precedence the dispatch has always used.
    private static func resolveLocalInboxHeader(messageId: String, accountId: String) async -> HeaderResolution {
        let durable = await resolveDurableInboxHeader(messageId: messageId, accountId: accountId)
        switch durable {
        case .found:
            return durable
        case .absent:
            return resolveStagedInboxHeader(messageId: messageId, accountId: accountId)
                .map(HeaderResolution.found) ?? .absent
        case .readFailed:
            // The durable read THREW. A staged row is real evidence of where
            // the message was observed, but it cannot rule out a contradicting
            // durable row the failed read would have returned, so it must not
            // become a dispatch target. Carry it as source evidence instead.
            return .readFailed(
                stagedHeader: resolveStagedInboxHeader(messageId: messageId, accountId: accountId)
            )
        }
    }

    private static func resolveAfterMerge(messageId: String, accountId: String) async -> HeaderResolution {
        let initial = await resolveLocalInboxHeader(messageId: messageId, accountId: accountId)
        switch initial {
        case .found:
            return initial
        case .absent:
            // Cold-launch gap: the NSE already staged this row to the on-disk
            // staging table (app-group), but nothing has drained it into GRDB
            // yet — only the in-memory staged-row cache is empty. Run the
            // SAME merge `ensureDurable` uses, then re-check. This is a
            // normal-path recovery, distinct from the "message not local at
            // all" cold fallback below.
            await NSEMergeCoordinator.shared.merge()
            return await resolveLocalInboxHeader(messageId: messageId, accountId: accountId)
        case .readFailed(let initialStagedHeader):
            // One real merge + retry: a transient failure (lock contention,
            // suspension, I/O) usually clears, and recovering the header is
            // strictly better than retaining a cold operation.
            await NSEMergeCoordinator.shared.merge()
            let retry = await resolveLocalInboxHeader(messageId: messageId, accountId: accountId)
            return reconcileRetryAfterReadFailure(
                initialStagedHeader: initialStagedHeader,
                retry: retry
            )
        }
    }

    /// A real NSE merge may replace the staged cache before the retry, so the
    /// initially observed staged row is kept as comparison/source evidence.
    /// v3 keys durable actions by the composite provider address, and that
    /// address embeds the folder and the (reusable) UID — so the only proof
    /// that the retry found the same message the failed read was asked about is
    /// address equality. A changed address still preserves the user's action,
    /// but only through cold admission scoped to the originally observed
    /// source; it must never dispatch against either row.
    private static func reconcileRetryAfterReadFailure(
        initialStagedHeader: MessageHeader?,
        retry: HeaderResolution
    ) -> HeaderResolution {
        switch retry {
        case .found(let header):
            guard let initialStagedHeader else { return .found(header) }
            return header.id == initialStagedHeader.id
                ? .found(header)
                : .readFailed(stagedHeader: initialStagedHeader)
        case .absent:
            // A healthy retry with no staged evidence is clean absence again —
            // restore the ordinary cold-miss path rather than letting a
            // superseded earlier throw keep the result uncertain forever. When
            // the merge replaced an initially observed staged row, retain that
            // source evidence instead of silently switching mailboxes.
            guard let initialStagedHeader else { return .absent }
            return .readFailed(stagedHeader: initialStagedHeader)
        case .readFailed(let retryStagedHeader):
            return .readFailed(stagedHeader: initialStagedHeader ?? retryStagedHeader)
        }
    }

    static func execute(actionId: String, messageId: String, accountId: String) async {
        switch await resolveAfterMerge(messageId: messageId, accountId: accountId) {
        case .found(let header):
            switch actionId {
            case "MARK_READ":
                await AccountManager.shared.markRead([header])
                log("[NotificationActionRouter] markRead via manager for \(messageId)")
            case "ARCHIVE":
                // T4.V8 (PORT of `v2final:NotificationActionRouter.execute`,
                // commit `b1c89ad4a`): this line used to log a success-shaped
                // string for an admission that may never have landed. Log the
                // three dispositions distinctly so a refused or rolled-back tap
                // is diagnosable from a device log instead of reading like a
                // completed archive.
                // C3 CONTENT WITNESS — the header resolved microseconds ago by
                // `resolveAfterMerge` above IS the producer's snapshot, so the
                // witness costs zero I/O here exactly as it does in
                // `EmailArchiveTool`/`EmailDeleteTool`. It is NOT vacuous: both
                // of the callee's `partition` passes run strictly later than
                // this capture — pass 1 after its own re-resolve, pass 2 after
                // the FIFO write queue has taken an unbounded amount of other
                // work — which is precisely the window a UIDVALIDITY turnover
                // can purge this row and re-seat a different message under the
                // same composite id. See the bound on the OTHER interval (push
                // delivery → this tap) in `KNOWN_ISSUES.md` `IOS-NOTIFY-001`.
                let archiveOutcome = await AccountManager.shared.performCoordinatedRoleMove(
                    ids: [header.id], role: .archive,
                    expectedIdentities: ExpectedMessageIdentity.map([header]))
                if archiveOutcome.admittedIds.contains(header.id) {
                    log("[NotificationActionRouter] archive durably admitted for \(messageId)")
                } else if archiveOutcome.pendingIds.contains(header.id) {
                    log("[NotificationActionRouter] archive outstanding (unconfirmed) for \(messageId)")
                } else {
                    log("[NotificationActionRouter] archive terminal-stale for \(messageId)")
                }
            case "DELETE":
                // C3 CONTENT WITNESS — same reasoning as the ARCHIVE arm above,
                // stated rather than cross-referenced because a sibling that
                // says "same as above" is how the first of these two lost its
                // guard in the port.
                let deleteOutcome = await AccountManager.shared.performCoordinatedRoleMove(
                    ids: [header.id], role: .trash,
                    expectedIdentities: ExpectedMessageIdentity.map([header]))
                if deleteOutcome.admittedIds.contains(header.id) {
                    log("[NotificationActionRouter] delete durably admitted for \(messageId)")
                } else if deleteOutcome.pendingIds.contains(header.id) {
                    log("[NotificationActionRouter] delete outstanding (unconfirmed) for \(messageId)")
                } else {
                    log("[NotificationActionRouter] delete terminal-stale for \(messageId)")
                }
            default:
                break
            }
        case .absent:
            // No header anywhere — even after the merge retry above (header not
            // local yet — push arrived but sync hasn't landed). Queue a
            // correctly-shaped PendingOperation so sync reconciles local state
            // when the message arrives. See the enum doc for the epoch guard.
            await queueColdPendingOperation(
                actionId: actionId, messageId: messageId, accountId: accountId, source: .canonicalInbox
            )
        case .readFailed(let stagedHeader):
            // A database read failure is uncertainty, never proof of absence:
            // dispatching is unsafe, but dropping the tap would violate
            // never-drop-user-intention. Retain it durably, scoped to the exact
            // folder the message was observed in when that evidence exists —
            // addressing a bare UID against the canonical inbox is precisely
            // how an op lands on a different message at the same UID.
            let observedPath = stagedHeader?.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: ColdSourceScope
            if let observedPath, !observedPath.isEmpty {
                source = .exactFolder(observedPath)
            } else {
                source = .canonicalInbox
            }
            log("[NotificationActionRouter] durable lookup unresolved (read failure) — retaining \(actionId) for \(messageId)")
            await queueColdPendingOperation(
                actionId: actionId, messageId: messageId, accountId: accountId, source: source
            )
        }
    }

    /// Durable fallback and retention path: no durable OR staged header could
    /// be dispatched for this message. Builds a `PendingOperation` via the
    /// record type against the requested source and the account's role folders
    /// — never raw SQL. `source` is `.canonicalInbox` for a clean cold miss and
    /// `.exactFolder` when a thrown read left a byte-exact observed source: the
    /// operation carries a bare UID, so it must address the mailbox the UID was
    /// actually observed in.
    private static func queueColdPendingOperation(
        actionId: String,
        messageId: String,
        accountId: String,
        source: ColdSourceScope
    ) async {
        do {
            let folders = try await AppDatabase.dbPool.read { db in
                try Folder.filter(Column("accountId") == accountId).fetchAll(db)
            }
            let sourcePath: String?
            switch source {
            case .canonicalInbox:
                sourcePath = folders.first(where: { $0.role == .inbox })?.path
            case .exactFolder(let path):
                sourcePath = path
            }
            guard let inboxPath = sourcePath, !inboxPath.isEmpty else {
                log("[NotificationActionRouter] no inbox folder for account \(accountId) — cannot queue \(actionId) for \(messageId)")
                return
            }
            switch actionId {
            case "MARK_READ":
                // Report the ADMISSION RESULT, not the mere absence of a throw — a
                // refusal queues nothing, and logging "queued" for it sends anyone
                // debugging a vanished action looking in the drain instead of here.
                let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                    // T1.3 — a notification-action tap is a new user gesture. No local
                    // header exists on this cold path, so `messageIds` is a bare UID:
                    // exactly the shape an unknown epoch can misresolve.
                    guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                        accountId: accountId, folderPath: inboxPath, db: db) else { return false }
                    // 🚨 RECORD THE EPOCH THE GUARD ABOVE JUST PROVED (audit A-1).
                    // Read in THIS transaction so the stamp and the row observe one
                    // consistent epoch. Omitting it made the insert self-refuting:
                    // admission proved the folder's epoch was known and then wrote a
                    // bare-UID op without it, which the drain's checkpoint A deleted
                    // — so an ARCHIVE/DELETE/MARK_READ tapped on a push banner for a
                    // not-yet-synced IMAP/iCloud message did nothing, silently.
                    var markReadOp = try PendingOperation(
                        type: .markRead, messageIds: [messageId], accountId: accountId,
                        folderPath: inboxPath,
                        observedUidValidity: AccountManager.admissionEpochForNewGesture(
                            accountId: accountId, folderPath: inboxPath, db: db))
                    try markReadOp.insert(db)
                    return true
                }
                log("[NotificationActionRouter] header not local — \(admitted ? "queued" : "REFUSED (unknown folder epoch)") markRead PendingOperation for \(messageId)")
            case "ARCHIVE", "DELETE":
                let role: FolderRole = actionId == "ARCHIVE" ? .archive : .trash
                guard let destinationPath = folders.first(where: { $0.role == role })?.path else {
                    log("[NotificationActionRouter] no \(role.rawValue) folder for account \(accountId) — cannot queue \(actionId) for \(messageId)")
                    return
                }
                let admitted = try await AppDatabase.dbPool.write { db -> Bool in
                    // T1.3 — see the MARK_READ arm above. Source-scoped.
                    guard try !AccountManager.newGestureRefusedForUnknownEpoch(
                        accountId: accountId, folderPath: inboxPath, db: db) else { return false }
                    // Record the proven epoch — see the MARK_READ arm (audit A-1).
                    var moveOp = try PendingOperation(
                        type: .move, messageIds: [messageId], accountId: accountId,
                        folderPath: inboxPath, destinationPath: destinationPath,
                        observedUidValidity: AccountManager.admissionEpochForNewGesture(
                            accountId: accountId, folderPath: inboxPath, db: db))
                    try moveOp.insert(db)
                    return true
                }
                log("[NotificationActionRouter] header not local — \(admitted ? "queued" : "REFUSED (unknown folder epoch)") \(actionId) (.move) PendingOperation for \(messageId)")
            default:
                break
            }
        } catch {
            log("[NotificationActionRouter] cold PendingOperation queue failed for \(actionId)/\(messageId): \(error)")
        }
    }
}

/// Separate delegate for UNUserNotificationCenter — must NOT be @MainActor
/// because the delegate methods are called on arbitrary threads by iOS.
/// AppDelegate is implicitly @MainActor (via UIApplicationDelegate), so
/// conforming to UNUserNotificationCenterDelegate on AppDelegate causes
/// Swift 6 isolation errors.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    #if DEBUG
    private let readinessHook: (@MainActor @Sendable () async -> Bool)?
    private let actionHook: (@MainActor @Sendable (String, String, String) async -> Void)?

    override init() {
        readinessHook = nil
        actionHook = nil
        super.init()
    }

    init(
        readiness: @escaping @MainActor @Sendable () async -> Bool,
        action: @escaping @MainActor @Sendable (String, String, String) async -> Void
    ) {
        readinessHook = readiness
        actionHook = action
        super.init()
    }
    #endif

    /// Handle notification while app is in foreground.
    /// For NSE pushes (email/task): suppress and trigger immediate sync.
    /// For other notifications (proactive, local): show normally.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let provider = userInfo["provider"] as? String
        if DebugModeManager.isLoggingEnabled() {
            print("[NotificationDelegate] willPresent notification: \(notification.request.identifier) provider=\(provider ?? "nil")")
        }

        // NSE email pushes: suppress in foreground, trigger sync instead.
        // Fan-out chain stops naturally — app's sync discovers all new messages.
        if let provider, ["gmail", "outlook", "imap_new_mail"].contains(provider) {
            Task { @MainActor in
                // A push can arrive during the one-time migration window; wait
                // for the DB before touching it (AppStartup / PLAN_HANG_FIX).
                guard await AppStartup.shared.awaitLaunchReady(background: true) else { return }
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

    /// Build the deep-link forwarding for an NSE new-mail notification TAP. Pure
    /// + testable (the inline version dropped `accountId`, so the wrong-account
    /// resolve + the staging-direct tier were dead on the real tap path).
    ///
    /// The DELIVERED notification's userInfo carries the local `Account.id`
    /// (`EmailNotificationBuilder.fill` sets `info["accountId"] = accountId`); the
    /// `.proactiveNotificationTapped` repost and the cold-start `PendingDeepLink`
    /// MUST forward it so `handleNotificationDeepLink` can account-scope the
    /// resolve. Returns nil when this isn't an NSE message tap (no messageId /
    /// no `provider` marker). Legacy payloads without `accountId` → nil accountId
    /// (messageId-only resolve, unchanged behavior).
    /// Returns the cold-start `link` plus the Sendable primitives the warm-path
    /// repost needs. NOTE: returns primitives (not a built `[AnyHashable: Any]`)
    /// so the `DispatchQueue.main.async` repost can build the userInfo INSIDE the
    /// closure — a non-Sendable `[AnyHashable: Any]` captured across the hop is a
    /// Swift-6 `sending` data-race error.
    static func nseMessageDeepLink(
        from userInfo: [AnyHashable: Any]
    ) -> (link: PendingDeepLink, messageId: String, accountId: String?)? {
        guard let messageId = userInfo["messageId"] as? String, !messageId.isEmpty,
              userInfo["provider"] != nil else { return nil }
        let accountId = userInfo["accountId"] as? String
        return (.message(id: messageId, accountId: accountId), messageId, accountId)
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
        if DebugModeManager.isLoggingEnabled() {
            print("[NotificationDelegate] didReceive notification: \(response.notification.request.identifier)")
        }

        handleNotificationResponse(
            actionId: response.actionIdentifier,
            userInfo: userInfo,
            completionHandler: completionHandler
        )
    }

    func handleNotificationResponse(
        actionId: String,
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        // ObjC completion handler — inherently thread-safe one-shot callback,
        // but not marked @Sendable. Safe to send to main queue.
        nonisolated(unsafe) let finish = completionHandler

        #if DEBUG
        // Capture immutable Sendable operations, never the nonisolated delegate.
        let ready: @MainActor @Sendable () async -> Bool = readinessHook ?? {
            await AppStartup.shared.awaitLaunchReady(background: true)
        }
        let execute: @MainActor @Sendable (String, String, String) async -> Void = actionHook ?? {
            await NotificationActionRouter.execute(actionId: $0, messageId: $1, accountId: $2)
        }
        #endif

        // Handle notification actions (archive, mark read, delete) from NSE notifications

        // MARK_READ wires through AccountManager.markRead so the local
        // MessageHeader.isRead + folder.unreadCount flip optimistically, the
        // optimistic overlay registers, the addressed row is ADMITTED (or
        // refused) by `admittedOrdinaryActionTargets`, the delivered
        // notification clears, and drainPendingQueue auto-kicks.
        // Direct PendingOperation INSERT bypasses all of that and leaves the
        // local row stale for up to 30s past drain (recentlyCompleted guard).
        //
        // ⚠️ THIS SAID "sibling rfc822 rows expand" UNTIL 2026-08-06. That
        // behaviour is GONE — `AccountManager.expandWithSiblingsByRfc822`
        // survives only as a removal note in `SyncEngineEpochVerify` — and the
        // sentence was worse than merely stale: it advertised the remedy
        // ADR-IOS-068/D4 PROHIBITS (selecting mutation targets by RFC 822
        // Message-ID), so a reader repairing this path would have reached for
        // it. `IOS-IMAP-011` owns the removal. What runs today does the
        // OPPOSITE of expanding: `admittedOrdinaryActionTargets` NARROWS the
        // gesture to the rows whose address it can prove — on IMAP, a folder
        // with no pending epoch reset, a live `lastKnownUidValidity`, and per
        // row `observedUidValidity == liveEpoch` with a `messageId` that is
        // exactly its own UID — dropping the unproven members and returning nil
        // if none survive, so the op carries one coherent epoch. Non-IMAP
        // providers admit any non-empty stable id and record no epoch.
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
                defer {
                    finish()
                    DatabaseSuspension.shared.endBackgroundWork("notification-action")
                }
                // A notification action can fire during the one-time migration
                // window; wait for the DB before touching it (AppStartup).
                #if DEBUG
                guard await ready() else { return }
                await execute(actionId, messageId, accountId)
                #else
                guard await AppStartup.shared.awaitLaunchReady(background: true) else { return }
                await NotificationActionRouter.execute(actionId: actionId, messageId: messageId, accountId: accountId)
                #endif
            }
            return
        }

        if actionId == "ARCHIVE" || actionId == "DELETE" {
            guard let messageId = userInfo["messageId"] as? String,
                  let accountId = userInfo["accountId"] as? String else {
                finish()
                return
            }
            Task { @MainActor in
                // Background notification action — same resume rationale as
                // MARK_READ above (ADR-IOS-041).
                DatabaseSuspension.shared.beginBackgroundWork("notification-action")
                defer {
                    finish()
                    DatabaseSuspension.shared.endBackgroundWork("notification-action")
                }
                // Can fire during the one-time migration window — wait for
                // the DB before touching it (AppStartup).
                #if DEBUG
                guard await ready() else { return }
                await execute(actionId, messageId, accountId)
                #else
                guard await AppStartup.shared.awaitLaunchReady(background: true) else { return }
                await NotificationActionRouter.execute(actionId: actionId, messageId: messageId, accountId: accountId)
                #endif
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
        if let (link, messageId, accountId) = Self.nseMessageDeepLink(from: userInfo) {
            PendingDeepLinkStore.store(link)
            DispatchQueue.main.async {
                // Build the userInfo INSIDE the closure — a captured
                // `[AnyHashable: Any]` is non-Sendable (Swift-6 `sending` error).
                var post: [AnyHashable: Any] = ["messageId": messageId]
                if let accountId { post["accountId"] = accountId }
                NotificationCenter.default.post(
                    name: .proactiveNotificationTapped,
                    object: nil,
                    userInfo: post
                )
                finish()
            }
            return
        }

        if let hash = userInfo["hash"] as? String {
            ReachedOutStore.markNotified(hash: hash)

            let messageId = userInfo["messageId"] as? String
            let source = userInfo["source"] as? String
            let reminderAccountId = userInfo["accountId"] as? String
            let deepLink: PendingDeepLink
            if let messageId, !messageId.isEmpty, source == "message" {
                deepLink = .message(id: messageId, accountId: reminderAccountId)
            } else {
                deepLink = .inbox
            }

            // Store for cold-start consumption (view may not be mounted yet)
            PendingDeepLinkStore.store(deepLink)

            DispatchQueue.main.async {
                switch deepLink {
                case .message(let id, let accountId):
                    var info: [AnyHashable: Any] = ["messageId": id]
                    if let accountId { info["accountId"] = accountId }
                    NotificationCenter.default.post(
                        name: .proactiveNotificationTapped,
                        object: nil,
                        userInfo: info
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

    #if DEBUG
    private var silentPushReadinessHook: (@MainActor () async -> Bool)?
    private var silentPushWorkHook: (@MainActor () async -> UIBackgroundFetchResult)?

    override init() { super.init() }

    init(
        silentPushReadiness: @escaping @MainActor () async -> Bool,
        silentPushWork: @escaping @MainActor () async -> UIBackgroundFetchResult
    ) {
        silentPushReadinessHook = silentPushReadiness
        silentPushWorkHook = silentPushWork
        super.init()
    }
    #endif

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
        // synchronous=NORMAL durability valve: fsync the WAL just before the app suspends,
        // so committed user intent (PendingOperation / OutboxMessage) survives an unclean
        // power-off while backgrounded (NORMAL doesn't fsync per commit). `beginBackgroundWork`
        // keeps the DB resumed + defers the quiesce until the checkpoint finishes; the
        // UIBackgroundTask assertion asks iOS for the brief time to run it. Best-effort.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard AppStartup.shared.dbReady else { return }
                // Idempotent finish: the normal-completion path (end of the
                // Task below) and the expiration handler both funnel through
                // this one closure, so `endBackgroundWork` (a refcount) is
                // NEVER decremented twice for one `beginBackgroundWork`, and
                // the OS task assertion is released exactly once. Mirrors
                // SyncScheduler.requestBackgroundGracePeriod's `ended`/
                // `bgTaskId` Mutex idiom.
                let ended = Mutex(false)
                let bgTaskId = Mutex<UIBackgroundTaskIdentifier>(.invalid)
                let finish: @MainActor @Sendable () -> Void = {
                    guard !ended.withLock({ let was = $0; $0 = true; return was }) else { return }
                    DatabaseSuspension.shared.endBackgroundWork("wal-durability-checkpoint")
                    let id = bgTaskId.withLock { $0 }
                    if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
                }
                let bgTask = UIApplication.shared.beginBackgroundTask(
                    withName: "wal-durability-checkpoint",
                    expirationHandler: finish
                )
                bgTaskId.withLock { $0 = bgTask }
                DatabaseSuspension.shared.beginBackgroundWork("wal-durability-checkpoint")
                Task { @MainActor in
                    // Drain the in-memory write queue BEFORE the durability
                    // checkpoint. The checkpoint fsyncs the WAL as of "now";
                    // closures still sitting in AccountManager.writeQueue —
                    // including queued ADR-IOS-057 intent-cycle executors —
                    // haven't committed yet, so checkpointing first could
                    // fsync a WAL that's missing whatever the queue hasn't
                    // flushed. Deadline-bounded (see
                    // SyncConfig.backgroundWriteQueueFlushTimeoutSeconds) so a
                    // pathological queue can't hold the background budget
                    // hostage — on timeout we proceed to the checkpoint
                    // anyway; the un-drained tail closures still run later
                    // (never dropped), they just miss this fsync window.
                    await AccountManager.awaitWriteQueueDrainOrTimeout(
                        timeoutSeconds: SyncConfig.backgroundWriteQueueFlushTimeoutSeconds
                    )
                    await AppDatabase.checkpointForDurability()
                    finish()
                }
            }
        }
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
        Task { _ = await AppStartup.shared.ensureDatabaseReady() }
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
            if DebugModeManager.isLoggingEnabled() {
                print("[AppDelegate] Migrated opt-out flag to shared suite: \(legacy)")
            }
        }
    }

    private func registerNotificationCategories() {
        let archiveAction = UNNotificationAction(
            identifier: "ARCHIVE", title: "Archive", options: [.destructive])
        let readAction = UNNotificationAction(
            identifier: "MARK_READ", title: "Mark Read")
        let deleteAction = UNNotificationAction(
            identifier: "DELETE", title: "Delete", options: [.destructive])
        // Suggested-action variants: the NSE stamps the category matching the
        // AI action tag (EmailNotificationBuilder.categoryIdentifier(forActionTag:)),
        // so the long-press sheet surfaces the suggestion first, labeled as
        // such. Action IDENTIFIERS are identical across all categories —
        // NotificationActionRouter needs no category awareness. Only
        // archive/delete tags get variants (reply has no notification action
        // yet; none/nil = no suggestion). A notification stamped with a
        // not-yet-registered category shows NO buttons — registration happens
        // here in didFinishLaunching, which also runs on background launches,
        // so the only exposure is an NSE delivery before the FIRST process
        // launch after the app update that introduced the new categories.
        let suggestedArchive = UNNotificationAction(
            identifier: "ARCHIVE", title: "Archive (Suggested)", options: [.destructive])
        let suggestedDelete = UNNotificationAction(
            identifier: "DELETE", title: "Delete (Suggested)", options: [.destructive])
        let emailCategory = UNNotificationCategory(
            identifier: "EMAIL",
            actions: [archiveAction, readAction, deleteAction],
            intentIdentifiers: [])
        let tagArchiveCategory = UNNotificationCategory(
            identifier: "EMAIL_TAG_ARCHIVE",
            actions: [suggestedArchive, readAction, deleteAction],
            intentIdentifiers: [])
        let tagDeleteCategory = UNNotificationCategory(
            identifier: "EMAIL_TAG_DELETE",
            actions: [suggestedDelete, readAction, archiveAction],
            intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories(
            [emailCategory, tagArchiveCategory, tagDeleteCategory])
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
        #if DEBUG
        let usable = if let silentPushReadinessHook {
            await silentPushReadinessHook()
        } else {
            await AppStartup.shared.awaitLaunchReady(background: true)
        }
        #else
        let usable = await AppStartup.shared.awaitLaunchReady(background: true)
        #endif
        guard usable else { return .failed }

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

        #if DEBUG
        if let silentPushWorkHook { return await silentPushWorkHook() }
        #endif
        return await PushNotificationService.shared.handleSilentPush(provider: info["provider"], accountEmail: info["accountEmail"])
    }
}

extension Notification.Name {
    static let proactiveNotificationTapped = Notification.Name("proactiveNotificationTapped")
}
