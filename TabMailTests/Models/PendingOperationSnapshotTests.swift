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
        // Durable message actions hold canonical RFC identity while provider
        // sync rows still expose a transient transport ID.
        #expect(set.containsAnyKey(messageId: "12345", rfc822MessageId: "abc@example.com"))
        #expect(set.containsAnyKey(messageId: "provider-token", rfc822MessageId: " <abc@example.com> "))
        #expect(!set.containsAnyKey(messageId: "12345", rfc822MessageId: "other@example.com"))
        #expect(!set.containsAnyKey(messageId: "12345", rfc822MessageId: "opaque-provider-token"))
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

    @Test("Snapshot excludes local action-tag rows from provider field protection")
    func snapshot_fieldClasses() {
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
        #expect(s.read == ["a", "b"])
        #expect(s.flagged == ["c", "d"])
        #expect(s.flag == ["a", "b", "c", "d"])
        #expect(!s.flag.contains("g"))
    }

    @Test("Snapshot destructive memberships are exact account-scoped source and destination rows")
    func snapshot_destructiveMembershipScope() {
        let first = PendingOperation(
            type: .move,
            messageIds: ["same-provider-id"],
            accountId: "acc1",
            folderPath: "Folder_A",
            destinationPath: "Folder_B"
        )
        let second = PendingOperation(
            type: .move,
            messageIds: ["same-provider-id"],
            accountId: "acc2",
            folderPath: "Folder_A",
            destinationPath: "Folder_C"
        )
        let sourceOnly = PendingOperation(
            type: .delete,
            messageIds: ["delete-id"],
            accountId: "acc1",
            folderPath: "Folder_D"
        )

        let snapshot = PendingOperationSnapshot(ops: [first, second, sourceOnly])
        #expect(snapshot.destructiveSourceMemberships == [
            MessageIdentity.membershipKey(
                accountId: "acc1", folderPath: "Folder_A", messageId: "same-provider-id",
                membership: .removedSource
            ),
            MessageIdentity.membershipKey(
                accountId: "acc2", folderPath: "Folder_A", messageId: "same-provider-id",
                membership: .removedSource
            ),
            MessageIdentity.membershipKey(
                accountId: "acc1", folderPath: "Folder_D", messageId: "delete-id",
                membership: .removedSource
            ),
        ])
        #expect(snapshot.destructiveDestinationMemberships == [
            MessageIdentity.membershipKey(
                accountId: "acc1", folderPath: "Folder_B", messageId: "same-provider-id",
                membership: .addedDestination
            ),
            MessageIdentity.membershipKey(
                accountId: "acc2", folderPath: "Folder_C", messageId: "same-provider-id",
                membership: .addedDestination
            ),
        ])
    }

    @Test("Snapshot membership keys cannot collide across colon boundaries")
    func snapshot_membershipKeysDisambiguateColonBoundaries() {
        let first = PendingOperation(
            type: .move,
            messageIds: ["B:C"],
            accountId: "account",
            folderPath: "A",
            destinationPath: "D"
        )
        let second = PendingOperation(
            type: .move,
            messageIds: ["C"],
            accountId: "account",
            folderPath: "A:B",
            destinationPath: "D:B"
        )

        let snapshot = PendingOperationSnapshot(ops: [first, second])
        #expect(snapshot.destructiveSourceMemberships.count == 2)
        #expect(snapshot.destructiveDestinationMemberships.count == 2)
        #expect(snapshot.destructiveSourceMemberships.contains(MessageIdentity.membershipKey(
            accountId: "account",
            folderPath: "A",
            messageId: "B:C",
            membership: .removedSource
        )))
        #expect(snapshot.destructiveSourceMemberships.contains(MessageIdentity.membershipKey(
            accountId: "account",
            folderPath: "A:B",
            messageId: "C",
            membership: .removedSource
        )))
        #expect(!snapshot.destructiveSourceMemberships.contains(MessageIdentity.membershipKey(
            accountId: "account",
            folderPath: "A",
            messageId: "C",
            membership: .removedSource
        )))
    }

    @Test("Snapshot merge unions every purpose-scoped protection set")
    func snapshot_mergeUnionsEverySet() {
        let before = PendingOperationSnapshot(ops: [
            PendingOperation(
                type: .move,
                messageIds: ["m1"],
                accountId: "acc1",
                folderPath: "Folder_A",
                destinationPath: "Folder_B"
            ),
            PendingOperation(
                type: .markRead,
                messageIds: ["read-1"],
                accountId: "acc1",
                folderPath: "Folder_A"
            ),
        ])
        let duringWrite = PendingOperationSnapshot(ops: [
            PendingOperation(
                type: .move,
                messageIds: ["m2"],
                accountId: "acc2",
                folderPath: "Folder_C",
                destinationPath: "Folder_D"
            ),
            PendingOperation(
                type: .markFlagged,
                messageIds: ["flagged-1"],
                accountId: "acc2",
                folderPath: "Folder_C"
            ),
            PendingOperation(
                type: .setTag,
                messageIds: ["tag-1"],
                accountId: "acc2",
                folderPath: "Folder_C",
                tagValue: ActionTag.reply.rawValue
            ),
        ])

        let merged = before.merging(duringWrite)
        #expect(merged.destructive == ["m1", "m2"])
        #expect(merged.destructiveSourceMemberships == [
            MessageIdentity.membershipKey(
                accountId: "acc1", folderPath: "Folder_A", messageId: "m1",
                membership: .removedSource
            ),
            MessageIdentity.membershipKey(
                accountId: "acc2", folderPath: "Folder_C", messageId: "m2",
                membership: .removedSource
            ),
        ])
        #expect(merged.destructiveDestinationMemberships == [
            MessageIdentity.membershipKey(
                accountId: "acc1", folderPath: "Folder_B", messageId: "m1",
                membership: .addedDestination
            ),
            MessageIdentity.membershipKey(
                accountId: "acc2", folderPath: "Folder_D", messageId: "m2",
                membership: .addedDestination
            ),
        ])
        #expect(merged.read == ["read-1"])
        #expect(merged.flagged == ["flagged-1"])
        #expect(merged.messageActions == ["m1", "read-1", "m2", "flagged-1"])
    }

    @Test("Snapshot keeps message-action RFC identities separate from draft resources")
    func snapshot_all() {
        let ops = [
            PendingOperation(type: .saveDraft,      messageIds: ["d1"], accountId: "acc1", folderPath: "Drafts"),
            PendingOperation(type: .deleteDraft,    messageIds: ["d2"], accountId: "acc1", folderPath: "Drafts"),
            PendingOperation(type: .archive,        messageIds: ["a1"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .markRead,       messageIds: ["m1"], accountId: "acc1", folderPath: "INBOX"),
            PendingOperation(type: .addUserLabel,   messageIds: ["u1"], accountId: "acc1", folderPath: "INBOX", userLabelId: "l1"),
        ]
        let s = PendingOperationSnapshot(ops: ops)
        #expect(s.messageActions == ["a1", "m1", "u1"])
        #expect(s.draftResources == ["d1", "d2"])
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

    // MARK: - Regression: IMAP move RFC identity

    @Test("IMAP move snapshot built from RFC identity matches numeric UID via RFC leg")
    func snapshot_imapMoveRfcIdentityRegression() {
        // Reproduces the original identity mismatch: an IMAP message has
        // numeric UID "8421" and a generic RFC id (stored bare). The pending
        // op carries stableId == rfc822. A naive `set.contains(info.messageId)`
        // check would miss this — only `containsAnyKey` catches both legs.
        let rfc822 = "message-id@example.com"
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
