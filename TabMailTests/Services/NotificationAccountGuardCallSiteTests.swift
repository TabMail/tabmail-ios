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
/// 1. **A user's action tap is never discarded on a verdict we could not
///    reach, and never admitted on one we could.** MARK_READ / ARCHIVE /
///    DELETE are durable intentions and iOS dismisses the notification the
///    instant the button is tapped, so a refusal on an UNDETERMINED verdict
///    would destroy the intention with no queue row, no error, and nothing left
///    on screen to retry from. A PROVEN verdict is the opposite case: admitting
///    a payload whose identity is contradicted or superseded mutates a message
///    the user was never shown, and C3 has no recovery.
/// 1b. **A built notification names exactly one identity**, so the account
///    acted upon is the account that was checked.
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

    // MARK: - (1) The action path is gated by PROOF, never by uncertainty

    /// CORRECTED 2026-08-27. This test used to be named
    /// `refusedIncarnationActionTapStillProducesItsDurableOperation` and used to
    /// require the OPPOSITE of what it requires now: it built a payload whose
    /// two identity claims contradict each other (`accountIncarnation:
    /// "replaced-account"` beside `accountId: "acc1"`), asserted as its premise
    /// that the incarnation rule refuses it, and then asserted that the ARCHIVE
    /// went through anyway and MOVED THE CURRENT ACCOUNT'S ROW — one `.move`
    /// PendingOperation on `acc1`, with the header ending up in Archive. That is
    /// the C3 hazard stated as a requirement: a push admitted for one
    /// incarnation mutating another incarnation's message.
    @Test("""
    a notification ARCHIVE tap whose payload names two DIFFERENT identities \
    mutates neither: no PendingOperation, and the addressed row never moves
    """)
    func contradictoryActionTapMutatesNothing() async throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let durable: MessageHeader = {
            var h = MessageHeader(
                messageId: "m-contradictory", subject: "Subj", from: "Sender",
                fromAddress: "sender@example.com", to: "notify@example.com", date: Date(),
                snippet: "snip", folderId: inbox.id, accountId: "acc1", folderPath: inbox.path,
                isInInbox: true
            )
            h.headerComplete = true
            return h
        }()
        try await pool.writeWithoutTransaction { db in try durable.insert(db) }
        let id = durable.id

        // The contradiction: routed from an incarnation that is gone, yet
        // naming the CURRENT row as the thing to mutate.
        let userInfo: [AnyHashable: Any] = [
            "provider": "gmail",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "replaced-account",
            "messageId": "m-contradictory",
            "accountId": "acc1",
        ]
        #expect(
            NSEDataBridge.notificationIsSuperseded(userInfo, defaults: defaults),
            "premise: this payload IS proven superseded, not merely undetermined"
        )

        let route = NotificationDelegate.tapRoute(
            actionId: "ARCHIVE",
            userInfo: userInfo,
            defaults: defaults
        )
        #expect(
            route == .refusedAccount,
            "C3: an action may never mutate an account the push was not admitted for"
        )

        // Drive the whole delegate seam, not just the router, so a future
        // regression that re-adds an action arm ahead of the check is caught.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NotificationDelegate.handleNotificationResponse(
                actionId: "ARCHIVE",
                userInfo: userInfo,
                identifier: "contradictory-archive",
                defaults: defaults
            ) {
                continuation.resume()
            }
        }

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "a refused tap must leave no durable operation behind")
        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == inbox.id, "the addressed row must not have moved")

        // ── OPPOSITE POLARITY, same harness: the SAME tap on a payload whose
        // single identity the mirror confirms still archives. Without this the
        // assertions above would be satisfied by a route that refuses
        // everything.
        var consistent = userInfo
        consistent["accountIncarnation"] = "acc1"
        let admitted = NotificationDelegate.tapRoute(
            actionId: "ARCHIVE",
            userInfo: consistent,
            defaults: defaults
        )
        #expect(
            admitted == .durableAction(actionId: "ARCHIVE", messageId: "m-contradictory", accountId: "acc1"),
            "a genuinely valid notification must still be actionable"
        )
        guard case .durableAction(let actionId, let messageId, let accountId) = admitted else { return }
        await NotificationActionRouter.execute(actionId: actionId, messageId: messageId, accountId: accountId)

        let admittedOps = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(admittedOps.count == 1, "the valid tap must survive as durable intention")
        guard admittedOps.count == 1 else { return }
        #expect(admittedOps[0].type == .move)
        #expect(admittedOps[0].folderPath == inbox.path)
        #expect(admittedOps[0].destinationPath == archive.path)
        #expect(admittedOps[0].messageIds == ["m-contradictory"])
        let moved = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(moved?.folderId == archive.id)
    }

    /// CORRECTED 2026-08-27. This test used to be named
    /// `everyActionButtonRoutesDurablyUnderEveryIncarnationVerdict` and used to
    /// require that all three action buttons route durably under a `("stale",
    /// "replaced-account")` payload as well as under absent and matching ones —
    /// "the durable route must be identical in all three". It made the C3
    /// hazard a property of every action button at once.
    @Test("""
    every action button routes durably under an UNDETERMINED verdict and \
    refuses under a PROVEN one — never the reverse
    """)
    func everyActionButtonSeparatesUndeterminedFromProven() throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        for actionId in ["MARK_READ", "ARCHIVE", "DELETE"] {
            // ── UNDETERMINED must still route durably. NEVER DROP USER
            // INTENTION: iOS dismisses the notification on tap, so a refusal on
            // a verdict we could not reach destroys the intention outright.
            //
            // `absent` is what every deployed push sends today; `unmirrored` is
            // an address the map cannot answer for (a casing gap, a
            // not-yet-mirrored account, an interrupted removal commit).
            let undetermined: [(label: String, userInfo: [AnyHashable: Any])] = [
                ("absent incarnation", [
                    "provider": "gmail",
                    "accountEmail": "notify@example.com",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc1",
                ]),
                ("unmirrored address", [
                    "provider": "gmail",
                    "accountEmail": "not-mirrored@example.com",
                    "accountIncarnation": "acc1",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc1",
                ]),
                ("no address at all", [
                    "provider": "gmail",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc1",
                ]),
            ]
            for case (let label, let userInfo) in undetermined {
                #expect(
                    NotificationDelegate.tapRoute(actionId: actionId, userInfo: userInfo, defaults: defaults)
                        == .durableAction(actionId: actionId, messageId: "m-\(actionId)", accountId: "acc1"),
                    "\(actionId) under an undetermined verdict (\(label)) must still route durably"
                )
            }

            // ── PROVEN must refuse. Two independent proofs, neither needing the
            // other: the payload contradicts itself, and the mirror names a
            // different row for the address the payload claims.
            let proven: [(label: String, userInfo: [AnyHashable: Any])] = [
                ("self-contradictory", [
                    "provider": "gmail",
                    "accountEmail": "notify@example.com",
                    "accountIncarnation": "replaced-account",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc1",
                ]),
                ("account replaced after delivery", [
                    "provider": "gmail",
                    "accountEmail": "notify@example.com",
                    "accountIncarnation": "acc0",
                    "messageId": "m-\(actionId)",
                    "accountId": "acc0",
                ]),
            ]
            for case (let label, let userInfo) in proven {
                #expect(
                    NotificationDelegate.tapRoute(actionId: actionId, userInfo: userInfo, defaults: defaults)
                        == .refusedAccount,
                    "\(actionId) on a proven-superseded payload (\(label)) must be refused"
                )
            }

            // ── And the ordinary valid case still routes.
            #expect(
                NotificationDelegate.tapRoute(
                    actionId: actionId,
                    userInfo: [
                        "provider": "gmail",
                        "accountEmail": "notify@example.com",
                        "accountIncarnation": "acc1",
                        "messageId": "m-\(actionId)",
                        "accountId": "acc1",
                    ],
                    defaults: defaults
                ) == .durableAction(actionId: actionId, messageId: "m-\(actionId)", accountId: "acc1"),
                "\(actionId) on a proven-current payload must route durably"
            )
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

    // MARK: - (1b) The binding: one identity per notification

    @Test("""
    a built notification names exactly ONE identity, so the account acted upon \
    is always the account that was checked
    """)
    func aBuiltNotificationCarriesOneIdentityOnly() throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        // The incoming push claims the incarnation it was routed from. The
        // extension resolves and processes some account; whichever one it is,
        // the notification it hands back must name that one and only that one.
        let content = UNMutableNotificationContent()
        content.userInfo = [
            "provider": "gmail",
            "accountEmail": "notify@example.com",
            "accountIncarnation": "routed-from-account",
        ]
        EmailNotificationBuilder.fill(
            content,
            signal: .init(senderName: "Sender", subject: "Subject"),
            accountId: "acc1",
            messageId: "m-bound"
        )
        #expect(content.userInfo["accountId"] as? String == "acc1")
        #expect(
            content.userInfo["accountIncarnation"] as? String == "acc1",
            "the incoming incarnation claim must be OVERWRITTEN by the identity the content was built from"
        )

        // The consequence: this notification is actionable, and it is actionable
        // against exactly the account it was built from.
        #expect(
            NotificationDelegate.tapRoute(
                actionId: "ARCHIVE",
                userInfo: content.userInfo,
                defaults: defaults
            ) == .durableAction(actionId: "ARCHIVE", messageId: "m-bound", accountId: "acc1")
        )

        // Opposite polarity: had the two claims been allowed to disagree — which
        // is exactly what a notification built before this rule looks like —
        // every action path refuses it.
        var split = content.userInfo
        split["accountIncarnation"] = "routed-from-account"
        for actionId in ["MARK_READ", "ARCHIVE", "DELETE", UNNotificationDefaultActionIdentifier] {
            #expect(
                NotificationDelegate.tapRoute(actionId: actionId, userInfo: split, defaults: defaults)
                    == .refusedAccount,
                "\(actionId) must refuse a notification that names two identities"
            )
        }
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

    // MARK: - (2b) An unreadable mirror never discards a valid notification

    @Test("""
    a valid notification is never discarded because the account mirror could \
    not be read — at presentation, at a plain tap and on an action
    """)
    func anUnreadableMirrorNeverDiscardsAValidNotification() async throws {
        // Three ways the mirror read fails, none of them evidence about the
        // account: no value at all, undecodable JSON, and a decodable map that
        // does not carry this address (a casing gap left by an upgrade, an
        // account not yet mirrored, or the briefly-empty map an interrupted
        // account-removal commit leaves behind).
        let email = "mirror-\(UUID().uuidString.lowercased())@example.com"
        let unreadable: [(label: String, json: String?)] = [
            ("absent", nil),
            ("undecodable", "{not json"),
            ("address not carried", "{\"other@example.com\":\"acc9\"}"),
        ]

        for (label, json) in unreadable {
            let name = "NotificationAccountGuardCallSiteTests.unreadable.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let json { defaults.set(json, forKey: "nse.accountMap") }

            // `imap_reconnect` is account-scoped but NOT in the suppress-and-sync
            // set, so an admitted presentation is distinguishable from a refusal.
            let presentable: [AnyHashable: Any] = [
                "provider": "imap_reconnect",
                "accountEmail": email,
                "accountIncarnation": "acc-unreadable",
            ]
            let options = await NotificationDelegate.foregroundPresentationOptions(
                for: presentable,
                identifier: "unreadable-present-\(label)",
                defaults: defaults
            )
            #expect(
                options == [.banner, .sound, .list],
                "a \(label) mirror must not suppress a valid notification's banner"
            )

            let tappable: [AnyHashable: Any] = [
                "provider": "gmail",
                "accountEmail": email,
                "accountIncarnation": "acc-unreadable",
                "messageId": "m-unreadable",
                "accountId": "acc-unreadable",
            ]
            #expect(
                NotificationDelegate.tapRoute(
                    actionId: UNNotificationDefaultActionIdentifier,
                    userInfo: tappable,
                    defaults: defaults
                ) == .passthrough,
                "a \(label) mirror must not refuse a plain tap"
            )
            for actionId in ["MARK_READ", "ARCHIVE", "DELETE"] {
                #expect(
                    NotificationDelegate.tapRoute(actionId: actionId, userInfo: tappable, defaults: defaults)
                        == .durableAction(actionId: actionId, messageId: "m-unreadable", accountId: "acc-unreadable"),
                    "a \(label) mirror must not destroy a durable \(actionId) intention"
                )
            }
        }

        // ── OPPOSITE POLARITY: with a mirror that CAN answer and names a
        // different row, every one of those same four sites refuses. Without
        // this the loop above would be satisfied by a guard that admits
        // everything.
        let (mirror, name) = try makeAccountMirror([email: "acc-current"])
        defer { mirror.removePersistentDomain(forName: name) }
        let superseded: [AnyHashable: Any] = [
            "provider": "imap_reconnect",
            "accountEmail": email,
            "accountIncarnation": "acc-unreadable",
        ]
        let refusedOptions = await NotificationDelegate.foregroundPresentationOptions(
            for: superseded,
            identifier: "superseded-present",
            defaults: mirror
        )
        #expect(refusedOptions == [])
        let supersededTap: [AnyHashable: Any] = [
            "provider": "gmail",
            "accountEmail": email,
            "accountIncarnation": "acc-unreadable",
            "messageId": "m-unreadable",
            "accountId": "acc-unreadable",
        ]
        #expect(
            NotificationDelegate.tapRoute(
                actionId: UNNotificationDefaultActionIdentifier,
                userInfo: supersededTap,
                defaults: mirror
            ) == .refusedAccount
        )
        for actionId in ["MARK_READ", "ARCHIVE", "DELETE"] {
            #expect(
                NotificationDelegate.tapRoute(actionId: actionId, userInfo: supersededTap, defaults: mirror)
                    == .refusedAccount
            )
        }
    }

    /// The silent-push half of the property above. Split out only because
    /// `AppDelegate` is `@MainActor` while the presentation seam is nonisolated,
    /// so one function cannot drive both.
    @MainActor
    @Test("an unreadable account mirror never turns a valid silent push into .noData")
    func anUnreadableMirrorNeverRefusesAValidSilentPush() throws {
        for (label, json) in [
            ("absent", String?.none),
            ("undecodable", "{not json"),
            ("address not carried", "{\"other@example.com\":\"acc9\"}"),
        ] {
            // Lowercased + unique: `PushHealthStore` is process-global, so each
            // case needs its own address to stay independent.
            let email = "silent-mirror-\(UUID().uuidString.lowercased())@example.com"
            let name = "NotificationAccountGuardCallSiteTests.silent.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let json { defaults.set(json, forKey: "nse.accountMap") }

            #expect(
                AppDelegate.admitSilentPush(
                    ["provider": "gmail", "accountEmail": email, "accountIncarnation": "acc-unreadable"],
                    defaults: defaults
                ),
                "a \(label) mirror must not turn a valid silent push into .noData"
            )
        }

        // Opposite polarity: a mirror that CAN answer and names a different row
        // still refuses, so the loop above is not measuring an always-true
        // predicate.
        let email = "silent-superseded-\(UUID().uuidString.lowercased())@example.com"
        let (mirror, name) = try makeAccountMirror([email: "acc-current"])
        defer { mirror.removePersistentDomain(forName: name) }
        #expect(
            !AppDelegate.admitSilentPush(
                ["provider": "gmail", "accountEmail": email, "accountIncarnation": "acc-unreadable"],
                defaults: mirror
            )
        )
    }

    // MARK: - (3) The refused-push shape and its marker round-trip

    @Test("a refused push is stripped to an inert placeholder the main app refuses again")
    func refusedPushIsStrippedToAnInertPlaceholder() throws {
        let (defaults, name) = try makeAccountMirror()
        defer { defaults.removePersistentDomain(forName: name) }

        // The extension-side verdict. Stripping is TERMINAL — the marker below
        // makes the main app refuse the same payload again without re-deriving
        // anything — so it may only ever follow a PROVEN verdict.
        #expect(
            NSEState.accountPushVerdict(
                "replaced-account",
                for: "notify@example.com",
                provider: "gmail",
                defaults: defaults
            ) == .superseded
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
        #expect(NSEDataBridge.notificationIsSuperseded(content.userInfo, defaults: defaults))
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
    @Test("the extension entry point strips only on PROOF, and binds what it checked")
    func extensionEntryPointRefusesBeforeDoingAnyWorkForTheAccount() throws {
        let source = try projectSource("TabMailNotificationService/NotificationService.swift")

        let verdictSite = try #require(
            source.range(of: "let accountVerdict = NSEState.accountPushVerdict("),
            "the extension entry point no longer consults the account-incarnation rule"
        )
        let guardSite = try #require(
            source.range(of: "if accountVerdict.isSuperseded {", range: verdictSite.upperBound..<source.endIndex),
            """
            the extension must strip ONLY on a proven supersession — a guard that \
            refuses anything other than `.superseded` folds an undetermined \
            verdict back into a terminal discard
            """
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

        // BINDING: the identity the admission proved is carried into processing
        // rather than re-read. Without this the extension can validate
        // incarnation A here and process B at step 1, stamping a notification
        // whose two identity claims disagree.
        let bindSite = try #require(
            source.range(of: "\"boundAccountId\": accountVerdict.boundAccountId ?? \"\"", range: refusalArm.upperBound..<source.endIndex),
            "the proven identity is no longer carried forward from the admission check"
        )
        let stepOne = try #require(
            source.range(of: "let boundAccountId = info[\"boundAccountId\"] ?? \"\"", range: bindSite.upperBound..<source.endIndex),
            "step 1 no longer consumes the bound identity"
        )
        let stepOneResolve = try #require(
            source.range(of: "NSEState.findAccountId(for: accountEmail)", range: stepOne.upperBound..<source.endIndex)
        )
        let resolution = String(source[stepOne.lowerBound..<stepOneResolve.upperBound])
        #expect(
            resolution.contains("boundAccountId.isEmpty"),
            """
            step 1 must re-read the mirror ONLY when nothing was proved — an \
            unconditional re-read is the contradiction this binding removes
            """
        )
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
