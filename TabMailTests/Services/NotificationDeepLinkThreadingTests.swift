/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Combine
import Synchronization
@testable import TabMail

/// Tests that notification-based deep link delivery is always on the main thread.
/// Regression: tapping a push notification crashed with "Call must be made on main thread"
/// because `.onReceive(NotificationCenter.publisher)` delivers on whatever thread the
/// notification was posted from. Fix: `.receive(on: DispatchQueue.main)`.
@Suite("Notification Deep Link Threading")
struct NotificationDeepLinkThreadingTests {

    @Test("proactiveNotificationTapped posted from background delivers on main thread via receive(on:)")
    func backgroundPostDeliversOnMainThread() async {
        let delivered = Mutex<Bool>(false)
        let receivedOnMain = Mutex<Bool>(false)
        var cancellable: AnyCancellable?

        // Mirror the fixed pattern: .receive(on: DispatchQueue.main)
        cancellable = NotificationCenter.default
            .publisher(for: .proactiveNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                receivedOnMain.withLock { $0 = Thread.isMainThread }
                delivered.withLock { $0 = true }
            }

        // Post from a background thread (simulates iOS calling didReceive on arbitrary thread)
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .proactiveNotificationTapped,
                object: nil,
                userInfo: ["messageId": "test-msg-123"]
            )
        }

        // Wait for delivery (receive(on: DispatchQueue.main) is async)
        let deadline = Date().addingTimeInterval(3)
        while !delivered.withLock({ $0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(delivered.withLock { $0 } == true, "Notification should have been delivered")
        #expect(receivedOnMain.withLock { $0 } == true, "Handler must run on main thread")

        cancellable?.cancel()
        _ = cancellable // silence unused warning
    }

    @Test("without receive(on: main), background post delivers on background thread")
    func backgroundPostWithoutFixDeliversOffMain() async {
        let delivered = Mutex<Bool>(false)
        let receivedOnMain = Mutex<Bool>(false)
        var cancellable: AnyCancellable?

        // Without the fix — no .receive(on:)
        cancellable = NotificationCenter.default
            .publisher(for: .proactiveNotificationTapped)
            .sink { _ in
                receivedOnMain.withLock { $0 = Thread.isMainThread }
                delivered.withLock { $0 = true }
            }

        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .proactiveNotificationTapped,
                object: nil,
                userInfo: ["messageId": "test-msg-456"]
            )
        }

        let deadline = Date().addingTimeInterval(3)
        while !delivered.withLock({ $0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(delivered.withLock { $0 } == true, "Notification should have been delivered")
        #expect(receivedOnMain.withLock { $0 } == false, "Without fix, handler runs on posting thread (background)")

        cancellable?.cancel()
        _ = cancellable
    }

    @Test("emailPillTapped posted from background delivers on main thread via receive(on:)")
    func emailPillBackgroundPostDeliversOnMainThread() async {
        let delivered = Mutex<Bool>(false)
        let receivedOnMain = Mutex<Bool>(false)
        var cancellable: AnyCancellable?

        cancellable = NotificationCenter.default
            .publisher(for: .emailPillTapped)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                receivedOnMain.withLock { $0 = Thread.isMainThread }
                delivered.withLock { $0 = true }
            }

        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .emailPillTapped,
                object: nil,
                userInfo: ["realId": "test-msg-789"]
            )
        }

        let deadline = Date().addingTimeInterval(3)
        while !delivered.withLock({ $0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(delivered.withLock { $0 } == true, "Notification should have been delivered")
        #expect(receivedOnMain.withLock { $0 } == true, "Handler must run on main thread")

        cancellable?.cancel()
        _ = cancellable
    }

    @Test("notification userInfo preserves messageId through main thread hop")
    func userInfoPreservedThroughMainThreadHop() async {
        let delivered = Mutex<Bool>(false)
        let receivedId = Mutex<String?>(Optional<String>.none)
        var cancellable: AnyCancellable?

        cancellable = NotificationCenter.default
            .publisher(for: .proactiveNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { notification in
                receivedId.withLock { $0 = notification.userInfo?["messageId"] as? String }
                delivered.withLock { $0 = true }
            }

        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .proactiveNotificationTapped,
                object: nil,
                userInfo: ["messageId": "deep-link-msg-abc"]
            )
        }

        let deadline = Date().addingTimeInterval(3)
        while !delivered.withLock({ $0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(delivered.withLock { $0 } == true)
        #expect(receivedId.withLock { $0 } == "deep-link-msg-abc", "messageId must survive the main-thread hop")

        cancellable?.cancel()
        _ = cancellable
    }

    // MARK: - Producer forwards accountId (regression for the dropped-accountId bug)

    @Test("nseMessageDeepLink forwards accountId into BOTH the repost and the cold-start link")
    func nseDeepLinkForwardsAccountId() {
        // The delivered notification carries the local Account.id (EmailNotificationBuilder).
        // The tap path MUST forward it or the wrong-account resolve + staging-direct tier
        // are dead (they gate on accountId). Regression: the old inline path reposted only
        // messageId.
        guard let (link, messageId, accountId) = NotificationDelegate.nseMessageDeepLink(
            from: ["messageId": "100", "provider": "imap", "accountId": "acc-uuid-1"]
        ) else {
            Issue.record("expected an NSE message deep link")
            return
        }
        #expect(messageId == "100")
        #expect(accountId == "acc-uuid-1",
                "accountId must be forwarded so the tap resolve can disambiguate accounts")
        guard case .message(let linkId, let linkAccountId) = link else {
            Issue.record("expected .message")
            return
        }
        #expect(linkId == "100")
        #expect(linkAccountId == "acc-uuid-1", "cold-start link must also carry accountId")
    }

    @Test("nseMessageDeepLink tolerates a legacy payload with no accountId")
    func nseDeepLinkLegacyNoAccountId() {
        guard let (link, messageId, accountId) = NotificationDelegate.nseMessageDeepLink(
            from: ["messageId": "100", "provider": "imap"]
        ) else {
            Issue.record("expected a deep link")
            return
        }
        #expect(messageId == "100")
        #expect(accountId == nil, "no accountId when the payload omits it")
        guard case .message(_, let linkAccountId) = link else {
            Issue.record("expected .message")
            return
        }
        #expect(linkAccountId == nil)
    }

    @Test("nseMessageDeepLink returns nil for a non-NSE-message notification")
    func nseDeepLinkRejectsNonMessage() {
        #expect(NotificationDelegate.nseMessageDeepLink(from: ["messageId": "100"]) == nil,
                "no provider marker → not an NSE new-mail tap")
        #expect(NotificationDelegate.nseMessageDeepLink(from: ["provider": "imap"]) == nil,
                "no messageId → not a message deep link")
    }

    @Test("deep link store integrates correctly with notification flow")
    func deepLinkStoreIntegrationWithNotification() async {
        // Clear any leftover state
        _ = PendingDeepLinkStore.consume()

        let delivered = Mutex<Bool>(false)
        var cancellable: AnyCancellable?

        cancellable = NotificationCenter.default
            .publisher(for: .proactiveNotificationTapped)
            .receive(on: DispatchQueue.main)
            .sink { notification in
                // Simulate what handleNotificationDeepLink does: consume pending store
                _ = PendingDeepLinkStore.consume()
                delivered.withLock { $0 = true }
            }

        // Simulate what NotificationDelegate.didReceive does:
        // 1. Store the deep link
        PendingDeepLinkStore.store(.message(id: "notif-msg-xyz", accountId: nil))

        // 2. Post notification from background (mimics didReceive on arbitrary thread)
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(
                name: .proactiveNotificationTapped,
                object: nil,
                userInfo: ["messageId": "notif-msg-xyz"]
            )
        }

        let deadline = Date().addingTimeInterval(3)
        while !delivered.withLock({ $0 }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(delivered.withLock { $0 } == true)
        // After handler consumed, store should be empty
        #expect(PendingDeepLinkStore.consume() == nil, "Handler should have consumed the pending deep link")

        cancellable?.cancel()
        _ = cancellable
    }
}
