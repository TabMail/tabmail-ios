/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers the Microsoft Graph payload's threading, used by `sendMail` and by
/// draft create and update. Recipients thread on the RFC-2822 In-Reply-To /
/// References headers (no thread-id field on `sendMail`), so a populated
/// `references` chain is what keeps replies/forwards in-thread. Graph's
/// `internetMessageHeaders` takes only custom `x-` headers, so the two travel as
/// the MAPI properties Exchange writes those headers from. See the outgoing-thread
/// fix (ADR-IOS-043).
@Suite("ExchangeProvider.buildGraphSendPayload threading headers")
struct ExchangeSendPayloadTests {

    private func makeProvider() -> ExchangeProvider {
        ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
    }

    /// The value written for a threading header, read from the extended property
    /// Exchange writes that header from.
    private func header(_ name: String, in payload: [String: Any]) -> String? {
        let property = switch name {
        case "In-Reply-To": ExchangeProvider.graphInReplyToProperty
        case "References": ExchangeProvider.graphReferencesProperty
        default: name
        }
        let properties = payload["singleValueExtendedProperties"] as? [[String: String]] ?? []
        return properties.first { $0["id"] == property }?["value"]
    }

    /// Graph refuses a standard header in `internetMessageHeaders`; only names
    /// starting with `x-` are accepted there, so a reply, forward or reply draft
    /// carrying one would be refused.
    @Test("Every internetMessageHeaders name is a custom x- header")
    func internetMessageHeadersAreCustomOnly() {
        let drafts = [
            DraftMessage(to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
                         inReplyTo: "parent@example.com", references: ["root@example.com", "parent@example.com"]),
            DraftMessage(to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
                         references: ["root@example.com"]),
            DraftMessage(to: ["alice@example.com"], subject: "Hello", body: "Hi"),
        ]
        for draft in drafts {
            let payload = makeProvider().buildGraphSendPayload(draft: draft)
            let headers = payload["internetMessageHeaders"] as? [[String: String]] ?? []
            for name in headers.map({ $0["name"] ?? "" }) {
                #expect(name.lowercased().hasPrefix("x-"), "standard header \(name) in internetMessageHeaders")
            }
        }
    }

    @Test("Threading goes as PidTagInReplyToId and PidTagInternetReferences")
    func threadingPropertyIds() {
        #expect(ExchangeProvider.graphInReplyToProperty == "String 0x1042")
        #expect(ExchangeProvider.graphReferencesProperty == "String 0x1039")
    }

    @Test("Reply emits bracketed In-Reply-To + full References chain")
    func replyEmitsThreadingHeaders() {
        let draft = DraftMessage(
            to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
            inReplyTo: "parent@example.com", references: ["root@example.com", "parent@example.com"]
        )
        let payload = makeProvider().buildGraphSendPayload(draft: draft)
        #expect(header("In-Reply-To", in: payload) == "<parent@example.com>")
        #expect(header("References", in: payload) == "<root@example.com> <parent@example.com>")
    }

    @Test("New compose emits no threading")
    func newComposeNoThreadingHeaders() {
        let draft = DraftMessage(to: ["alice@example.com"], subject: "Hello", body: "Hi")
        let payload = makeProvider().buildGraphSendPayload(draft: draft)
        #expect(payload["singleValueExtendedProperties"] == nil)
        #expect(payload["internetMessageHeaders"] == nil)
    }

    @Test("References present without In-Reply-To still emits the References header")
    func referencesOnly() {
        let draft = DraftMessage(
            to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
            references: ["root@example.com"]
        )
        let payload = makeProvider().buildGraphSendPayload(draft: draft)
        #expect(header("References", in: payload) == "<root@example.com>")
        #expect(header("In-Reply-To", in: payload) == nil)
    }

    @Test("Graph subject remains semantic text at its JSON boundary")
    func graphSubjectRemainsSemanticText() {
        let subject = "Re: =?UTF-8?B?SGVsbG8=?= explained"
        let draft = DraftMessage(to: ["alice@example.com"], subject: subject, body: "Hi")
        let payload = makeProvider().buildGraphSendPayload(draft: draft)
        #expect(payload["subject"] as? String == subject)
    }
}
