/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers the Gmail `users.messages.send` request body — specifically that a
/// reply/forward carries `threadId` (so Gmail files it into the source
/// conversation) and that a plain compose does not. See PLAN_THREAD_FIX.md /
/// ADR-IOS-043.
@Suite("GmailProvider.buildSendBody")
struct GmailSendBodyTests {

    private func makeProvider() -> GmailProvider {
        GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
    }

    /// Decode Gmail's URL-safe, unpadded base64 `raw` back into the MIME string.
    private func decodeRaw(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Reply with a threadId puts it in the send body alongside raw")
    func replyIncludesThreadId() {
        let draft = DraftMessage(
            to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
            inReplyTo: "parent@example.com", references: ["root@example.com", "parent@example.com"],
            threadId: "gmail-thread-xyz"
        )
        let body = makeProvider().buildSendBody(draft: draft)
        #expect(body["threadId"] as? String == "gmail-thread-xyz")
        #expect(body["raw"] as? String != nil)
    }

    @Test("Forward with a threadId also carries it (forward threads like reply)")
    func forwardIncludesThreadId() {
        let draft = DraftMessage(
            to: ["bob@example.com"], subject: "Fwd: Hello", body: "FYI",
            inReplyTo: "parent@example.com", references: ["parent@example.com"],
            threadId: "gmail-thread-xyz"
        )
        let body = makeProvider().buildSendBody(draft: draft)
        #expect(body["threadId"] as? String == "gmail-thread-xyz")
    }

    @Test("New compose (no threadId) omits the threadId key entirely")
    func newComposeOmitsThreadId() {
        let draft = DraftMessage(to: ["alice@example.com"], subject: "Hello", body: "Hi")
        let body = makeProvider().buildSendBody(draft: draft)
        #expect(body["threadId"] == nil)
        #expect(body.keys.contains("threadId") == false)
        #expect(body["raw"] as? String != nil)
    }

    @Test("Empty threadId is treated as absent (no key)")
    func emptyThreadIdOmitted() {
        let draft = DraftMessage(
            to: ["alice@example.com"], subject: "Re: Hello", body: "Hi",
            inReplyTo: "parent@example.com", threadId: ""
        )
        let body = makeProvider().buildSendBody(draft: draft)
        #expect(body.keys.contains("threadId") == false)
    }

    @Test("raw is URL-safe base64 (no +, /, or = padding)")
    func rawIsUrlSafeBase64() {
        let draft = DraftMessage(to: ["a@example.com"], subject: "Hi", body: "Body", threadId: "t-1")
        let raw = makeProvider().buildSendBody(draft: draft)["raw"] as? String ?? ""
        #expect(!raw.isEmpty)
        #expect(!raw.contains("+"))
        #expect(!raw.contains("/"))
        #expect(!raw.contains("="))
    }

    @Test("Reply raw MIME carries the In-Reply-To + References headers end-to-end")
    func replyRawCarriesThreadingHeaders() {
        let draft = DraftMessage(
            to: ["alice@example.com"], subject: "Re: Hello", body: "Sure",
            inReplyTo: "parent@example.com", references: ["root@example.com", "parent@example.com"],
            threadId: "gmail-thread-xyz"
        )
        let raw = makeProvider().buildSendBody(draft: draft)["raw"] as? String ?? ""
        let mime = decodeRaw(raw)
        #expect(mime.contains("In-Reply-To: <parent@example.com>"))
        #expect(mime.contains("References: <root@example.com> <parent@example.com>"))
    }
}
