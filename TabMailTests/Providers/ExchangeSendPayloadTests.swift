/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers the Microsoft Graph `sendMail` payload threading headers. Exchange
/// threads purely via the RFC-2822 In-Reply-To / References internet headers
/// (no thread-id field on `sendMail`), so a populated `references` chain is what
/// keeps replies/forwards in-thread on Outlook. See PLAN_THREAD_FIX.md / ADR-IOS-043.
@Suite("ExchangeProvider.buildGraphSendPayload threading headers")
struct ExchangeSendPayloadTests {

    private func makeProvider() -> ExchangeProvider {
        ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
    }

    /// Find an internetMessageHeaders entry by header name.
    private func header(_ name: String, in payload: [String: Any]) -> String? {
        let headers = payload["internetMessageHeaders"] as? [[String: String]] ?? []
        return headers.first { $0["name"] == name }?["value"]
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

    @Test("New compose emits no internetMessageHeaders")
    func newComposeNoThreadingHeaders() {
        let draft = DraftMessage(to: ["alice@example.com"], subject: "Hello", body: "Hi")
        let payload = makeProvider().buildGraphSendPayload(draft: draft)
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
