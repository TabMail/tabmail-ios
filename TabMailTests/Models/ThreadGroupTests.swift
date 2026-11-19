/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ThreadGroup & ThreadDetection")
struct ThreadGroupTests {

    @Test("normalizeSubject strips Re: prefix")
    func normalizeSubjectRe() {
        #expect(ThreadUtils.normalizeSubject("Re: Hello") == "Hello")
    }

    @Test("normalizeSubject strips multiple Re:/Fwd: prefixes")
    func normalizeSubjectMultiple() {
        #expect(ThreadUtils.normalizeSubject("Re: Fwd: RE: Hello") == "Hello")
    }

    @Test("normalizeSubject strips Fwd: prefix")
    func normalizeSubjectFwd() {
        #expect(ThreadUtils.normalizeSubject("Fwd: Newsletter") == "Newsletter")
    }

    @Test("normalizeSubject strips Fw: prefix")
    func normalizeSubjectFw() {
        #expect(ThreadUtils.normalizeSubject("Fw: Newsletter") == "Newsletter")
    }

    @Test("normalizeSubject strips German reply prefix AW:")
    func normalizeSubjectGerman() {
        #expect(ThreadUtils.normalizeSubject("AW: Betreff") == "Betreff")
    }

    @Test("normalizeSubject strips Swedish reply prefix SV:")
    func normalizeSubjectSwedish() {
        #expect(ThreadUtils.normalizeSubject("SV: Ämne") == "Ämne")
    }

    @Test("normalizeSubject strips Norwegian/Danish VS:")
    func normalizeSubjectNorwegian() {
        #expect(ThreadUtils.normalizeSubject("VS: Emne") == "Emne")
    }

    @Test("normalizeSubject case-insensitive")
    func normalizeSubjectCaseInsensitive() {
        #expect(ThreadUtils.normalizeSubject("re: hello") == "hello")
        #expect(ThreadUtils.normalizeSubject("RE: hello") == "hello")
        #expect(ThreadUtils.normalizeSubject("Re: hello") == "hello")
    }

    @Test("normalizeSubject preserves subject without prefix")
    func normalizeSubjectNoPrefix() {
        #expect(ThreadUtils.normalizeSubject("Hello World") == "Hello World")
    }

    @Test("normalizeSubject trims whitespace")
    func normalizeSubjectTrims() {
        let result = ThreadUtils.normalizeSubject("Re:  Hello  ")
        #expect(result == "Hello")
    }

    @Test("computeSubjectThreadId groups by normalized subject")
    func computeSubjectThreadIdGrouping() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Budget")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Budget")
        #expect(id1 == id2)
        #expect(id1 != nil)
    }

    @Test("computeSubjectThreadId returns nil for empty subject")
    func computeSubjectThreadIdEmpty() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "")
        #expect(id == nil)
    }

    @Test("computeSubjectThreadId returns nil for '(no subject)'")
    func computeSubjectThreadIdNoSubject() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "(no subject)")
        #expect(id == nil)
    }

    @Test("computeSubjectThreadId format is subj:accountId:lowercased")
    func computeSubjectThreadIdFormat() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Hello World")
        #expect(id == "subj:acc1:hello world")
    }

    @Test("computeSubjectThreadId is case-insensitive")
    func computeSubjectThreadIdCaseInsensitive() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "HELLO")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "hello")
        #expect(id1 == id2)
    }

    @Test("computeSubjectThreadId different accounts produce different ids")
    func computeSubjectThreadIdDifferentAccounts() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Hello")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc2", subject: "Hello")
        #expect(id1 != id2)
    }

    @Test("ThreadGroup isThread for multi-member groups")
    func threadGroupIsThread() {
        let snapshot = makeSnapshot()
        let group = ThreadGroup(
            id: "t1",
            representative: snapshot,
            memberCount: 3,
            allSenders: ["Alice", "Bob", "Carol"],
            threadTag: .archive,
            hasUnread: true,
            members: [snapshot, snapshot, snapshot]
        )
        #expect(group.isThread == true)
    }

    @Test("ThreadGroup isThread false for single message")
    func threadGroupSingleMessage() {
        let snapshot = makeSnapshot()
        let group = ThreadGroup(
            id: "t1",
            representative: snapshot,
            memberCount: 1,
            allSenders: ["Alice"],
            threadTag: nil,
            hasUnread: false,
            members: [snapshot]
        )
        #expect(group.isThread == false)
    }

    @Test("ThreadGroup displayInfo nil for single message")
    func threadGroupDisplayInfoNil() {
        let snapshot = makeSnapshot()
        let group = ThreadGroup(
            id: "t1",
            representative: snapshot,
            memberCount: 1,
            allSenders: ["Alice"],
            threadTag: nil,
            hasUnread: false,
            members: [snapshot]
        )
        #expect(group.displayInfo == nil)
    }

    @Test("ThreadDisplayInfo senderList joins with comma")
    func displayInfoSenderList() {
        let snapshot = makeSnapshot()
        let group = ThreadGroup(
            id: "t1",
            representative: snapshot,
            memberCount: 2,
            allSenders: ["Alice", "Bob"],
            threadTag: nil,
            hasUnread: false,
            members: [snapshot, snapshot]
        )
        let info = group.displayInfo
        #expect(info?.senderList == "Alice, Bob")
        #expect(info?.memberCount == 2)
    }

    @Test("ThreadDisplayInfo unionLabels: every member's labels, once each, by name")
    func displayInfoUnionLabels() {
        let work = UserLabel(accountId: "acc1", providerLabelId: "work", name: "work", isSystem: false)
        let alpha = UserLabel(accountId: "acc1", providerLabelId: "alpha", name: "Alpha", isSystem: false)
        let zed = UserLabel(accountId: "acc1", providerLabelId: "zed", name: "Zed", isSystem: false)
        var first = makeSnapshot()
        first.userLabels = [zed, work]
        var second = makeSnapshot()
        second.userLabels = [work, alpha]
        let group = ThreadGroup(
            id: "t1", representative: first, memberCount: 2, allSenders: ["Alice", "Bob"],
            threadTag: nil, hasUnread: false, members: [first, second])
        #expect(group.displayInfo?.unionLabels.map(\.name) == ["Alpha", "work", "Zed"])
        #expect(UserLabel.union([[zed, work], [work, alpha]]).map(\.name) == ["Alpha", "work", "Zed"])
    }

    // Helper to create a minimal MessageSnapshot via MessageHeader
    private func makeSnapshot(actionTag: ActionTag? = nil, isInInbox: Bool = true) -> MessageSnapshot {
        var header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: isInInbox
        )
        header.actionTag = actionTag
        return MessageSnapshot(from: header)
    }
}
