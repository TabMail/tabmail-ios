/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ToolFormatters")
struct ToolFormattersTests {

    // MARK: - formatDate

    @Test("formatDate returns ISO8601 string for a known date")
    func formatDateKnownDate() {
        // 2024-03-15 14:30:00 UTC
        let date = Date(timeIntervalSince1970: 1710513000)
        let result = ToolFormatters.formatDate(date)
        #expect(result == "2024-03-15T14:30:00Z")
    }

    @Test("formatDate for epoch zero")
    func formatDateEpoch() {
        let date = Date(timeIntervalSince1970: 0)
        let result = ToolFormatters.formatDate(date)
        #expect(result == "1970-01-01T00:00:00Z")
    }

    @Test("formatDate does not include fractional seconds")
    func formatDateNoFractional() {
        let date = Date(timeIntervalSince1970: 1710513000.123)
        let result = ToolFormatters.formatDate(date)
        #expect(!result.contains("."))
        #expect(result.hasSuffix("Z"))
    }

    // MARK: - formatDateMs

    @Test("formatDateMs converts milliseconds to ISO8601")
    func formatDateMsBasic() {
        // 1710513000000 ms = 2024-03-15T14:30:00Z
        let result = ToolFormatters.formatDateMs(1710513000000)
        #expect(result == "2024-03-15T14:30:00Z")
    }

    @Test("formatDateMs for zero returns epoch")
    func formatDateMsZero() {
        let result = ToolFormatters.formatDateMs(0)
        #expect(result == "1970-01-01T00:00:00Z")
    }

    @Test("formatDateMs handles fractional milliseconds")
    func formatDateMsFractional() {
        let result = ToolFormatters.formatDateMs(1710513000500)
        // Should still produce a valid ISO8601 string (seconds truncated)
        #expect(result.hasSuffix("Z"))
        #expect(result.contains("2024-03-15"))
    }

    // MARK: - formatFrom

    /// Build a minimal MessageHeader for testing formatFrom.
    private func makeHeader(from: String = "", fromAddress: String = "") -> MessageHeader {
        MessageHeader(
            messageId: "m",
            subject: "S",
            from: from,
            fromAddress: fromAddress,
            to: "",
            date: Date(),
            snippet: "",
            folderId: "f",
            accountId: "a",
            folderPath: "INBOX",
            isInInbox: true
        )
    }

    @Test("formatFrom with name and different address returns Name <email>")
    func formatFromNameAndAddress() {
        let header = makeHeader(from: "Alice Smith", fromAddress: "alice@test.com")
        #expect(ToolFormatters.formatFrom(header) == "Alice Smith <alice@test.com>")
    }

    @Test("formatFrom with empty fromAddress returns from")
    func formatFromEmptyAddress() {
        let header = makeHeader(from: "Alice", fromAddress: "")
        #expect(ToolFormatters.formatFrom(header) == "Alice")
    }

    @Test("formatFrom with from matching fromAddress returns just address")
    func formatFromSameAsAddress() {
        let header = makeHeader(from: "alice@test.com", fromAddress: "alice@test.com")
        #expect(ToolFormatters.formatFrom(header) == "alice@test.com")
    }

    @Test("formatFrom with empty from returns just address")
    func formatFromEmptyName() {
        let header = makeHeader(from: "", fromAddress: "bob@test.com")
        #expect(ToolFormatters.formatFrom(header) == "bob@test.com")
    }

    // MARK: - parseDate

    @Test("parseDate with YYYY-MM-DD string returns date at midnight UTC")
    func parseDateYMD() {
        let result = ToolFormatters.parseDate(.string("2024-03-15"))
        #expect(result != nil)
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let components = utcCalendar.dateComponents([.year, .month, .day], from: result!)
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
    }

    @Test("parseDate with full ISO8601 returns correct date")
    func parseDateFullISO() {
        let result = ToolFormatters.parseDate(.string("2024-03-15T14:30:00Z"))
        #expect(result != nil)
        // Verify it parses to the expected UTC time
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: result!)
        #expect(comps.year == 2024)
        #expect(comps.month == 3)
        #expect(comps.day == 15)
    }

    @Test("parseDate with ISO8601 fractional seconds")
    func parseDateFractional() {
        let result = ToolFormatters.parseDate(.string("2024-03-15T14:30:00.123Z"))
        #expect(result != nil)
    }

    @Test("parseDate with nil returns nil")
    func parseDateNil() {
        #expect(ToolFormatters.parseDate(nil) == nil)
    }

    @Test("parseDate with empty string returns nil")
    func parseDateEmpty() {
        #expect(ToolFormatters.parseDate(.string("")) == nil)
    }

    @Test("parseDate with non-string JSONValue returns nil")
    func parseDateNonString() {
        #expect(ToolFormatters.parseDate(.int(42)) == nil)
        #expect(ToolFormatters.parseDate(.bool(true)) == nil)
    }

    @Test("parseDate with invalid string returns nil")
    func parseDateInvalid() {
        #expect(ToolFormatters.parseDate(.string("not-a-date")) == nil)
    }
}
