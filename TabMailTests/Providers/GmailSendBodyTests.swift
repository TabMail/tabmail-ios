/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers the Gmail `users.messages.send` request body — specifically that a
/// reply/forward carries `threadId` (so Gmail files it into the source
/// conversation) and that a plain compose does not. See the outgoing-thread fix (ADR-IOS-043) /
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

    /// A forward carries the original only in References, no In-Reply-To
    /// (#1483); with its threadId and "Fwd:" subject Gmail files it in the
    /// original's conversation (checked live on a Workspace account, 2026-11-25).
    @Test("Forward with a threadId also carries it (forward threads like reply), and its raw has References but no In-Reply-To")
    func forwardIncludesThreadId() {
        let draft = DraftMessage(
            to: ["bob@example.com"], subject: "Fwd: Hello", body: "FYI",
            references: ["parent@example.com"],
            threadId: "gmail-thread-xyz"
        )
        let body = makeProvider().buildSendBody(draft: draft)
        #expect(body["threadId"] as? String == "gmail-thread-xyz")
        let mime = decodeRaw(body["raw"] as? String ?? "")
        #expect(mime.contains("References: <parent@example.com>"))
        #expect(!mime.contains("In-Reply-To:"))
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

/// `users.messages.send` answers with the Message resource Gmail stores in
/// Sent. Its `id` (and `threadId`) is the copy's identity: Gmail replaces the
/// Message-ID the send wrote, so that id is the only key the Sent listing and
/// the local row share.
@Suite("GmailProvider.send names the Sent copy")
struct GmailSentCopyIdentityTests {

    private static func parse(_ json: String) -> SentCopyIdentity? {
        GmailProvider.sentCopyIdentity(fromSendResponse: Data(json.utf8))
    }

    @Test("the send answer's id and threadId are the Sent copy's identity")
    func fullAnswer() {
        let identity = Self.parse(#"{"id":"msg-1","threadId":"thread-1","labelIds":["SENT"]}"#)
        #expect(identity == SentCopyIdentity(providerMessageId: "msg-1", threadId: "thread-1"))
    }

    @Test("an answer with an id but no usable threadId still names the copy",
          arguments: [#"{"id":"msg-1"}"#, #"{"id":"msg-1","threadId":""}"#, #"{"id":"msg-1","threadId":7}"#])
    func idWithoutThread(json: String) {
        #expect(Self.parse(json) == SentCopyIdentity(providerMessageId: "msg-1", threadId: nil))
    }

    @Test("an answer that names no id names no copy",
          arguments: [#"{"threadId":"thread-1"}"#, #"{"id":"","threadId":"thread-1"}"#,
                      #"{"id":42}"#, #"[]"#, "", "not json"])
    func noId(json: String) {
        #expect(Self.parse(json) == nil)
    }

    @Test("send returns the identity Gmail's answer names")
    func sendReturnsTheAnswer() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(
            path: "/messages/send", method: "POST",
            response: .json(raw: #"{"id":"msg-sent","threadId":"thread-sent","labelIds":["SENT"]}"#))
        let provider = GmailProvider(userEmail: "sender@example.com", accessToken: { _ in "tok" }, session: http.session)
        let identity = try await provider.send(
            draft: DraftMessage(to: ["to@example.com"], subject: "Test", body: "Body text"))
        #expect(identity == SentCopyIdentity(providerMessageId: "msg-sent", threadId: "thread-sent"))
        #expect(http.recordedCalls().count == 1)
    }
}
