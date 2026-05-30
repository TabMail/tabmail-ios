/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageSnapshot.stableId")
struct MessageSnapshotStableIdTests {

    private func makeHeader(messageId: String, rfc822MessageId: String?) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "test@example.com",
            fromAddress: "test@example.com",
            to: "to@example.com",
            date: Date(),
            snippet: "",
            folderId: "acct1:INBOX",
            accountId: "acct1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId
        return header
    }

    @Test("stableId returns rfc822MessageId for IMAP messages (numeric messageId)")
    func stableIdIMAP() {
        let header = makeHeader(messageId: "12345", rfc822MessageId: "abc@example.com")
        let snapshot = MessageSnapshot(from: header)
        #expect(snapshot.stableId == "abc@example.com")
    }

    @Test("stableId returns messageId for Gmail/Exchange (non-numeric messageId)")
    func stableIdGmail() {
        let header = makeHeader(messageId: "gmail-thread-id-abc", rfc822MessageId: nil)
        let snapshot = MessageSnapshot(from: header)
        #expect(snapshot.stableId == "gmail-thread-id-abc")
    }

    @Test("stableId falls back to messageId when rfc822MessageId is nil")
    func stableIdFallbackNil() {
        let header = makeHeader(messageId: "42", rfc822MessageId: nil)
        let snapshot = MessageSnapshot(from: header)
        // Numeric messageId but no rfc822 — falls back to messageId
        #expect(snapshot.stableId == "42")
    }

    @Test("stableId falls back to messageId when rfc822MessageId is empty")
    func stableIdFallbackEmpty() {
        let header = makeHeader(messageId: "42", rfc822MessageId: "")
        let snapshot = MessageSnapshot(from: header)
        #expect(snapshot.stableId == "42")
    }
}
