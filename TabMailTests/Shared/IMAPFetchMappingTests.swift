/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// Regression tests for `IMAPFetchMapping` — the pure helpers the NSE's one-
/// shot IMAP fetch uses to turn SwiftMail's `MessageInfo` / `Message` values
/// into the canonical `NSEMessageMetadata` + `RenderedBody` shape.
///
/// These invariants killed a real user-visible bug on 2026-04-19 (iCloud NSE
/// push produced duplicate inbox entries with a garbled "w3" snippet and a
/// blank recipient). Each scenario below encodes one invariant of that fix.
@Suite("IMAPFetchMapping")
struct IMAPFetchMappingTests {

    // MARK: - Helpers

    private func makeInfo(
        uid: Int? = nil,
        sequence: Int = 1,
        messageID: String? = nil,
        subject: String = "Test"
    ) -> MessageInfo {
        MessageInfo(
            sequenceNumber: SequenceNumber(UInt32(sequence)),
            uid: uid.map { UID(UInt32($0)) },
            subject: subject,
            from: "sender@example.com",
            to: ["recipient@example.com"],
            date: Date(timeIntervalSince1970: 1_710_000_000),
            messageId: messageID.flatMap { MessageID($0) }
        )
    }

    private func makeMessage(
        uid: Int? = nil,
        messageID: String? = nil,
        parts: [MessagePart]
    ) -> Message {
        Message(header: makeInfo(uid: uid, messageID: messageID), parts: parts)
    }

    private func htmlPart(_ html: String) -> MessagePart {
        MessagePart(
            sectionString: "1",
            contentType: "text/html; charset=utf-8",
            data: html.data(using: .utf8)
        )
    }

    private func textPart(_ text: String) -> MessagePart {
        MessagePart(
            sectionString: "1",
            contentType: "text/plain; charset=utf-8",
            data: text.data(using: .utf8)
        )
    }

    // MARK: - messageIdString

    /// Sync's IMAPProvider uses UID as the canonical messageId. The NSE MUST
    /// match so the merge-side `WHERE messageId=?` lookup finds the row
    /// sync later inserts — otherwise the user sees two copies of every
    /// pushed message in the inbox.
    @Test("messageIdString prefers UID over rfc822 Message-ID")
    func messageIdPrefersUID() {
        let info = makeInfo(uid: 12345, messageID: "<abc@icloud.com>")
        #expect(IMAPFetchMapping.messageIdString(from: info) == "12345")
    }

    @Test("messageIdString falls back to bare local@domain when UID is missing")
    func messageIdFallsBackToRfc822Bare() {
        let info = makeInfo(uid: nil, messageID: "<abc@icloud.com>")
        // Bare form (no angle brackets) matches IMAPProvider.buildMessageHeaderInfo.
        #expect(IMAPFetchMapping.messageIdString(from: info) == "abc@icloud.com")
    }

    @Test("messageIdString falls back to sequence number when neither UID nor Message-ID present")
    func messageIdFallsBackToSequence() {
        let info = makeInfo(uid: nil, sequence: 42, messageID: nil)
        #expect(IMAPFetchMapping.messageIdString(from: info) == "42")
    }

    @Test("messageIdString output for UID+rfc822 matches IMAPProvider sync format")
    func messageIdMatchesIMAPProviderFormat() {
        // Mirror of IMAPProvider.buildMessageHeaderInfo:
        //   info.uid.map { "\($0.value)" } ?? info.messageId.map { "\(localPart)@\(domain)" } ?? "\(sequenceNumber.value)"
        // Any divergence here causes NSE-created headers to fail the merge
        // lookup and duplicate themselves on first sync.
        let uidOnly = makeInfo(uid: 7, messageID: nil)
        #expect(IMAPFetchMapping.messageIdString(from: uidOnly) == "7")

        let ridOnly = makeInfo(uid: nil, messageID: "<x@y.z>")
        #expect(IMAPFetchMapping.messageIdString(from: ridOnly) == "x@y.z")

        let both = makeInfo(uid: 9, messageID: "<x@y.z>")
        #expect(IMAPFetchMapping.messageIdString(from: both) == "9")
    }

    // MARK: - rfc822MessageId

    @Test("rfc822MessageId returns bare local@domain form")
    func rfc822Bare() {
        let info = makeInfo(messageID: "<abc@icloud.com>")
        #expect(IMAPFetchMapping.rfc822MessageId(from: info) == "abc@icloud.com")
    }

    @Test("rfc822MessageId is nil when Message-ID header absent")
    func rfc822NilWhenMissing() {
        let info = makeInfo(messageID: nil)
        #expect(IMAPFetchMapping.rfc822MessageId(from: info) == nil)
    }

    // MARK: - renderBody: HTML canon

    /// THIS is the "w3" regression. An HTML-only message must produce a
    /// textContent that is plain text stripped from the HTML — NEVER the
    /// raw HTML source. If this fails, snippet/FTS/MessageBody all get
    /// tag-soup (literally "<html xmlns=\"http://www.w3.org/1999/xhtml\">
    /// ...") as "plain text".
    @Test("renderBody strips HTML for textContent when only an HTML part exists")
    func htmlOnlyStripsForText() async {
        let html = """
        <!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml">\
        <head><title>t</title></head>\
        <body><p>Hello, <b>world</b>!</p></body></html>
        """
        let msg = makeMessage(parts: [htmlPart(html)])
        let rendered = await IMAPFetchMapping.renderBody(info: makeInfo(), message: msg)

        #expect(rendered.htmlContent == html)
        let text = rendered.textContent ?? ""
        #expect(!text.contains("<html"))
        #expect(!text.contains("xmlns"))
        #expect(!text.contains("w3.org"))
        #expect(!text.contains("<p>"))
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
    }

    /// Canon: HTML is the source of truth even when text/plain is present.
    /// Matches `EmailFilter.extractPlainText` — the main-app body pipeline
    /// always derives plain text from HTML when HTML exists, to avoid two
    /// parts diverging in ways that confuse search and summaries.
    @Test("renderBody derives text from HTML when both parts are present (HTML preferred)")
    func htmlPreferredOverTextPlain() async {
        // Intentionally-different text/plain content to prove the text arm
        // of MessageBody was produced from HTML, not by taking text/plain.
        let html = "<p>Hello <b>world</b></p>"
        let plain = "SOMETHING COMPLETELY DIFFERENT FROM HTML"
        let msg = makeMessage(parts: [htmlPart(html), textPart(plain)])

        let rendered = await IMAPFetchMapping.renderBody(info: makeInfo(), message: msg)

        #expect(rendered.htmlContent == html)
        let text = rendered.textContent ?? ""
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
        #expect(!text.contains("SOMETHING"))
    }

    @Test("renderBody converts text/plain to display HTML once; textContent stays verbatim")
    func textOnlyConvertedToDisplayHTML() async {
        // BodyRenderer is the single conversion authority: a text/plain-only message
        // now yields display-ready htmlContent (escaped + wrapped) while textContent
        // remains the verbatim plain text for snippet/FTS.
        let plain = "Just a plain email.\nMultiple lines."
        let msg = makeMessage(parts: [textPart(plain)])
        let rendered = await IMAPFetchMapping.renderBody(info: makeInfo(), message: msg)

        #expect(rendered.htmlContent?.contains("white-space:pre-wrap") == true)
        #expect(rendered.htmlContent?.contains("Just a plain email.") == true)
        #expect(rendered.htmlContent?.contains("Multiple lines.") == true)
        #expect(rendered.textContent == plain)
    }

    @Test("renderBody returns nil content fields when message has no body parts")
    func emptyBody() async {
        let msg = makeMessage(parts: [])
        let rendered = await IMAPFetchMapping.renderBody(info: makeInfo(), message: msg)

        #expect(rendered.htmlContent == nil)
        #expect(rendered.textContent == nil)
        #expect(rendered.hasUnresolvedCIDs == false)
        #expect(rendered.attachments.isEmpty)
    }

    /// Regression guard: the shared renderer must NEVER truncate. A prior
    /// NSE path applied a 4KB cap to both html and text payloads, writing
    /// short bodies as the canonical `MessageBody` for every pushed IMAP
    /// message. Full-length preservation is the invariant; NSE memory
    /// budget is handled by iOS process limits and graceful fallback to
    /// the default push payload, not by silent truncation.
    @Test("renderBody preserves full html and text payloads — no cap")
    func noTruncation() async {
        let big = String(repeating: "a", count: 50_000)
        let html = "<p>\(big)</p>"
        let msg = makeMessage(parts: [htmlPart(html)])

        let rendered = await IMAPFetchMapping.renderBody(info: makeInfo(), message: msg)

        #expect(rendered.htmlContent?.count == html.count)
        #expect((rendered.textContent?.count ?? 0) >= 50_000)
    }

    // MARK: - Full-header helpers (inReplyTo, references, hasAttachments, keywords)

    @Test("inReplyTo returns bare local@domain")
    func inReplyToBare() {
        var info = makeInfo()
        info.inReplyTo = MessageID("<parent@example.com>")
        #expect(IMAPFetchMapping.inReplyTo(from: info) == "parent@example.com")
    }

    @Test("inReplyTo is nil when header absent")
    func inReplyToNil() {
        let info = makeInfo()
        #expect(IMAPFetchMapping.inReplyTo(from: info) == nil)
    }

    @Test("references returns bare local@domain entries")
    func referencesBare() {
        var info = makeInfo()
        info.references = [
            MessageID("<a@x.com>"),
            MessageID("<b@y.com>"),
        ].compactMap { $0 }
        #expect(IMAPFetchMapping.references(from: info) == ["a@x.com", "b@y.com"])
    }

    @Test("references returns empty array when header absent")
    func referencesEmpty() {
        let info = makeInfo()
        #expect(IMAPFetchMapping.references(from: info).isEmpty)
    }

    @Test("hasAttachments true for explicit attachment disposition")
    func hasAttachmentsExplicit() {
        var info = makeInfo()
        info.parts = [
            MessagePart(sectionString: "1", contentType: "text/plain"),
            MessagePart(
                sectionString: "2",
                contentType: "application/pdf",
                disposition: "attachment",
                filename: "report.pdf"
            ),
        ]
        #expect(IMAPFetchMapping.hasAttachments(from: info))
    }

    @Test("hasAttachments true for text/calendar")
    func hasAttachmentsCalendar() {
        var info = makeInfo()
        info.parts = [
            MessagePart(sectionString: "1", contentType: "text/plain"),
            MessagePart(sectionString: "2", contentType: "text/calendar; method=REQUEST"),
        ]
        #expect(IMAPFetchMapping.hasAttachments(from: info))
    }

    @Test("hasAttachments false for plain-text-only message")
    func hasAttachmentsFalse() {
        var info = makeInfo()
        info.parts = [MessagePart(sectionString: "1", contentType: "text/plain")]
        #expect(!IMAPFetchMapping.hasAttachments(from: info))
    }

    @Test("customKeywords extracts non-standard IMAP keywords verbatim")
    func customKeywordsVerbatim() {
        var info = makeInfo()
        info.flags = [.seen, .custom("tm_reply"), .custom("$Important"), .flagged]
        // System flags (\\Seen, \\Flagged) are NOT .custom, so filtered out by the match.
        let keywords = IMAPFetchMapping.customKeywords(from: info)
        #expect(keywords == ["tm_reply", "$Important"])
    }
}
