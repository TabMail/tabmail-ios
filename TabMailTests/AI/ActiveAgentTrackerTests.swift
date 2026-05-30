/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActiveAgentTracker")
@MainActor
struct ActiveAgentTrackerTests {

    // MARK: - Working Sessions

    @Test("setWorking adds session key to working set")
    func setWorkingAdds() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("inbox")
        #expect(tracker.workingSessions.contains("inbox"))
        #expect(tracker.anyWorking)
    }

    @Test("clearWorking removes session key from working set")
    func clearWorkingRemoves() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("inbox")
        tracker.clearWorking("inbox")
        #expect(!tracker.workingSessions.contains("inbox"))
        #expect(!tracker.anyWorking)
    }

    @Test("anyWorking reflects set state correctly")
    func anyWorkingReflectsState() {
        let tracker = ActiveAgentTracker()
        #expect(!tracker.anyWorking)
        tracker.setWorking("msg:acct1:rfc822id1")
        #expect(tracker.anyWorking)
        tracker.setWorking("compose:draft1")
        #expect(tracker.anyWorking)
        tracker.clearWorking("msg:acct1:rfc822id1")
        #expect(tracker.anyWorking) // compose still working
        tracker.clearWorking("compose:draft1")
        #expect(!tracker.anyWorking)
    }

    @Test("isMessageWorking matches exact session key format")
    func isMessageWorkingExactMatch() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("msg:account123:messageIdABC")
        #expect(tracker.isMessageWorking(accountId: "account123", stableId: "messageIdABC"))
        #expect(!tracker.isMessageWorking(accountId: "account123", stableId: "other"))
        #expect(!tracker.isMessageWorking(accountId: "other", stableId: "messageIdABC"))
    }

    @Test("anyComposeWorking checks prefix")
    func anyComposeWorkingChecksPrefix() {
        let tracker = ActiveAgentTracker()
        #expect(!tracker.anyComposeWorking)
        tracker.setWorking("compose:draft-uuid")
        #expect(tracker.anyComposeWorking)
        tracker.setWorking("msg:acct:id")
        #expect(tracker.anyComposeWorking)
        tracker.clearWorking("compose:draft-uuid")
        #expect(!tracker.anyComposeWorking) // msg session not compose
    }

    @Test("anyBackgroundWorking excludes inbox")
    func anyBackgroundWorkingExcludesInbox() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("inbox")
        #expect(!tracker.anyBackgroundWorking)
        tracker.setWorking("msg:acct:id")
        #expect(tracker.anyBackgroundWorking)
        tracker.clearWorking("msg:acct:id")
        #expect(!tracker.anyBackgroundWorking)
    }

    @Test("multiple concurrent sessions tracked independently")
    func multipleConcurrentSessions() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("inbox")
        tracker.setWorking("msg:acct1:id1")
        tracker.setWorking("compose:draft1")
        #expect(tracker.workingSessions.count == 3)
        #expect(tracker.anyWorking)
        #expect(tracker.anyBackgroundWorking)
        #expect(tracker.anyComposeWorking)
        tracker.clearWorking("inbox")
        #expect(tracker.workingSessions.count == 2)
        #expect(tracker.anyWorking)
    }

    // MARK: - Pending Responses

    @Test("setPendingResponse and consumePendingResponse work correctly")
    func pendingResponseLifecycle() {
        let tracker = ActiveAgentTracker()
        tracker.setPendingResponse("msg:acct:id", text: "Here's what I found...")
        let response = tracker.consumePendingResponse("msg:acct:id")
        #expect(response == "Here's what I found...")
    }

    @Test("consumePendingResponse returns nil on second call (already consumed)")
    func consumePendingResponseOnlyOnce() {
        let tracker = ActiveAgentTracker()
        tracker.setPendingResponse("msg:acct:id", text: "Response")
        _ = tracker.consumePendingResponse("msg:acct:id")
        let secondCall = tracker.consumePendingResponse("msg:acct:id")
        #expect(secondCall == nil)
    }

    @Test("consumePendingResponse returns nil for unknown key")
    func consumeUnknownKey() {
        let tracker = ActiveAgentTracker()
        let result = tracker.consumePendingResponse("nonexistent")
        #expect(result == nil)
    }

    // MARK: - Compose Draft ID

    @Test("workingComposeDraftId extracts draft ID from compose session key")
    func workingComposeDraftId() {
        let tracker = ActiveAgentTracker()
        #expect(tracker.workingComposeDraftId == nil)
        tracker.setWorking("compose:my-draft-uuid")
        #expect(tracker.workingComposeDraftId == "my-draft-uuid")
        tracker.clearWorking("compose:my-draft-uuid")
        #expect(tracker.workingComposeDraftId == nil)
    }

    @Test("workingComposeDraftId ignores non-compose sessions")
    func workingComposeDraftIdIgnoresOthers() {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("inbox")
        tracker.setWorking("msg:acct:id")
        #expect(tracker.workingComposeDraftId == nil)
    }

    // MARK: - Session Key Parsing

    @Test("messageStableId parses msg: session keys correctly")
    func messageStableIdParsing() {
        let result = ActiveAgentTracker.messageStableId(from: "msg:account123:rfc822@example.com")
        #expect(result?.accountId == "account123")
        #expect(result?.stableId == "rfc822@example.com")
    }

    @Test("messageStableId returns nil for non-msg keys")
    func messageStableIdNonMsg() {
        #expect(ActiveAgentTracker.messageStableId(from: "inbox") == nil)
        #expect(ActiveAgentTracker.messageStableId(from: "compose:draft1") == nil)
    }

    @Test("messageStableId handles stableId with colons")
    func messageStableIdWithColons() {
        // rfc822 message IDs can contain colons
        let result = ActiveAgentTracker.messageStableId(from: "msg:acct:some:complex:id")
        #expect(result?.accountId == "acct")
        #expect(result?.stableId == "some:complex:id")
    }

    // MARK: - Notification

    @Test("clearWorking posts agentSessionDidFinish notification")
    func clearWorkingPostsNotification() async {
        let tracker = ActiveAgentTracker()
        tracker.setWorking("msg:acct:id")

        var receivedSessionKey: String?
        let expectation = NotificationCenter.default.notifications(named: .agentSessionDidFinish)
        let task = Task {
            for await notification in expectation {
                receivedSessionKey = notification.userInfo?["sessionKey"] as? String
                break
            }
        }

        // Small delay to ensure observer is registered
        try? await Task.sleep(for: .milliseconds(50))
        tracker.clearWorking("msg:acct:id")

        // Wait for notification
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(receivedSessionKey == "msg:acct:id")
    }
}
