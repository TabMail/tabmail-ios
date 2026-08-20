/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Owner decision (2026-08-19, ADR-IOS-078): an AI summary that already exists is
// NEVER gated from display. The newest-100 inbox window bounds PROCESSING only
// (IOS-AI-004); the display gate that 7a31f1d22 added to this view (and the
// inbox-membership display gate that v1.7.9 already had) are both removed. The
// only remaining `.hidden` outcomes are presentation states: demo-with-AI-declined,
// and the ABSENT-summary empty state outside the Inbox (where nothing will ever
// process the message, so a spinner would advertise work that never happens).
@Suite("SummaryBubbleView — display decision")
@MainActor
struct SummaryBubbleViewTests {

    // MARK: - An existing summary renders — in every folder

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
        // The "no content" stub is written by AccountManager.processOpenedMessage
        // when an opened inbox message has no body/attachments. It is an existing
        // AI artifact and displays, mirroring TB's stub behavior.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: "This message has no content.",
            demoSuppressed: false
        )
        #expect(mode == .content)
    }

    @Test("non-inbox message with cached summary renders it (search-opened Sent/Archive case)")
    func nonInboxWithSummaryRendersContent() {
        // The predecessor of this test asserted `== .hidden` — the inbox-membership
        // display gate that v1.7.9 shipped. The owner decision of 2026-08-19 removes
        // that gate too: an existing summary renders in every folder. Inverted
        // rather than deleted, so the old policy cannot silently return.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: "Vendor confirmed Friday delivery.",
            demoSuppressed: false
        )
        #expect(mode == .content)
    }

    @Test("non-inbox message with the no-content stub renders it")
    func nonInboxWithNoContentStubRendersContent() {
        // The stub stamps MessageHeader.summaryBlurb directly; it is existing AI
        // content and follows the message out of the inbox. Inverted from the
        // predecessor that asserted `.hidden`.
        let mode = SummaryBubbleView.displayMode(
            isInInbox: false,
            summaryBlurb: "This message has no content.",
            demoSuppressed: false
        )
        #expect(mode == .content)
    }

    @Test("summary existence is the only display input — no folder state hides an existing summary")
    func existingSummaryRendersRegardlessOfFolderState() {
        // The invariant this file exists to pin: exists ⇒ shown. The newest-100
        // window axis is deliberately ABSENT from displayMode's signature — the
        // processing bound has no display-side input to vary — so the remaining
        // folder axis is exhausted here.
        let blurbs = ["Vendor confirmed Friday delivery.", "This message has no content."]
        for isInInbox in [true, false] {
            for blurb in blurbs {
                let mode = SummaryBubbleView.displayMode(
                    isInInbox: isInInbox,
                    summaryBlurb: blurb,
                    demoSuppressed: false
                )
                #expect(
                    mode == .content,
                    "isInInbox=\(isInInbox) blurb=\(blurb)"
                )
            }
        }
    }

    // MARK: - Absent summary: empty state in the inbox, nothing elsewhere

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

    @Test("non-inbox message with nil summary is hidden (empty-state presentation, not a content gate)")
    func nonInboxWithNilSummaryIsHidden() {
        // There is no summary to display and nothing ever processes a non-inbox
        // message (AccountManager.processOpenedMessage guards on isInInbox), so
        // rendering the loading/failed chain would advertise work that never
        // happens. This bounds only the absent-summary presentation.
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

    @Test("demo with AI declined hides the inbox empty state (control pair: same input without demo is .empty)")
    func demoSuppressedHidesInboxEmpty() {
        // Discriminating control for the demo flag on the absent-summary arm:
        // `inboxWithNilSummaryRendersEmpty` pins this same input with
        // demoSuppressed=false to `.empty`, so the pair fails if the demo
        // consent branch is removed. (A non-inbox variant would be vacuous —
        // that input is `.hidden` with or without demo.)
        let mode = SummaryBubbleView.displayMode(
            isInInbox: true,
            summaryBlurb: nil,
            demoSuppressed: true
        )
        #expect(mode == .hidden)
    }

    // MARK: - Live MessageHeader fixture (DB roundtrip → displayMode parity)

    @Test("non-inbox MessageHeader fetched from DB renders its retained summary")
    func nonInboxHeaderFromDBRendersContent() throws {
        // Inverted from the predecessor that asserted `.hidden`: a message opened
        // via search from a non-inbox folder (Sent/Archive/Trash) renders the
        // summary its row retained — existing AI content is never window- or
        // folder-gated (owner decision 2026-08-19).
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

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
                arguments: ["Summary retained from before move", header.id]
            )
        }
        header = try db.read { try MessageHeader.fetchOne($0, key: header.id) }!

        let mode = SummaryBubbleView.displayMode(
            isInInbox: header.isInInbox,
            summaryBlurb: header.summaryBlurb,
            demoSuppressed: false
        )
        #expect(mode == .content)
        #expect(header.summaryBlurb == "Summary retained from before move")
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
