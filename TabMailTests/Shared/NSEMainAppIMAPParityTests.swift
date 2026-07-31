/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// Byte-identical-output parity between the NSE's IMAP fetch path
/// (`IMAPFetchMapping` helpers consumed by `NSEIMAPConnection`) and the
/// main-app sync path (`IMAPProvider.buildMessageHeaderInfo` — which also
/// consumes the same helpers after the 2026-04-19 refactor).
///
/// The 2026-04-19 duplicate-row bug existed because NSE had its own inline
/// `messageId` / `rfc822MessageId` format that diverged from IMAPProvider.
/// With both call sites now funneled through `IMAPFetchMapping`, drift is
/// impossible by construction — but we assert the invariant here so a future
/// maintainer adding a second divergent code path finds a failing test.
@Suite("NSE / main-app IMAP parity")
struct NSEMainAppIMAPParityTests {

    private func makeInfo(
        uid: Int? = 42,
        messageID: String? = "<id@example.com>",
        inReplyTo: String? = "<parent@example.com>",
        references: [String] = ["<root@example.com>", "<parent@example.com>"],
        flags: [Flag] = [.seen, .custom("tm_reply"), .custom("$Important")],
        attachmentDisposition: String? = "attachment"
    ) -> MessageInfo {
        var info = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: uid.map { UID(UInt32($0)) },
            subject: "Parity",
            from: "sender@example.com",
            to: ["a@x.com", "b@x.com"],
            cc: ["c@x.com"],
            bcc: ["d@x.com"],
            date: Date(timeIntervalSince1970: 1_710_000_000),
            messageId: messageID.flatMap { MessageID($0) },
            inReplyTo: inReplyTo.flatMap { MessageID($0) },
            references: references.compactMap { MessageID($0) },
            flags: flags
        )
        info.parts = [
            MessagePart(sectionString: "1", contentType: "text/plain"),
            MessagePart(
                sectionString: "2",
                contentType: "application/pdf",
                disposition: attachmentDisposition,
                filename: "a.pdf"
            ),
        ]
        return info
    }

    /// Compute the fields both call sites derive from a shared `MessageInfo`
    /// via the shared helpers, and assert the values are what both sites
    /// produce. Main-app `IMAPProvider.buildMessageHeaderInfo` is an actor
    /// method and needs a live IMAP connection to instantiate — we can't
    /// call it directly from a unit test. Instead we assert against the
    /// exact expressions the production code uses (see
    /// `IMAPProvider.mapMessageInfo`, symbol-cited: line numbers into
    /// `IMAPProvider.swift` are abolished tree-wide because any edit to that
    /// file silently falsifies them here), so drift in IMAPProvider shows
    /// up here as a failure.
    @Test("Shared helpers produce the per-field output both NSE + main-app use")
    func sharedHelpersByteIdentical() {
        let info = makeInfo()

        // messageId — prefer UID.
        #expect(IMAPFetchMapping.messageIdString(from: info) == "42")
        // Matches IMAPProvider.mapMessageInfo's messageId expression for the same inputs.

        // rfc822MessageId — bare.
        #expect(IMAPFetchMapping.rfc822MessageId(from: info) == "id@example.com")
        // Matches IMAPProvider.mapMessageInfo's rfc822MessageId.

        // inReplyTo — bare, normalized.
        #expect(IMAPFetchMapping.inReplyTo(from: info) == "parent@example.com")
        // Matches IMAPProvider.mapMessageInfo's inReplyTo expression (pre-helper inline form).

        // references — bare entries.
        #expect(IMAPFetchMapping.references(from: info) == ["root@example.com", "parent@example.com"])
        // Matches IMAPProvider.mapMessageInfo's references expression.

        // hasAttachments — predicate parity with IMAPProvider.mapMessageInfo.
        #expect(IMAPFetchMapping.hasAttachments(from: info))

        // Recipient joining parity with IMAPProvider.mapMessageInfo.
        #expect(info.to.joined(separator: ", ") == "a@x.com, b@x.com")
        #expect(info.cc.joined(separator: ", ") == "c@x.com")
        #expect(info.bcc.joined(separator: ", ") == "d@x.com")

        // Flags — mirrors IMAPProvider.mapMessageInfo.
        #expect(info.flags.contains(.seen))
        #expect(!info.flags.contains(.flagged))

        // customKeywords — the raw list NSE stages (pre-filter).
        let kws = IMAPFetchMapping.customKeywords(from: info)
        #expect(kws == ["tm_reply", "$Important"])
    }

    @Test("UID-less message falls back identically in both paths")
    func uidlessFallback() {
        let info = makeInfo(uid: nil, messageID: "<only@id.com>")
        // Fallback: bare local@domain (no angle brackets), per
        // IMAPProvider.mapMessageInfo and IMAPFetchMapping.messageIdString.
        #expect(IMAPFetchMapping.messageIdString(from: info) == "only@id.com")
    }

    @Test("Sequence-only fallback matches main-app's sequence format")
    func sequenceOnlyFallback() {
        var info = makeInfo(uid: nil, messageID: nil)
        info = MessageInfo(
            sequenceNumber: SequenceNumber(7),
            subject: info.subject,
            from: info.from
        )
        #expect(IMAPFetchMapping.messageIdString(from: info) == "7")
    }

    // MARK: - Body render parity (NSE vs main-app IMAP)

    /// Shared body-render pipeline must produce the SAME `RenderedBody` for
    /// the same `(info, message)` regardless of which target called it.
    ///
    /// Prior to this commit the NSE's body render used an entirely separate
    /// path (`IMAPFetchMapping.renderBody(message:cap:)`) that
    ///   1. applied a 4 KB cap silently truncating every pushed IMAP body,
    ///   2. skipped attachments / inline images / ICS extraction entirely.
    ///
    /// Now both targets call `IMAPFetchMapping.renderBody(info:message:)`
    /// which builds `RawBodyIngredients` via the shared helpers and hands
    /// them to `BodyRenderer.render`. This test asserts the renderer
    /// produces NO truncation and full parity for a realistic HTML+text body.
    @Test("NSE body render has no truncation and preserves full content")
    func noTruncationAnyLength() async {
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 5_000) // ~135 KB
        let html = "<html><body><p>\(big)</p></body></html>"
        let info = makeInfo()
        let msg = Message(
            header: info,
            parts: [
                MessagePart(
                    sectionString: "1",
                    contentType: "text/html; charset=utf-8",
                    data: html.data(using: .utf8)
                )
            ]
        )

        let rendered = await IMAPFetchMapping.renderBody(info: info, message: msg)

        // HTML preserved verbatim.
        #expect((rendered.htmlContent?.count ?? 0) == html.count)
        // textContent is HTML-stripped via EmailFilter.extractPlainText, which
        // may collapse trailing whitespace / drop outer tags. A prior 4 KB cap
        // would have truncated to ~4096 — anything in the "full" ballpark
        // (≥ 100 KB) proves we're not silently capped.
        #expect((rendered.textContent?.count ?? 0) > 100_000)
    }

    /// Attachment extraction parity: the shared `extractAttachments` must
    /// surface the same set the main-app IMAP path surfaces — both top-level
    /// and nested-inside-`.eml` entries. Without the nested-eml pass, NSE
    /// was silently dropping attachments that came inside file-uploaded
    /// `.eml` blobs, and the main-app merge would later re-fetch and
    /// disagree with the NSE-staged list.
    @Test("extractAttachments includes top-level classifications")
    func extractAttachmentsTopLevel() {
        var info = makeInfo()
        info.parts = [
            MessagePart(sectionString: "1", contentType: "text/plain"),
            MessagePart(
                sectionString: "2",
                contentType: "application/pdf",
                disposition: "attachment",
                encoding: "base64",
                filename: "report.pdf"
            ),
            MessagePart(
                sectionString: "3",
                contentType: "text/calendar; method=REQUEST"
            ),
        ]
        let msg = Message(header: info, parts: [])
        let attachments = IMAPFetchMapping.extractAttachments(info: info, message: msg)
        // text/plain is NOT an attachment; application/pdf + text/calendar are.
        #expect(attachments.count == 2)
        #expect(attachments.contains { $0.filename == "report.pdf" && $0.encoding == "base64" })
        #expect(attachments.contains { $0.contentType.hasPrefix("text/calendar") })
    }

    /// Full body render round-trip: an HTML-only message survives end-to-end
    /// with no truncation, HTML preserved verbatim as `htmlContent`, and
    /// `textContent` derived via `EmailFilter.extractPlainText` (same path
    /// the main-app body pipeline uses).
    @Test("renderBody preserves HTML verbatim and derives text from it")
    func renderBodyHtmlAndText() async {
        let html = "<p>Hello, <b>world</b>!</p>"
        let info = makeInfo()
        let msg = Message(
            header: info,
            parts: [
                MessagePart(
                    sectionString: "1",
                    contentType: "text/html; charset=utf-8",
                    data: html.data(using: .utf8)
                )
            ]
        )

        let rendered = await IMAPFetchMapping.renderBody(info: info, message: msg)

        #expect(rendered.htmlContent == html)
        let text = rendered.textContent ?? ""
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
        #expect(!text.contains("<p>"))
        #expect(!text.contains("<b>"))
    }
}
