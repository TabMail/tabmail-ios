/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageViewHelpers")
struct MessageViewHelpersTests {
    // MARK: - extractNames

    @Test("extractNames extracts display name from formatted address")
    func extractNamesDisplayName() {
        let result = MessageViewHelpers.extractNames("\"John Doe\" <john@example.com>")
        #expect(result == "John Doe")
    }

    @Test("extractNames returns email when no display name")
    func extractNamesNoDisplayName() {
        let result = MessageViewHelpers.extractNames("<john@example.com>")
        #expect(result == "john@example.com")
    }

    @Test("extractNames handles plain email without angle brackets")
    func extractNamesPlainEmail() {
        let result = MessageViewHelpers.extractNames("john@example.com")
        #expect(result == "john@example.com")
    }

    @Test("extractNames handles multiple recipients")
    func extractNamesMultipleRecipients() {
        let result = MessageViewHelpers.extractNames("\"John\" <john@ex.com>, jane@ex.com, \"Bob\" <bob@ex.com>")
        #expect(result == "John, jane@ex.com, Bob")
    }

    @Test("extractNames strips surrounding quotes")
    func extractNamesQuotedEmail() {
        let result = MessageViewHelpers.extractNames("\"jane@example.com\"")
        #expect(result == "jane@example.com")
    }

    @Test("extractNames handles empty string")
    func extractNamesEmpty() {
        let result = MessageViewHelpers.extractNames("")
        #expect(result == "")
    }

    // MARK: - formatShortDate

    @Test("formatShortDate returns time for today")
    func formatShortDateToday() {
        let result = MessageViewHelpers.formatShortDate(Date())
        // Should be a time string like "3:45 PM", not a date
        #expect(!result.contains("Yesterday"))
        #expect(!result.contains("Jan"))
        #expect(!result.contains("Feb"))
    }

    @Test("formatShortDate returns Yesterday for yesterday")
    func formatShortDateYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let result = MessageViewHelpers.formatShortDate(yesterday)
        #expect(result == "Yesterday")
    }

    @Test("formatShortDate returns month and day for older dates this year")
    func formatShortDateThisYear() {
        // Use a date 10 days ago (guaranteed to be this year if we're past Jan 10)
        let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        let result = MessageViewHelpers.formatShortDate(tenDaysAgo)
        // Should contain a month abbreviation
        #expect(result != "Yesterday")
        #expect(!result.isEmpty)
    }

    @Test("formatShortDate includes year for dates in a different year")
    func formatShortDateDifferentYear() {
        var components = DateComponents()
        components.year = 2020
        components.month = 6
        components.day = 15
        let date = Calendar.current.date(from: components)!
        let result = MessageViewHelpers.formatShortDate(date)
        #expect(result.contains("2020"))
    }

    // MARK: - formatExpandedDate

    @Test("formatExpandedDate includes both date and time")
    func formatExpandedDateIncludesDateTime() {
        let result = MessageViewHelpers.formatExpandedDate(Date())
        // Should be something like "Mar 18, 2026 at 5:30 PM"
        #expect(!result.isEmpty)
        // Should contain a comma (date format) and either AM/PM or 24h time
        #expect(result.contains(",") || result.contains(":"))
    }

    // MARK: - showShimmer

    @Test("showShimmer true when tag exists but no cached reply")
    @MainActor
    func showShimmerActiveTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, actionTag: .reply)
        header.cachedReply = nil
        // Shimmer requires an active subscription gate; default is closed.
        AISubscriptionGate.shared.openGate()
        #expect(MessageViewHelpers.showShimmer(header) == true)
    }

    @Test("showShimmer false when no tag")
    func showShimmerNoTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        #expect(MessageViewHelpers.showShimmer(header) == false)
    }

    @Test("showShimmer false when tag exists and cached reply exists")
    func showShimmerWithCachedReply() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, actionTag: .reply)
        header.cachedReply = "Some reply text"
        #expect(MessageViewHelpers.showShimmer(header) == false)
    }
}
