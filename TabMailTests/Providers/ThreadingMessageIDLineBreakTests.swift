/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// In-Reply-To and References carry message IDs taken from incoming mail. An ID
/// holding a line break is left out on every send and draft path, so it can
/// neither start a header field of its own nor make SwiftMail refuse an IMAP
/// send (which would keep the reply queued).
@Suite("Threading message IDs with a line break")
struct ThreadingMessageIDLineBreakTests {
    /// The threading fields one writer produced, and the text they were written into.
    struct Written {
        let inReplyTo: [String]
        let references: [String]
        let text: String
    }

    private static func headerFields(_ name: String, in message: String) -> [String] {
        (message.components(separatedBy: "\r\n\r\n").first ?? message)
            .components(separatedBy: "\r\n")
            .filter { $0.hasPrefix(name + ": ") }
            .map { String($0.dropFirst(name.count + 2)) }
    }

    private static func fromText(_ message: String) -> Written {
        Written(inReplyTo: headerFields("In-Reply-To", in: message),
                references: headerFields("References", in: message), text: message)
    }

    /// Every writer of threading fields, keyed by name.
    private static func written(_ draft: DraftMessage) throws -> [String: Written] {
        let gmail = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        let exchange = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        var withAttachment = draft
        withAttachment.attachments = [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))]

        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@example.com")
        let headers = email.additionalHeaders ?? [:]
        let graphHeaders = (exchange.buildGraphSendPayload(draft: draft)["internetMessageHeaders"]
            as? [[String: String]]) ?? []
        func graph(_ name: String) -> [String] { graphHeaders.filter { $0["name"] == name }.compactMap { $0["value"] } }

        return [
            "IMAP send": Written(
                inReplyTo: headers["In-Reply-To"].map { [$0] } ?? [],
                references: headers["References"].map { [$0] } ?? [],
                text: headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")),
            "Gmail buildRFC822": fromText(gmail.buildRFC822(draft: draft)),
            "Gmail buildMIMEMessage": fromText(String(decoding: gmail.buildMIMEMessage(draft: withAttachment), as: UTF8.self)),
            "Outlook": Written(
                inReplyTo: graph("In-Reply-To"), references: graph("References"),
                text: graphHeaders.map { "\($0["name"] ?? ""): \($0["value"] ?? "")" }.joined(separator: "\r\n"))
        ]
    }

    private static func draft(inReplyTo: String, references: [String]) -> DraftMessage {
        DraftMessage(to: ["to@example.com"], subject: "Re: Hello", body: "Body",
                     inReplyTo: inReplyTo, references: references)
    }

    @Test("A message ID with a line break is left out of In-Reply-To and References on every writer",
          arguments: ["\r\n", "\n", "\r", "\u{2028}"])
    func lineBreakIDIsLeftOut(lineBreak: String) throws {
        let hostile = "<mid@example.com>\(lineBreak)X-Injected: yes"
        let all = try Self.written(Self.draft(
            inReplyTo: hostile, references: ["root@example.com", hostile, "<last@example.com>"]))

        #expect(all.count == 4)
        for (writer, written) in all {
            #expect(written.inReplyTo.isEmpty, "\(writer)")
            #expect(written.references == ["<root@example.com> <last@example.com>"], "\(writer)")
            #expect(!written.text.contains("X-Injected"), "\(writer)")
        }
    }

    @Test("Message IDs without a line break are written on every writer")
    func ordinaryIDsAreWritten() throws {
        let all = try Self.written(Self.draft(
            inReplyTo: "parent@example.com", references: ["root@example.com", "<parent@example.com>"]))

        #expect(all.count == 4)
        for (writer, written) in all {
            #expect(written.inReplyTo == ["<parent@example.com>"], "\(writer)")
            #expect(written.references == ["<root@example.com> <parent@example.com>"], "\(writer)")
        }
    }
}
