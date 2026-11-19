/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("UndoableAction Label Formatting")
struct UndoableActionLabelTests {

    private func makeHeader(messageId: String = "msg1") -> MessageHeader {
        MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "Alice",
            fromAddress: "alice@test.com",
            to: "bob@test.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
    }

    @Test("Move label singular")
    func moveLabelSingular() {
        let action = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [makeHeader()],
            originalFolderId: "acc1:INBOX",
            originalFolderPath: "INBOX",
            accountId: "acc1",
            timestamp: Date()
        )
        #expect(action.label == "Moved 1 message")
    }

    @Test("Move label plural")
    func moveLabelPlural() {
        let action = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [makeHeader(messageId: "m1"), makeHeader(messageId: "m2"), makeHeader(messageId: "m3")],
            originalFolderId: "acc1:INBOX",
            originalFolderPath: "INBOX",
            accountId: "acc1",
            timestamp: Date()
        )
        #expect(action.label == "Moved 3 messages")
    }

}

/// The shared by-account move (`UndoableAction.byAccount`, `UndoableAction.move`), used by the chat's
/// and the inbox's whole-thread Archive, Delete and Move: each account's emails go to that account's
/// folder, and the whole move is one undo entry that puts each email back from its own folder.
@Suite("UndoableAction by-account move")
struct UndoableActionAccountMoveTests {

    private func header(_ uid: String, account: String, folder: String) -> MessageHeader {
        MessageHeader(
            messageId: uid, subject: "Test", from: "Alice", fromAddress: "alice@example.com",
            to: "bob@example.com", date: Date(), snippet: "",
            folderId: "\(account):\(folder)", accountId: account, folderPath: folder,
            isInInbox: folder == "INBOX")
    }

    @Test("Emails group by account in the order the accounts first appear, each email once")
    func byAccountKeepsOrderAndDropsRepeats() {
        let a1 = header("1", account: "acc1", folder: "INBOX")
        let b1 = header("2", account: "acc2", folder: "INBOX")
        let a2 = header("3", account: "acc1", folder: "Projects")
        let groups = UndoableAction.byAccount([a1, b1, a2, a1, b1])
        #expect(groups.map { $0.map(\.id) } == [[a1.id, a2.id], [b1.id]])
    }

    @Test("One undo entry; each source folder gets a command naming its account's destination")
    func oneEntryEachEmailBackFromItsOwnFolder() throws {
        let a1 = header("1", account: "acc1", folder: "INBOX")
        let a2 = header("3", account: "acc1", folder: "Projects")
        let b1 = header("2", account: "acc2", folder: "INBOX")
        let undo = try #require(UndoableAction.move([
            .init(messages: [a1, a2], toPath: "Archive"),
            .init(messages: [b1], toPath: "[Gmail]/All Mail"),
        ]))
        #expect(undo.messages.map(\.id) == [a1.id, a2.id, b1.id])
        let commands = undo.commands.map { ($0.accountId, $0.forwardDestinationPath, $0.members.map(\.sourceFolderPath)) }
        #expect(commands.count == 3)
        guard commands.count == 3 else { return }
        #expect(commands[0] == ("acc1", "Archive", ["INBOX"]))
        #expect(commands[1] == ("acc1", "Archive", ["Projects"]))
        #expect(commands[2] == ("acc2", "[Gmail]/All Mail", ["INBOX"]))
    }

    @Test("A move with no emails records nothing")
    func emptyMoveIsNil() {
        #expect(UndoableAction.move([]) == nil)
        #expect(UndoableAction.move([.init(messages: [], toPath: "Archive")]) == nil)
    }
}
