/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SummaryBubbleView — display gate")
struct SummaryBubbleViewTests {

    // MARK: - Inbox + content → .content

    @Test("inbox message with cached summary renders content")
    func inboxWithSummaryShowsContent() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: "Vendor confirmed Friday delivery.",
            demoSuppressed: false
        )
        #expect(mode == .content)
    }

    @Test("inbox message with the no-content stub still renders content (stub is in-inbox AI-skip path)")
    func inboxWithNoContentStubShowsContent() {
        // The "no content" stub is written by AccountManagerAI.processOpenedMessage
        // when an opened inbox message has no body/attachments. While in the inbox
        // it should display, mirroring TB's stub behavior.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: "This message has no content.",
            demoSuppressed: false
        )
        #expect(mode == .content)
    }

    // MARK: - Inbox + no content → .empty

    @Test("inbox message with nil summary renders empty state")
    func inboxWithNilSummaryRendersEmpty() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: nil,
            demoSuppressed: false
        )
        #expect(mode == .empty)
    }

    @Test("inbox message with empty-string summary renders empty state")
    func inboxWithEmptyStringSummaryRendersEmpty() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: "",
            demoSuppressed: false
        )
        #expect(mode == .empty)
    }

    // MARK: - Non-inbox → .hidden (regardless of content)

    @Test("non-inbox message with cached summary is hidden (search-opened Sent/Archive case)")
    func nonInboxWithSummaryIsHidden() {
        // This is the bug fix: a message opened via search from a non-inbox folder
        // (Sent/Archive/Trash) must not surface a leftover cached summary, even
        // though MessageAICache.restoreIfCached or a prior inbox-stay may have
        // populated MessageHeader.summaryBlurb.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: "Vendor confirmed Friday delivery.",
            demoSuppressed: false
        )
        #expect(mode == .hidden)
    }

    @Test("non-inbox message with no-content stub is hidden")
    func nonInboxWithNoContentStubIsHidden() {
        // The "no content" stub stamps MessageHeader.summaryBlurb directly. When
        // such a message later moves out of inbox and is opened via search, the
        // stub must not display.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: "This message has no content.",
            demoSuppressed: false
        )
        #expect(mode == .hidden)
    }

    @Test("non-inbox message with nil summary is hidden")
    func nonInboxWithNilSummaryIsHidden() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: nil,
            demoSuppressed: false
        )
        #expect(mode == .hidden)
    }

    @Test("non-inbox message with empty-string summary is hidden")
    func nonInboxWithEmptyStringSummaryIsHidden() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: "",
            demoSuppressed: false
        )
        #expect(mode == .hidden)
    }

    // MARK: - Demo suppression takes precedence

    @Test("demo with AI declined hides bubble even for inbox + content")
    func demoSuppressedHidesContent() {
        // Demo-with-AI-declined suppresses the bubble
        // regardless of pre-baked content or inbox state.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: "Pre-baked demo summary.",
            demoSuppressed: true
        )
        #expect(mode == .hidden)
    }

    @Test("demo with AI declined hides bubble for non-inbox empty case")
    func demoSuppressedHidesNonInboxEmpty() {
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: nil,
            demoSuppressed: true
        )
        #expect(mode == .hidden)
    }

    // MARK: - Live MessageHeader fixture (DB roundtrip → displayMode parity)

    @Test("non-inbox MessageHeader fetched from DB resolves to .hidden")
    func nonInboxHeaderFromDBHidden() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Insert a message in the Sent folder with a cached summaryBlurb (mimicking
        // a row that retained the stub or had its summary restored from a prior
        // inbox stay).
        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "200",
            folderId: "acc1:Sent",
            folderPath: "Sent",
            isInInbox: false,
            rfc822MessageId: "<msg200@example.com>"
        )
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ? WHERE id = ?",
                arguments: ["Stale summary from before move", header.id]
            )
        }
        header = try db.read { try MessageHeader.fetchOne($0, key: header.id) }!

        let mode = SummaryBubbleView.displayMode(
            isInInbox: header.isInInbox,
            summaryBlurb: header.summaryBlurb,
            demoSuppressed: false
        )
        #expect(mode == .hidden)
        #expect(header.summaryBlurb == "Stale summary from before move")
    }

    @Test("inbox MessageHeader fetched from DB with summary resolves to .content")
    func inboxHeaderFromDBContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "300",
            isInInbox: true,
            rfc822MessageId: "<msg300@example.com>"
        )
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ? WHERE id = ?",
                arguments: ["Fresh inbox summary", header.id]
            )
        }
        header = try db.read { try MessageHeader.fetchOne($0, key: header.id) }!

        let mode = SummaryBubbleView.displayMode(
            isInInbox: header.isInInbox,
            summaryBlurb: header.summaryBlurb,
            demoSuppressed: false
        )
        #expect(mode == .content)
    }
}
