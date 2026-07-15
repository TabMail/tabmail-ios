/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

// MARK: - MessageHeader.stableId legacy characterization (non-queue)

/// `stableId` remains in use by non-queue local keys. Durable message actions
/// use canonical RFC Message-ID directly and are covered by their admission and
/// provider-resolution suites instead.
@Suite("MessageHeader.stableId — legacy mixed helper outside the durable queue")
struct MessageHeaderStableIdTests {

    @Test("stableId returns rfc822MessageId for numeric UIDs")
    func stableIdReturnsRfc822ForNumericUid() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(
            db,
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            accountId: "acc1"
        )

        let msg = try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            rfc822MessageId: "<stable@example.com>"
        )
        #expect(
            msg.stableId == "<stable@example.com>",
            "stableId should prefer rfc822MessageId for numeric UIDs"
        )
    }

    @Test("stableId returns messageId for non-numeric IDs (Gmail)")
    func stableIdReturnsMessageIdForGmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(
            db,
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            accountId: "acc1"
        )

        let msg = try TestDatabase.insertMessageHeader(
            db,
            messageId: "gmail-stable-id",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            rfc822MessageId: "<msg@example.com>"
        )
        #expect(
            msg.stableId == "gmail-stable-id",
            "stableId should return messageId for non-numeric IDs"
        )
    }
}
