/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers `ThreadUtils.outgoingThreadHeaders` — the single source of truth for
/// the In-Reply-To / References / Gmail-threadId fields a reply or forward must
/// carry so the provider files it into the source conversation.
/// See `PLAN_THREAD_FIX.md` / ADR-IOS-043.
@Suite("ThreadUtils.outgoingThreadHeaders")
struct OutgoingThreadHeadersTests {

    // Convenience wrapper around the scalar core with sensible defaults so each
    // test only states the fields it cares about.
    private func headers(
        parentRfc822: String? = "parent@example.com",
        parentRefs: [String] = [],
        parentThreadId: String? = "thread-123",
        parentAccountId: String = "acct-1",
        parentSubject: String = "Project update",
        sendAccountId: String = "acct-1",
        sendSubject: String = "Re: Project update",
        provider: AccountProvider = .gmail
    ) -> ThreadUtils.OutgoingThreadHeaders {
        ThreadUtils.outgoingThreadHeaders(
            parentRfc822MessageId: parentRfc822,
            parentReferences: parentRefs,
            parentThreadId: parentThreadId,
            parentAccountId: parentAccountId,
            parentSubject: parentSubject,
            sendAccountId: sendAccountId,
            sendSubject: sendSubject,
            providerKind: provider
        )
    }

    // MARK: - New composition

    @Test("nil replyTo (new compose) → empty headers")
    func newCompose() {
        let h = ThreadUtils.outgoingThreadHeaders(
            replyTo: nil, sendAccountId: "acct-1", sendSubject: "Hello", providerKind: .gmail)
        #expect(h == .none)
        #expect(h.inReplyTo == nil)
        #expect(h.references.isEmpty)
        #expect(h.threadId == nil)
    }

    // MARK: - Reply: In-Reply-To + References chain

    @Test("Reply to a root message (no parent references) → IRT + single-entry References")
    func replyToRoot() {
        let h = headers(parentRfc822: "root@example.com", parentRefs: [])
        #expect(h.inReplyTo == "root@example.com")
        #expect(h.references == ["root@example.com"])
        #expect(h.threadId == "thread-123")
    }

    @Test("Reply mid-thread → References = parent.references ++ parent id, order preserved")
    func replyMidThread() {
        let h = headers(
            parentRfc822: "msg3@example.com",
            parentRefs: ["msg1@example.com", "msg2@example.com"]
        )
        #expect(h.inReplyTo == "msg3@example.com")
        #expect(h.references == ["msg1@example.com", "msg2@example.com", "msg3@example.com"])
    }

    @Test("Parent id already present in parent.references is not duplicated")
    func dedupParentIdInChain() {
        let h = headers(
            parentRfc822: "msg2@example.com",
            parentRefs: ["msg1@example.com", "msg2@example.com"]
        )
        #expect(h.references == ["msg1@example.com", "msg2@example.com"])
    }

    @Test("Duplicate entries within parent.references are collapsed (order-preserving)")
    func dedupWithinChain() {
        let h = headers(
            parentRfc822: "msg3@example.com",
            parentRefs: ["msg1@example.com", "msg1@example.com", "msg2@example.com"]
        )
        #expect(h.references == ["msg1@example.com", "msg2@example.com", "msg3@example.com"])
    }

    // MARK: - Normalization (angle brackets / whitespace stripped to bare ids)

    @Test("Bracketed + whitespace parent id and refs are normalized to bare ids")
    func normalization() {
        let h = headers(
            parentRfc822: "  <msg3@example.com>  ",
            parentRefs: ["<msg1@example.com>", " <msg2@example.com> "]
        )
        #expect(h.inReplyTo == "msg3@example.com")
        #expect(h.references == ["msg1@example.com", "msg2@example.com", "msg3@example.com"])
    }

    @Test("Bracketed parent id that also appears (bracketed) in refs dedupes after normalization")
    func dedupAfterNormalization() {
        let h = headers(
            parentRfc822: "<msg2@example.com>",
            parentRefs: ["<msg1@example.com>", "msg2@example.com"]
        )
        #expect(h.references == ["msg1@example.com", "msg2@example.com"])
    }

    // MARK: - Missing parent Message-ID (common on IMAP)

    @Test("Parent without rfc822 and without references → no IRT, empty References")
    func parentNoIdNoRefs() {
        let h = headers(parentRfc822: nil, parentRefs: [])
        #expect(h.inReplyTo == nil)
        #expect(h.references.isEmpty)
    }

    @Test("Parent without rfc822 but with references → no IRT, References = parent.references only")
    func parentNoIdWithRefs() {
        let h = headers(parentRfc822: nil, parentRefs: ["msg1@example.com", "msg2@example.com"])
        #expect(h.inReplyTo == nil)
        #expect(h.references == ["msg1@example.com", "msg2@example.com"])
    }

    @Test("Empty/whitespace parent rfc822 is treated as absent")
    func emptyParentId() {
        #expect(headers(parentRfc822: "   ").inReplyTo == nil)
        #expect(headers(parentRfc822: "").inReplyTo == nil)
        #expect(headers(parentRfc822: "<>").inReplyTo == nil)
    }

    // MARK: - Forward derives the SAME headers as reply (Gmail convention, D2)

    @Test("Forward (Fwd: subject) derives identical headers to reply, incl. threadId")
    func forwardSameAsReply() {
        let reply = headers(sendSubject: "Re: Project update")
        let forward = headers(sendSubject: "Fwd: Project update")
        #expect(forward == reply)
        #expect(forward.threadId == "thread-123")
        #expect(forward.inReplyTo == "parent@example.com")
        #expect(forward.references == ["parent@example.com"])
    }

    @Test("Forward of an Fw: prefixed parent still matches via normalization")
    func forwardPrefixNormalization() {
        let h = headers(parentSubject: "Re: Project update", sendSubject: "Fwd: Project update")
        #expect(h.threadId == "thread-123")
    }

    // MARK: - Gmail threadId guards

    @Test("threadId nil when sending account differs from the parent's account")
    func threadIdCrossAccount() {
        let h = headers(parentAccountId: "acct-1", sendAccountId: "acct-2")
        #expect(h.threadId == nil)
        // Headers still built — the reply just starts a fresh Gmail thread.
        #expect(h.inReplyTo == "parent@example.com")
        #expect(h.references == ["parent@example.com"])
    }

    @Test("threadId nil when the (normalized) subject no longer matches the thread")
    func threadIdSubjectMismatch() {
        let h = headers(parentSubject: "Project update", sendSubject: "Re: Different topic")
        #expect(h.threadId == nil)
        #expect(h.inReplyTo == "parent@example.com")
    }

    @Test("threadId set when subjects match after stripping multiple prefixes")
    func threadIdSubjectMatchDeepPrefix() {
        let h = headers(parentSubject: "Fwd: Re: Quarterly", sendSubject: "Re: Quarterly")
        #expect(h.threadId == "thread-123")
    }

    @Test("threadId nil when the parent carries no native threadId")
    func threadIdMissingNative() {
        #expect(headers(parentThreadId: nil).threadId == nil)
        #expect(headers(parentThreadId: "").threadId == nil)
    }

    @Test("Non-Gmail providers never set threadId, but still build IRT + References")
    func nonGmailNoThreadId() {
        for provider in [AccountProvider.imap, .outlook] {
            let h = headers(provider: provider)
            #expect(h.threadId == nil, "provider \(provider) must not set threadId")
            #expect(h.inReplyTo == "parent@example.com")
            #expect(h.references == ["parent@example.com"])
        }
    }

    // MARK: - Adapter over a real MessageHeader

    @Test("MessageHeader adapter matches the scalar core")
    func adapterMatchesCore() {
        var parent = MessageHeader(
            messageId: "uid-1",
            subject: "Project update",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "me@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: "hi",
            folderId: "acct-1:INBOX",
            accountId: "acct-1",
            folderPath: "INBOX",
            isInInbox: true
        )
        parent.rfc822MessageId = "parent@example.com"
        parent.referencesJSON = MessageHeader.encodeReferences(["msg1@example.com"])
        parent.threadId = "thread-123"

        let viaAdapter = ThreadUtils.outgoingThreadHeaders(
            replyTo: parent,
            sendAccountId: "acct-1",
            sendSubject: "Re: Project update",
            providerKind: .gmail
        )
        let viaCore = ThreadUtils.outgoingThreadHeaders(
            parentRfc822MessageId: "parent@example.com",
            parentReferences: ["msg1@example.com"],
            parentThreadId: "thread-123",
            parentAccountId: "acct-1",
            parentSubject: "Project update",
            sendAccountId: "acct-1",
            sendSubject: "Re: Project update",
            providerKind: .gmail
        )
        #expect(viaAdapter == viaCore)
        #expect(viaAdapter.inReplyTo == "parent@example.com")
        #expect(viaAdapter.references == ["msg1@example.com", "parent@example.com"])
        #expect(viaAdapter.threadId == "thread-123")
    }
}
