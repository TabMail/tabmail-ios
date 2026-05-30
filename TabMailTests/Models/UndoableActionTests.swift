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
