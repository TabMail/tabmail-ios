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

    @Test("Compose session keys include the exact generation and remain injective")
    func workingComposeDraftId() {
        let tracker = ActiveAgentTracker()
        #expect(tracker.workingComposeDraftId == nil)
        let keyA = ActiveAgentTracker.composeSessionKey(
            draftId: "reply:acct:msg", epoch: "legacy:op:42")
        let keyB = ActiveAgentTracker.composeSessionKey(
            draftId: "reply:acct:msg:legacy:op", epoch: "42")
        #expect(keyA != keyB)
        #expect(ActiveAgentTracker.parseComposeSession(keyA)?.draftId == "reply:acct:msg")
        #expect(ActiveAgentTracker.parseComposeSession(keyA)?.epoch == "legacy:op:42")
        #expect(ActiveAgentTracker.parseComposeSession(keyB)?.draftId == "reply:acct:msg:legacy:op")
        #expect(ActiveAgentTracker.parseComposeSession(keyB)?.epoch == "42")
        tracker.setWorking(keyA)
        #expect(tracker.workingComposeDraftId == "reply:acct:msg")
        tracker.clearWorking(keyA)
        #expect(tracker.workingComposeDraftId == nil)
    }

    // MARK: - R16-11 — every producer of a compose session key mints it

    /// 🚨 THE INVARIANT (system property, not mechanism — `MIS-015`): **a compose
    /// session key produced anywhere in the app decodes back to the draft id it was
    /// made for.** Asserted here against `ScreenshotMode`'s fixture key, which built
    /// itself by hand as `"compose:<draftId>"` — a format that stopped being current
    /// at PORT `3f2cc4c34`, when the key became
    /// `compose:<epochByteCount>:<epoch><draftId>` behind
    /// `ActiveAgentTracker.composeSessionKey`. R15-FIX-4b ported one of the two known
    /// consumers and this was a THIRD, missed because both greps were for the SYMBOL
    /// while this site spelled only the FORMAT (`MIS-018` — the unit of a port is the
    /// CONTRACT).
    ///
    /// The assertion is deliberately a DECODE of the producer's own constant rather
    /// than a comparison against a key this test mints: minting it here would compare
    /// `composeSessionKey` with itself and stay green no matter what `ScreenshotMode`
    /// does. `ScreenshotMode.seededComposeSessionKey` is the exact value
    /// `seedChatSessionsIfNeeded` passes to `ChatPillState.session(for:)`.
    ///
    /// ⚠️ TWO NAMESPACES SHARE THE `compose:` PREFIX and only one is governed here:
    /// `ChatStore` session ids are the bare `compose:<draftId>`, while
    /// `ActiveAgentTracker` / `ChatPillState` keys carry the length-prefixed epoch.
    /// `composeSessionKey` must NOT be weakened to accept a bare key — the length
    /// prefix is what keeps the encoding injective when a draft id or an epoch
    /// contains a colon, and both can. The bare-key rejection below is that anchor.
    @Test("ScreenshotMode's seeded compose key round-trips through the real parser")
    func screenshotComposeSessionKeyRoundTrips() {
        let key = ScreenshotMode.seededComposeSessionKey
        let parsed = ActiveAgentTracker.parseComposeSession(key)
        #expect(parsed?.draftId == ScreenshotMode.seededComposeDraftId,
                """
                the screenshot fixture's ChatPillState key must decode back to the draft id \
                it names — a hand-rolled "compose:<draftId>" key binds to no live compose \
                session, because every live producer mints the length-prefixed epoch form. \
                Got \(parsed?.draftId ?? "nil") from key \(key)
                """)
        #expect(parsed?.epoch.isEmpty == false,
                "and it must carry an epoch — the half of the key a bare format has no room for")

        // NON-VACUITY / the held direction (`MIS-026`): the parser is not one that
        // accepts anything with the prefix. A bare key is REFUSED, which is exactly
        // why the hand-rolled fixture key bound to nothing.
        #expect(
            ActiveAgentTracker.parseComposeSession(
                "compose:\(ScreenshotMode.seededComposeDraftId)") == nil,
            "a bare `compose:<draftId>` key must stay unparseable — weakening the decoder is the mirror-image fix")
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
