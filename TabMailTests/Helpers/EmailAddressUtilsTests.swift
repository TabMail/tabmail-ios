/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailAddressUtils")
struct EmailAddressUtilsTests {

    @Test("extractEmailAddress from display name format")
    func extractFromDisplayName() {
        #expect(extractEmailAddress("John Doe <john@example.com>") == "john@example.com")
    }

    @Test("extractEmailAddress from quoted display name")
    func extractFromQuotedDisplayName() {
        #expect(extractEmailAddress("\"Doe, John\" <john@example.com>") == "john@example.com")
    }

    @Test("extractEmailAddress from bare address")
    func extractFromBare() {
        #expect(extractEmailAddress("john@example.com") == "john@example.com")
    }

    @Test("extractEmailAddress trims whitespace")
    func extractTrimsWhitespace() {
        #expect(extractEmailAddress("  john@example.com  ") == "john@example.com")
    }

    @Test("extractEmailAddress strips surrounding angle brackets")
    func extractStripsAngleBrackets() {
        #expect(extractEmailAddress("<john@example.com>") == "john@example.com")
    }

    @Test("parseAddressList handles comma-separated addresses")
    func parseCommaSeparated() {
        let result = parseAddressList("a@x.com, b@x.com")
        #expect(result.count == 2)
    }

    @Test("parseAddressList handles quoted display names with commas")
    func parseQuotedCommas() {
        let result = parseAddressList("\"Doe, John\" <john@x.com>, foo@bar.com")
        #expect(result.count == 2)
    }

    @Test("parseAddressList handles empty string")
    func parseEmpty() {
        let result = parseAddressList("")
        #expect(result.isEmpty)
    }

    @Test("parseAddressList handles single address")
    func parseSingle() {
        let result = parseAddressList("alice@example.com")
        #expect(result.count == 1)
    }

    @Test("parseAddressList handles display name format")
    func parseDisplayName() {
        let result = parseAddressList("Alice <alice@example.com>, Bob <bob@example.com>")
        #expect(result.count == 2)
    }
}
