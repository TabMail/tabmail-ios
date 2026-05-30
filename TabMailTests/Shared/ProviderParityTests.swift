/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Non-regression tests for the main-app (non-NSE) pathway after the
/// shared-layer refactor. Every assertion here pins behavior that existed
/// BEFORE the refactor; any break signals an unintended behavior change.
///
/// Counterpart to NSE-only tests — these specifically exercise the main-app
/// entry points (`GmailProvider.parseGmailMessage`, `ExchangeProvider.parseGraphMessage`)
/// and assert the observable outputs haven't shifted.
@Suite("Main-app parity: post-refactor behavior pinned")
struct ProviderParityTests {

    // MARK: - Gmail parseGmailMessage

    @Test("Gmail: raw To/Cc/Bcc headers are preserved verbatim (no email-only stripping)")
    func gmailRawHeaders() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: ["INBOX"],
            snippet: nil, internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [
                    GmailHeader(name: "Subject", value: "hi"),
                    GmailHeader(name: "From", value: "Alice <alice@example.com>"),
                    GmailHeader(name: "To", value: "\"Bob\" <bob@example.com>, carol@example.com"),
                    GmailHeader(name: "Cc", value: "cc@example.com"),
                    GmailHeader(name: "Bcc", value: "bcc@example.com"),
                ],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.to == "\"Bob\" <bob@example.com>, carol@example.com",
                "To header must be preserved with display names + quotes")
        #expect(header?.cc == "cc@example.com")
        #expect(header?.bcc == "bcc@example.com")
    }

    @Test("Gmail: from name + fromAddress split correctly")
    func gmailFromParsed() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: ["INBOX"],
            snippet: nil, internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "Alice Smith <alice@example.com>")],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.from == "Alice Smith")
        #expect(header?.fromAddress == "alice@example.com")
    }

    @Test("Gmail: empty Subject header renders as '(no subject)'")
    func gmailEmptySubject() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: ["INBOX"],
            snippet: nil, internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.subject == "(no subject)")
    }

    @Test("Gmail: hasAttachments=true for non-empty filename")
    func gmailAttachmentFilename() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: nil, snippet: nil,
            internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil,
                parts: [
                    GmailPart(mimeType: "application/pdf", filename: "doc.pdf",
                              headers: nil, body: nil, parts: nil)
                ]
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.hasAttachments == true)
    }

    @Test("Gmail: hasAttachments=true for text/calendar without filename")
    func gmailAttachmentTextCalendar() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: nil, snippet: nil,
            internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil,
                parts: [
                    GmailPart(mimeType: "text/calendar", filename: nil,
                              headers: nil, body: nil, parts: nil)
                ]
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.hasAttachments == true)
    }

    @Test("Gmail: hasAttachments=false for large-body part (filename empty, attachmentId present)")
    func gmailLargeBodyNotAttachment() async {
        // Regression guard: old broken behavior flagged any part
        // with attachmentId as an attachment; correct behavior matches the
        // pre-refactor filename-or-calendar rule.
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: nil, snippet: nil,
            internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil,
                parts: [
                    GmailPart(mimeType: "text/plain", filename: "",
                              headers: nil,
                              body: GmailBody(data: nil, size: 5_000_000, attachmentId: "big-body"),
                              parts: nil)
                ]
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.hasAttachments == false)
    }

    @Test("Gmail: missing internalDate returns nil (fetch failure — retry)")
    func gmailMissingDateReturnsNil() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: nil, snippet: nil,
            internalDate: nil,
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header == nil)
    }

    @Test("Gmail: STARRED label maps to isFlagged=true, UNREAD absence maps to isRead=true")
    func gmailFlagMapping() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: ["INBOX", "STARRED"],
            snippet: nil, internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [GmailHeader(name: "From", value: "a@b.c")],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.isFlagged == true)
        #expect(header?.isRead == true)  // UNREAD not in labels
    }

    @Test("Gmail: References header parsed into normalized ID list")
    func gmailReferencesList() async {
        let provider = makeGmailProvider()
        let msg = GmailMessage(
            id: "m1", threadId: nil, labelIds: nil, snippet: nil,
            internalDate: "1700000000000",
            payload: GmailPayload(
                mimeType: nil,
                headers: [
                    GmailHeader(name: "From", value: "a@b.c"),
                    GmailHeader(name: "References", value: "<a@x.com> <b@y.com> <c@z.com>"),
                ],
                body: nil, parts: nil
            )
        )
        let header = await provider.parseGmailMessage(msg)
        #expect(header?.references == ["a@x.com", "b@y.com", "c@z.com"])
    }

    // MARK: - Helpers

    private func makeGmailProvider() -> GmailProvider {
        GmailProvider(userEmail: "test@example.com") { _ in "fake-token" }
    }
}
