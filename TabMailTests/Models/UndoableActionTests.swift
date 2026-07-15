/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// ADR-IOS-060: `UndoableAction` stores only enough command data to issue the
/// inverse move (per-account `forwardDestinationPath`/`members`) — no full-row
/// snapshot, no token. These tests pin the label formatting and the plain
/// `commands(for:forwardDestinationByAccount:)` grouping/admission helper.
@Suite("UndoableAction Label Formatting")
struct UndoableActionLabelTests {

    private func member(_ n: Int) -> UndoMember {
        UndoMember(
            rfc822MessageId: "m\(n)@example.com",
            sourceFolderPath: "INBOX",
            originalHeaderId: "acc1:INBOX:msg\(n)"
        )
    }

    @Test("Move label singular")
    func moveLabelSingular() {
        let action = UndoableAction(commands: [
            UndoAccountCommand(accountId: "acc1", forwardDestinationPath: "Trash", members: [member(1)]),
        ])
        #expect(action.label == "Moved 1 message")
    }

    @Test("Move label plural")
    func moveLabelPlural() {
        let action = UndoableAction(commands: [
            UndoAccountCommand(
                accountId: "acc1", forwardDestinationPath: "Trash",
                members: [member(1), member(2), member(3)]
            ),
        ])
        #expect(action.label == "Moved 3 messages")
    }

    @Test("Move label sums members across multiple account commands")
    func moveLabelSumsAcrossCommands() {
        let action = UndoableAction(commands: [
            UndoAccountCommand(accountId: "acc1", forwardDestinationPath: "Archive", members: [member(1)]),
            UndoAccountCommand(accountId: "acc2", forwardDestinationPath: "Archive", members: [member(2), member(3)]),
        ])
        #expect(action.totalMemberCount == 3)
        #expect(action.label == "Moved 3 messages")
    }

    @Test("id is UI-local and distinct per action")
    func idIsDistinctPerAction() {
        let a = UndoableAction(commands: [])
        let b = UndoableAction(commands: [])
        #expect(a.id != b.id)
    }
}

// MARK: - UndoableAction.commands(for:forwardDestinationByAccount:) admission

@Suite("UndoableAction.commands admission")
struct UndoableActionCommandsAdmissionTests {

    private func makeHeader(
        messageId: String,
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        rfc822MessageId: String? = nil
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@test.com",
            to: "bob@test.com",
            date: Date(),
            snippet: "",
            folderId: "\(accountId):\(folderPath)",
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.rfc822MessageId = rfc822MessageId ?? "\(messageId)@example.com"
        return header
    }

    @Test("builds one command per account, routing to that account's own destination")
    func oneCommandPerAccount() {
        let h1 = makeHeader(messageId: "m1", accountId: "acc1")
        let h2 = makeHeader(messageId: "m2", accountId: "acc2")
        let commands = UndoableAction.commands(
            for: [h1, h2],
            forwardDestinationByAccount: ["acc1": "Archive", "acc2": "[Gmail]/All Mail"]
        )
        #expect(commands.count == 2)
        let byAccount = Dictionary(uniqueKeysWithValues: commands.map { ($0.accountId, $0) })
        #expect(byAccount["acc1"]?.forwardDestinationPath == "Archive")
        #expect(byAccount["acc2"]?.forwardDestinationPath == "[Gmail]/All Mail")
        #expect(byAccount["acc1"]?.members.map(\.originalHeaderId) == [h1.id])
        #expect(byAccount["acc2"]?.members.map(\.originalHeaderId) == [h2.id])
    }

    @Test("member without a resolvable RFC identity is omitted")
    func invalidRfcMemberOmitted() {
        let valid = makeHeader(messageId: "m1")
        var invalid = makeHeader(messageId: "m2")
        invalid.rfc822MessageId = nil
        let commands = UndoableAction.commands(
            for: [valid, invalid],
            forwardDestinationByAccount: ["acc1": "Archive"]
        )
        #expect(commands.count == 1)
        #expect(commands.first?.members.map(\.originalHeaderId) == [valid.id])
    }

    @Test("account with no recorded destination is omitted entirely")
    func accountWithNoDestinationOmitted() {
        let h1 = makeHeader(messageId: "m1", accountId: "acc1")
        let h2 = makeHeader(messageId: "m2", accountId: "acc2")
        let commands = UndoableAction.commands(
            for: [h1, h2],
            forwardDestinationByAccount: ["acc1": "Archive"]
        )
        #expect(commands.count == 1)
        #expect(commands.first?.accountId == "acc1")
    }

    @Test("preserves each member's own pre-move source folder path")
    func preservesSourceFolderPath() {
        let h1 = makeHeader(messageId: "m1", folderPath: "INBOX")
        let h2 = makeHeader(messageId: "m2", folderPath: "Projects")
        let commands = UndoableAction.commands(
            for: [h1, h2],
            forwardDestinationByAccount: ["acc1": "Archive"]
        )
        #expect(commands.count == 1)
        let bySource = Dictionary(uniqueKeysWithValues: commands[0].members.map { ($0.originalHeaderId, $0.sourceFolderPath) })
        #expect(bySource[h1.id] == "INBOX")
        #expect(bySource[h2.id] == "Projects")
    }
}
