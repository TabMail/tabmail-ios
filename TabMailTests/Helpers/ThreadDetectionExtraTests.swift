/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ThreadDetection.excludeCopies")
struct ThreadDetectionExcludeCopiesTests {

    private func makeHeader(
        messageId: String,
        rfc822MessageId: String? = nil,
        accountId: String = "acc1",
        folderPath: String = "INBOX"
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "\(accountId):\(folderPath)",
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        h.rfc822MessageId = rfc822MessageId
        return h
    }

    @Test("Returns empty array when given empty results")
    func emptyResults() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let result = ThreadDetection.excludeCopies([], of: msg)
        #expect(result.isEmpty)
    }

    @Test("Excludes copies of the viewed message in other folders")
    func excludesCopyOfViewedMessage() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>", folderPath: "INBOX")
        let copy = makeHeader(messageId: "99", rfc822MessageId: "<msg1@example.com>", folderPath: "Sent")
        let result = ThreadDetection.excludeCopies([copy], of: msg)
        #expect(result.isEmpty)
    }

    @Test("Keeps messages with different rfc822MessageId")
    func keepsDifferentMessages() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let other = makeHeader(messageId: "2", rfc822MessageId: "<msg2@example.com>")
        let result = ThreadDetection.excludeCopies([other], of: msg)
        #expect(result.count == 1)
    }

    @Test("Deduplicates thread messages with same rfc822MessageId across folders")
    func deduplicatesAcrossFolders() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let inboxCopy = makeHeader(messageId: "10", rfc822MessageId: "<reply@example.com>", folderPath: "INBOX")
        let sentCopy = makeHeader(messageId: "20", rfc822MessageId: "<reply@example.com>", folderPath: "Sent")
        let result = ThreadDetection.excludeCopies([inboxCopy, sentCopy], of: msg)
        #expect(result.count == 1)
        // First one wins
        #expect(result[0].messageId == "10")
    }

    @Test("Keeps messages without rfc822MessageId (no dedup possible)")
    func keepsMessagesWithoutRfc822() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let noRfc1 = makeHeader(messageId: "2", rfc822MessageId: nil)
        let noRfc2 = makeHeader(messageId: "3", rfc822MessageId: nil)
        let result = ThreadDetection.excludeCopies([noRfc1, noRfc2], of: msg)
        #expect(result.count == 2)
    }

    @Test("Handles viewed message without rfc822MessageId")
    func viewedMessageWithoutRfc822() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: nil)
        let other = makeHeader(messageId: "2", rfc822MessageId: "<msg2@example.com>")
        let result = ThreadDetection.excludeCopies([other], of: msg)
        #expect(result.count == 1)
    }

    @Test("Handles viewed message with empty rfc822MessageId")
    func viewedMessageEmptyRfc822() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "")
        let other = makeHeader(messageId: "2", rfc822MessageId: "<msg2@example.com>")
        let result = ThreadDetection.excludeCopies([other], of: msg)
        #expect(result.count == 1)
    }

    @Test("Skips dedup for result with empty rfc822MessageId")
    func resultWithEmptyRfc822Kept() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let emptyRfc = makeHeader(messageId: "2", rfc822MessageId: "")
        let emptyRfc2 = makeHeader(messageId: "3", rfc822MessageId: "")
        let result = ThreadDetection.excludeCopies([emptyRfc, emptyRfc2], of: msg)
        // Empty string rfc822 is treated as "no rfc822" — both should be kept
        #expect(result.count == 2)
    }

    @Test("Multiple unique messages all kept")
    func multipleUniqueMessagesKept() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        let results = (2...5).map { i in
            makeHeader(messageId: "\(i)", rfc822MessageId: "<msg\(i)@example.com>")
        }
        let filtered = ThreadDetection.excludeCopies(results, of: msg)
        #expect(filtered.count == 4)
    }

    @Test("First occurrence wins in dedup order")
    func firstOccurrenceWins() {
        let msg = makeHeader(messageId: "1", rfc822MessageId: "<msg1@example.com>")
        var first = makeHeader(messageId: "A", rfc822MessageId: "<dup@example.com>", folderPath: "INBOX")
        first.from = "First"
        var second = makeHeader(messageId: "B", rfc822MessageId: "<dup@example.com>", folderPath: "Sent")
        second.from = "Second"
        let result = ThreadDetection.excludeCopies([first, second], of: msg)
        #expect(result.count == 1)
        #expect(result[0].from == "First")
    }
}
