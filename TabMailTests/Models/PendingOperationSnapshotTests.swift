/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("PendingOperationSnapshot")
struct PendingOperationSnapshotTests {

    // MARK: - containsAnyKey

    @Test("containsAnyKey matches by messageId")
    func containsAnyKey_messageId() {
        let set: Set<String> = ["msg1", "msg2"]
        #expect(set.containsAnyKey(messageId: "msg1", rfc822MessageId: nil))
        #expect(set.containsAnyKey(messageId: "msg2", rfc822MessageId: "no-match"))
        #expect(!set.containsAnyKey(messageId: "msg3", rfc822MessageId: nil))
    }

    @Test("containsAnyKey matches by rfc822MessageId when messageId differs")
    func containsAnyKey_rfc822() {
        let set: Set<String> = ["abc@example.com"]
        // IMAP-style: PendingOperation.messageIds holds the rfc822 (stableId),
        // server returns numeric UID — only the rfc822 leg can match.
        #expect(set.containsAnyKey(messageId: "12345", rfc822MessageId: "abc@example.com"))
        #expect(!set.containsAnyKey(messageId: "12345", rfc822MessageId: "other@example.com"))
    }

    @Test("containsAnyKey ignores empty rfc822MessageId")
    func containsAnyKey_emptyRfc822() {
        let set: Set<String> = [""]
        // An empty rfc822 must not match an empty entry — protects against
        // accidental matches when both sides are blank.
        #expect(!set.containsAnyKey(messageId: "x", rfc822MessageId: ""))
        #expect(!set.containsAnyKey(messageId: "x", rfc822MessageId: nil))
    }

    @Test("containsAnyKey returns false on empty set")
    func containsAnyKey_emptySet() {
        let set: Set<String> = []
        #expect(!set.containsAnyKey(messageId: "x", rfc822MessageId: "y"))
    }

    // MARK: - Snapshot classification

    @Test("Snapshot classifies destructive ops")
    func snapshot_destructive() {
        let ops = [
            PendingOperation(type: .archive, messageIds: ["a"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .delete,  messageIds: ["b"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .move,    messageIds: ["c"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive"),
            PendingOperation(type: .markRead, messageIds: ["d"], accountId: "acc1", folderPath: "INBOX"),
        ]
        let s = PendingOperationSnapshot(ops: ops)
        #expect(s.destructive == ["a", "b", "c"])
        #expect(!s.destructive.contains("d"))
    }

    @Test("Snapshot classifies flag ops")
    func snapshot_flag() {
        let ops = [
            PendingOperation(type: .markRead,      messageIds: ["a"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .markUnread,    messageIds: ["b"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .markFlagged,   messageIds: ["c"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .markUnflagged, messageIds: ["d"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .setTag,        messageIds: ["e"], accountId: "acc1", folderPath: "INBOX", tagValue: "reply"),
            PendingOperation(type: .removeTag,     messageIds: ["f"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .archive,       messageIds: ["g"], accountId: "acc1", folderPath: "INBOX"),
        ]
        let s = PendingOperationSnapshot(ops: ops)
        #expect(s.flag == ["a", "b", "c", "d", "e", "f"])
        #expect(!s.flag.contains("g"))
    }

    @Test("Snapshot 'all' includes every op type")
    func snapshot_all() {
        let ops = [
            PendingOperation(type: .saveDraft,      messageIds: ["d1"], accountId: "acc1", folderPath: "Drafts"),
            PendingOperation(type: .archive,        messageIds: ["a1"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .markRead,       messageIds: ["m1"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .addUserLabel,   messageIds: ["u1"], accountId: "acc1", folderPath: "INBOX", userLabelId: "l1"),
        ]
        let s = PendingOperationSnapshot(ops: ops)
        #expect(s.all == ["d1", "a1", "m1", "u1"])
    }

    @Test("Snapshot loads only the requested account")
    func snapshot_accountScope() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com")
        try db.write { dbConn in
            try PendingOperation(type: .archive, messageIds: ["m1"], accountId: "acc1", folderPath: "INBOX").insert(dbConn)
            try PendingOperation(type: .archive, messageIds: ["m2"], accountId: "acc2", folderPath: "INBOX").insert(dbConn)
        }
        let snap = try db.read { dbConn in
            try PendingOperationSnapshot.load(accountId: "acc1", db: dbConn)
        }
        #expect(snap.destructive == ["m1"])
        #expect(!snap.destructive.contains("m2"))
    }

    // MARK: - Regression: IMAP move undo

    @Test("IMAP move regression: snapshot built from rfc822 stableId matches numeric UID via rfc822 leg")
    func snapshot_imapMoveRegression() {
        // Reproduces the original bug: the user archives an IMAP message with
        // numeric UID "8421" and rfc822 "<abc@imap>" (stored bare). The pending
        // op carries stableId == rfc822. A naive `set.contains(info.messageId)`
        // check would miss this — only `containsAnyKey` catches both legs.
        let rfc822 = "abc@imap"
        let op = PendingOperation(
            type: .archive,
            messageIds: [rfc822],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        let snap = PendingOperationSnapshot(ops: [op])

        // Simulating server-fresh delta: messageId is the UID, rfc822 matches.
        #expect(snap.destructive.containsAnyKey(messageId: "8421", rfc822MessageId: rfc822))

        // The legacy one-key check (the bug) would return false here.
        #expect(!snap.destructive.contains("8421"))
    }
}
