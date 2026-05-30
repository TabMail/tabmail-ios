/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("FullMessageInfo")
struct FullMessageInfoTests {

    private static func makeHeader(messageId: String = "1", subject: String = "Test") -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: messageId,
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: subject,
            from: "alice@example.com",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
    }

    @Test("FullMessageInfo stores all components")
    func storesAllComponents() {
        let attachment = AttachmentInfo(
            filename: "doc.pdf",
            contentType: "application/pdf",
            section: "1.2",
            size: 1024,
            encoding: "base64"
        )
        let image = InlineImage(
            contentId: "img001@example.com",
            contentType: "image/png",
            data: Data("imagedata".utf8)
        )
        let fullMsg = FullMessageInfo(
            header: Self.makeHeader(),
            htmlBody: "<p>Hello</p>",
            textBody: "Hello",
            attachments: [attachment],
            inlineImages: [image]
        )
        #expect(fullMsg.header.messageId == "1")
        #expect(fullMsg.htmlBody == "<p>Hello</p>")
        #expect(fullMsg.textBody == "Hello")
        #expect(fullMsg.attachments.count == 1)
        #expect(fullMsg.inlineImages.count == 1)
    }

    @Test("FullMessageInfo with no attachments or images")
    func noAttachmentsOrImages() {
        let fullMsg = FullMessageInfo(
            header: Self.makeHeader(messageId: "2", subject: "Simple"),
            htmlBody: "<p>Simple</p>",
            textBody: nil,
            attachments: [],
            inlineImages: []
        )
        #expect(fullMsg.attachments.isEmpty)
        #expect(fullMsg.inlineImages.isEmpty)
        #expect(fullMsg.textBody == nil)
    }
}
