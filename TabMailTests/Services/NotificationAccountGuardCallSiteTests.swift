/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
import UserNotifications
@testable import TabMail

/// Pins the account-incarnation admission rule AT ITS CALL SITES, not just in
/// the policy function. Before these tests existed, all four guard call sites
/// could be deleted and the suite stayed green.
///
/// The invariants pinned here:
///
/// 1. **A user's action tap is NEVER discarded by the incarnation rule.**
///    MARK_READ / ARCHIVE / DELETE are durable intentions and iOS dismisses the
///    notification the instant the button is tapped, so a refusal on that path
///    would destroy the intention with no queue row, no error, and nothing left
///    on screen to retry from. `NotificationDelegate.tapRoute` must resolve the
///    action branch BEFORE consulting the rule.
/// 2. **Presentation and navigation ARE still gated**, in the foreground
///    (`willPresent`), on a plain tap (`didReceive`) and on a silent push
///    (`didReceiveRemoteNotification`) — and on the silent-push path the
///    refusal happens before the push-health stamp.
/// 3. **A refused push is stripped to an inert placeholder** by the shared
///    `neutralizeRefusedAccountPush`, and the marker it stamps is what makes the
///    main app refuse the same payload again if the user taps it.
///
/// `.serialized` + a swapped `AppDatabase.shared`: mirrors
/// `NotificationActionRouterTests`, whose harness this reuses.
@Suite("Notification account-incarnation guard — call sites", .serialized, .processGlobalState)
struct NotificationAccountGuardCallSiteTests {

    // MARK: - Harness

    /// A `UserDefaults` suite standing in for the App Group mirror, seeded with
    /// one account whose local row id is `acc1` — the same account id the
    /// database harness below inserts.
    private func makeAccountMirror(
        _ map: [String: String] = ["notify@example.com": "acc1"]
    ) throws -> (defaults: UserDefaults, name: String) {
        let name = "NotificationAccountGuardCallSiteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(
            String(data: try JSONEncoder().encode(map), encoding: .utf8),
            forKey: "nse.accountMap"
        )
        return (defaults, name)
    }

    /// Mirrors `NotificationActionRouterTests.makeTestDB` — the durable action
    /// path is the same production path, so the fixture must be too.
    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        // Same rationale as the router suite: the default-ON "mark as read on
        // archive & delete" setting composes an extra `.markRead` op ahead of
        // every move, and the op-count assertion below pins the MOVE itself.
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "notify@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    // MARK: - (1) The action path is never gated by the incarnation rule

    @Test("""
    a notification ARCHIVE tap whose payload the incarnation rule REFUSES still \
    reaches the durable queue: exactly one .move PendingOperation, source INBOX
    """)
    func refusedIncarnationActionTapStillProducesItsDurableOperation() async throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let durable: MessageHeader = {
            var h = MessageHeader(
                messageId: "m-refused-incarnation", subject: "Subj", from: "Sender",
                fromAddress: "sender@example.com", to: "notify@example.com", date: Date(),
                snippet: "snip", folderId: inbox.id, accountId: "acc1", folderPath: inbox.path,
                isInInbox: true
            )
            h.headerComplete = true
            return h
        }()
        try await pool.writeWithoutTransaction { db in try durable.insert(db) }
        let id = durable.id

        // The payload the rule REFUSES: a present incarnation that disagrees
        // with the mirrored account row.
        let userInfo: [AnyHashable: Any] = [
            "provider": "gmail",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "replaced-account",
            "messageId": "m-refused-incarnation",
            "accountId": "acc1",
        ]
        #expect(
            !NSEDataBridge.notificationAccountMatches(userInfo, defaults: defaults),
            "premise: this payload IS refused by the account-incarnation rule"
        )

        // Production's two steps, in production's order: route the tap, then run
        // the router. `handleNotificationResponse` cannot be driven directly here
        // because its action arm parks on `AppStartup.awaitLaunchReady`, which
        // would replace `AppDatabase.shared` with the real app database.
        let route = NotificationDelegate.tapRoute(
            actionId: "ARCHIVE",
            userInfo: userInfo,
            defaults: defaults
        )
        #expect(
            route == .durableAction(actionId: "ARCHIVE", messageId: "m-refused-incarnation", accountId: "acc1"),
            "NEVER DROP USER INTENTION: the action branch must resolve ahead of the incarnation rule"
        )
        guard case .durableAction(let actionId, let messageId, let accountId) = route else { return }
        await NotificationActionRouter.execute(actionId: actionId, messageId: messageId, accountId: accountId)

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "the tap must survive as durable intention")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == inbox.path)
        #expect(ops[0].destinationPath == archive.path)
        #expect(ops[0].messageIds == ["m-refused-incarnation"])

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id)
    }

    @Test("every action button routes durably regardless of what the incarnation rule says")
    func everyActionButtonRoutesDurablyUnderEveryIncarnationVerdict() throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        // Absent (what every deployed server actually sends), stale, and
        // matching — the durable route must be identical in all three.
        let payloads: [(label: String, incarnation: String?)] = [
            ("absent", nil),
            ("stale", "replaced-account"),
            ("matching", "acc1"),
        ]
        for actionId in ["MARK_READ", "ARCHIVE", "DELETE"] {
            for payload in payloads {
                var userInfo: [AnyHashable: Any] = [
                    "provider": "gmail",
                    "accountEmail": "notify@example.com",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc1",
                ]
                if let incarnation = payload.incarnation { userInfo["accountIncarnation"] = incarnation }
                #expect(
                    NotificationDelegate.tapRoute(actionId: actionId, userInfo: userInfo, defaults: defaults)
                        == .durableAction(actionId: actionId, messageId: "m-\(actionId)", accountId: "acc1"),
                    "\(actionId) with a \(payload.label) incarnation must still route durably"
                )
            }
        }

        // Non-vacuity: an action payload with no target is still refused — the
        // action branch is not an unconditional accept.
        #expect(
            NotificationDelegate.tapRoute(
                actionId: "ARCHIVE",
                userInfo: ["provider": "gmail", "accountEmail": "notify@example.com"],
                defaults: defaults
            ) == .incompleteAction
        )
    }

    // MARK: - (2) Presentation and navigation ARE still gated

    @Test("a plain tap on a replaced-account notification is refused before any navigation runs")
    func plainTapOnAReplacedAccountIsRefused() async throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        let refused: [AnyHashable: Any] = [
            "provider": "gmail",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "replaced-account",
            "messageId": "m-tap-refused",
            "accountId": "acc1",
        ]
        #expect(
            NotificationDelegate.tapRoute(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: refused,
                defaults: defaults
            ) == .refusedAccount
        )

        _ = PendingDeepLinkStore.consume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NotificationDelegate.handleNotificationResponse(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: refused,
                identifier: "refused-tap",
                defaults: defaults
            ) {
                continuation.resume()
            }
        }
        #expect(
            PendingDeepLinkStore.consume() == nil,
            "a refused tap must not stage a deep link into the replaced account"
        )

        // Non-vacuity: the SAME payload with a matching incarnation does stage
        // one, so the assertion above is measuring the guard and not a
        // structurally dead path.
        var admitted = refused
        admitted["accountIncarnation"] = "acc1"
        #expect(
            NotificationDelegate.tapRoute(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: admitted,
                defaults: defaults
            ) == .passthrough
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NotificationDelegate.handleNotificationResponse(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: admitted,
                identifier: "admitted-tap",
                defaults: defaults
            ) {
                continuation.resume()
            }
        }
        if case .message(let id, let accountId)? = PendingDeepLinkStore.consume() {
            #expect(id == "m-tap-refused")
            #expect(accountId == "acc1")
        } else {
            Issue.record("an admitted tap must stage the message deep link")
        }
    }

    @Test("willPresent refuses a replaced-account push in the foreground")
    func foregroundPresentationRefusesAReplacedAccountPush() async throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        // `imap_reconnect` is an account-scoped provider that is NOT in the
        // suppress-and-sync set, so a refusal ([]) is distinguishable from the
        // admitted outcome ([.banner, .sound, .list]). A `gmail` payload would
        // return [] either way and could not measure the guard at all.
        var payload: [AnyHashable: Any] = [
            "provider": "imap_reconnect",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "replaced-account",
        ]
        var options = await NotificationDelegate.foregroundPresentationOptions(
            for: payload,
            identifier: "refused-present",
            defaults: defaults
        )
        #expect(options == [], "a replaced-account push must not be presented")

        payload["accountIncarnation"] = "acc1"
        options = await NotificationDelegate.foregroundPresentationOptions(
            for: payload,
            identifier: "admitted-present",
            defaults: defaults
        )
        #expect(options == [.banner, .sound, .list], "the account's own push is presented normally")

        // The deployed-server reality: no incarnation at all is presented too.
        payload.removeValue(forKey: "accountIncarnation")
        options = await NotificationDelegate.foregroundPresentationOptions(
            for: payload,
            identifier: "absent-present",
            defaults: defaults
        )
        #expect(options == [.banner, .sound, .list])
    }

    @MainActor
    @Test("a refused silent push never reaches the push-health stamp")
    func silentPushRefusalPrecedesThePushHealthStamp() throws {
        // Lowercased: `mirrorAccountMap` writes lowercase keys in production
        // (worker routing is case-insensitive) and the policy looks up the
        // lowercased address, so a mixed-case key would never be found.
        let email = "silent-\(UUID().uuidString.lowercased())@example.com"
        let (defaults, name) = try makeAccountMirror([email: "acc-silent"])
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(
            PushHealthStore.lastNonReconnectPushAt(accountEmail: email) == nil,
            "premise: this account has no push-health record yet"
        )
        #expect(
            !AppDelegate.admitSilentPush(
                ["provider": "gmail", "accountEmail": email, "accountIncarnation": "replaced-account"],
                defaults: defaults
            )
        )
        #expect(
            PushHealthStore.lastNonReconnectPushAt(accountEmail: email) == nil,
            "the refusal must run BEFORE the push-health stamp, or a replaced account keeps its health alive"
        )

        #expect(
            AppDelegate.admitSilentPush(
                ["provider": "gmail", "accountEmail": email, "accountIncarnation": "acc-silent"],
                defaults: defaults
            )
        )
        #expect(
            PushHealthStore.lastNonReconnectPushAt(accountEmail: email) != nil,
            "non-vacuity: an admitted push does stamp push health"
        )
    }

    // MARK: - (3) The refused-push shape and its marker round-trip

    @Test("a refused push is stripped to an inert placeholder the main app refuses again")
    func refusedPushIsStrippedToAnInertPlaceholder() throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        // The extension-side verdict, with its reason — the log line can no
        // longer call an absent field a replaced account.
        #expect(
            NSEState.accountPushRefusal(
                "replaced-account",
                for: "notify@example.com",
                provider: "gmail",
                defaults: defaults
            ) == .replacedAccount
        )

        let content = UNMutableNotificationContent()
        content.title = "New email - Sender"
        content.body = "Subject line"
        content.categoryIdentifier = "EMAIL_ACTIONS"
        content.threadIdentifier = "thread-1"
        content.targetContentIdentifier = "target-1"
        content.badge = 3
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = [
            "provider": "gmail",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "replaced-account",
            "messageId": "m-stripped",
            "accountId": "acc1",
        ]

        neutralizeRefusedAccountPush(content)

        #expect(content.categoryIdentifier.isEmpty, "no action buttons survive on a refused push")
        #expect(content.threadIdentifier.isEmpty)
        #expect(content.targetContentIdentifier == nil)
        #expect(content.badge == nil)
        #expect(content.attachments.isEmpty)
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
        #expect(content.userInfo["messageId"] == nil, "no actionable metadata survives")
        #expect(content.userInfo[AccountPushIncarnationPolicy.refusedPushMarkerKey] as? Bool == true)

        // The marker is what closes the loop: a tap on the stripped
        // notification is refused by the main app without re-deriving anything.
        #expect(!NSEDataBridge.notificationAccountMatches(content.userInfo, defaults: defaults))
        #expect(
            NotificationDelegate.tapRoute(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: content.userInfo,
                defaults: defaults
            ) == .refusedAccount
        )
    }

    // MARK: - The extension's own entry point

    /// The fourth call site. `NotificationService` is not compiled into the
    /// test target — only the extension's leaf helpers are — so its guard is
    /// pinned by reading the source: the check must be there, it must strip the
    /// content through the shared helper, and it must return BEFORE the
    /// extension does any work on behalf of the refused account.
    @Test("the extension entry point refuses before it stamps push health or sweeps")
    func extensionEntryPointRefusesBeforeDoingAnyWorkForTheAccount() throws {
        let source = try projectSource("TabMailNotificationService/NotificationService.swift")

        let guardSite = try #require(
            source.range(of: "if let refusal = NSEState.accountPushRefusal("),
            "the extension entry point no longer consults the account-incarnation rule"
        )
        let refusalArm = try #require(
            source.range(of: "return", range: guardSite.upperBound..<source.endIndex)
        )
        let arm = String(source[guardSite.upperBound..<refusalArm.upperBound])
        #expect(
            arm.contains("neutralizeRefusedAccountPush(content)"),
            "a refused push must be stripped through the one shared definition"
        )
        #expect(arm.contains("contentHandler(content)"), "the refused push is still delivered, inert")

        // Ordering: everything the extension does on the account's behalf must
        // sit after the refusal returns.
        for laterWork in [
            "PushHealthStore.recordPush(",
            "NotificationCleanupService.sweepExpired()",
        ] {
            let site = try #require(source.range(of: laterWork), "anchor \(laterWork) moved")
            #expect(
                site.lowerBound > refusalArm.upperBound,
                "\(laterWork) runs for a push the incarnation rule refuses"
            )
        }
    }

    /// Reads a file from the checkout this test was compiled from.
    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
