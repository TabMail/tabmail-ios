/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageHeader")
struct MessageHeaderTests {

    @Test("stableId returns rfc822MessageId when present and messageId is numeric UID")
    func stableIdWithRfc822() {
        var header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<abc@example.com>"
        #expect(header.stableId == "<abc@example.com>")
    }

    @Test("stableId falls back to messageId when rfc822MessageId is nil")
    func stableIdFallback() {
        let header = MessageHeader(
            messageId: "msg-uuid-123",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.stableId == "msg-uuid-123")
    }

    @Test("id format is accountId:folderPath:messageId")
    func idFormat() {
        let header = MessageHeader(
            messageId: "42",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.id == "acc1:INBOX:42")
    }

    @Test("Default values are correct")
    func defaults() {
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        #expect(header.cc == "")
        #expect(header.bcc == "")
        #expect(header.isReplied == false)
        #expect(header.isForwarded == false)
        #expect(header.actionTag == nil)
        #expect(header.tagSortOrder == 99)
        #expect(header.summaryBlurb == nil)
        #expect(header.cachedReply == nil)
    }

    @Test("tagSortOrder reflects ActionTag.sortOrder")
    func tagSortOrder() {
        var header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.actionTag = .archive
        header.tagSortOrder = ActionTag.archive.sortOrder
        #expect(header.tagSortOrder == 2)
    }
}

@Suite("ActionTag Decoding")
struct ActionTagDecodingTests {

    @Test("Decodes plain raw values")
    func decodesPlainRawValues() throws {
        for tag in ActionTag.allCases {
            let json = "\"\(tag.rawValue)\""
            let data = json.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(ActionTag.self, from: data)
            #expect(decoded == tag)
        }
    }

    @Test("Decodes tm_ prefixed values for backward compatibility")
    func decodesTmPrefixed() throws {
        let json = "\"tm_archive\""
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActionTag.self, from: data)
        #expect(decoded == .archive)
    }

    @Test("Throws on invalid raw value")
    func throwsOnInvalid() {
        let json = "\"invalid_tag\""
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ActionTag.self, from: data)
        }
    }

    @Test("Throws on invalid tm_ prefixed value")
    func throwsOnInvalidTmPrefixed() {
        let json = "\"tm_bogus\""
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ActionTag.self, from: data)
        }
    }

    @Test("imapKeyword adds tm_ prefix")
    func imapKeyword() {
        #expect(ActionTag.archive.imapKeyword == "tm_archive")
        #expect(ActionTag.delete.imapKeyword == "tm_delete")
        #expect(ActionTag.reply.imapKeyword == "tm_reply")
        #expect(ActionTag.none.imapKeyword == "tm_none")
    }

    @Test("fromIMAPKeyword parses tm_ prefixed keywords")
    func fromIMAPKeyword() {
        #expect(ActionTag.fromIMAPKeyword("tm_archive") == .archive)
        #expect(ActionTag.fromIMAPKeyword("tm_delete") == .delete)
        #expect(ActionTag.fromIMAPKeyword("archive") == .archive)
        #expect(ActionTag.fromIMAPKeyword("unknown") == nil)
    }

    @Test("letter returns expected values")
    func letterValues() {
        #expect(ActionTag.reply.letter == "R")
        #expect(ActionTag.archive.letter == "A")
        #expect(ActionTag.delete.letter == "D")
        #expect(ActionTag.none.letter == nil)
    }

    @Test("displayName returns expected values")
    func displayNameValues() {
        #expect(ActionTag.reply.displayName == "Reply")
        #expect(ActionTag.none.displayName == "None")
        #expect(ActionTag.archive.displayName == "Archive")
        #expect(ActionTag.delete.displayName == "Delete")
    }
}
