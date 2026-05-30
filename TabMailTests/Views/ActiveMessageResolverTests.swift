/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Regression coverage for the toolbar Reply / Reply-All "stale suggested-reply" bug.
/// The fix re-resolves the stored context snapshot by id against the viewModel's live
/// arrays so `cachedReply` (populated asynchronously by AI) is visible to the bottom bar.
@Suite("ActiveMessageResolver")
struct ActiveMessageResolverTests {

    // MARK: - Fixture

    private func makeHeader(id rawId: String, cachedReply: String? = nil) -> MessageHeader {
        // `id` is derived from messageId/folderPath/accountId via MessageIdentity.
        // Keep accountId/folderPath stable so we can control the resulting id via messageId.
        var h = MessageHeader(
            messageId: rawId,
            subject: "s",
            from: "Sender",
            fromAddress: "s@x.com",
            to: "t@x.com",
            date: Date(timeIntervalSince1970: 0),
            snippet: "",
            folderId: "acct:INBOX",
            accountId: "acct",
            folderPath: "INBOX",
            isInInbox: true
        )
        h.cachedReply = cachedReply
        return h
    }

    // MARK: - Tests

    @Test("nil context falls through to focused message")
    func nilContextReturnsFocused() {
        let focused = makeHeader(id: "m1")
        let result = ActiveMessageResolver.resolve(
            context: nil, focused: focused, later: [], earlier: []
        )
        #expect(result?.id == focused.id)
    }

    @Test("nil context + nil focused returns nil")
    func nothingReturnsNil() {
        let result = ActiveMessageResolver.resolve(
            context: nil, focused: nil, later: [], earlier: []
        )
        #expect(result == nil)
    }

    @Test("matches focused by id, returning the live instance")
    func matchesFocused() {
        let stale = makeHeader(id: "m1", cachedReply: nil)
        let live = makeHeader(id: "m1", cachedReply: "Hi there")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: live, later: [], earlier: []
        )
        #expect(result?.cachedReply == "Hi there")
    }

    @Test("matches in laterMessages, returning the live instance")
    func matchesLater() {
        let stale = makeHeader(id: "m2", cachedReply: nil)
        let live = makeHeader(id: "m2", cachedReply: "Sure")
        let other = makeHeader(id: "m3")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: other, later: [live], earlier: []
        )
        #expect(result?.cachedReply == "Sure")
    }

    @Test("matches in earlierMessages, returning the live instance")
    func matchesEarlier() {
        let stale = makeHeader(id: "m4", cachedReply: nil)
        let live = makeHeader(id: "m4", cachedReply: "Ack")
        let other = makeHeader(id: "m5")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: other, later: [], earlier: [live]
        )
        #expect(result?.cachedReply == "Ack")
    }

    @Test("regression: stale snapshot is replaced when live instance has cachedReply")
    func regressionStaleReplyReplaced() {
        // Captured via CardVisibilityKey BEFORE AI generated the reply.
        let stale = makeHeader(id: "m6", cachedReply: nil)
        // Later, AI populated cachedReply on the live instance in viewModel.
        let live = makeHeader(id: "m6", cachedReply: "Generated reply body")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: live, later: [], earlier: []
        )
        #expect(result?.cachedReply == "Generated reply body")
    }

    @Test("falls back to stale context when no live instance is found")
    func fallbackToContext() {
        // Edge case: viewModel arrays don't contain the context id (e.g. message was
        // evicted). Preserve previous behavior by returning the stale snapshot.
        let stale = makeHeader(id: "m7", cachedReply: "from-context")
        let unrelated = makeHeader(id: "m8")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: unrelated, later: [], earlier: []
        )
        #expect(result?.id == stale.id)
        #expect(result?.cachedReply == "from-context")
    }

    @Test("laterMessages is searched before focused (thread ordering)")
    func laterBeforeFocused() {
        // If both arrays contain an instance with the same id, prefer laterMessages.
        // (In practice this shouldn't happen, but the resolver's ordering is stable.)
        let stale = makeHeader(id: "m9", cachedReply: nil)
        let later = makeHeader(id: "m9", cachedReply: "from-later")
        let focused = makeHeader(id: "m9", cachedReply: "from-focused")
        let result = ActiveMessageResolver.resolve(
            context: stale, focused: focused, later: [later], earlier: []
        )
        #expect(result?.cachedReply == "from-later")
    }
}
