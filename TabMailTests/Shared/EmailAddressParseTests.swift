/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates that `EmailAddress.parse` — the shared consolidation of three
/// previous `parseFromHeader` implementations (Gmail, IMAP, NSE) — preserves
/// behavior across every scenario the legacy code handled. Any regression here
/// would desync display names in headers across providers.
@Suite("Shared/DTO EmailAddress.parse")
struct EmailAddressParseTests {

    // MARK: - Angle-bracket format (the common "Name <email>" case)

    @Test("Display name + address")
    func displayNameAddress() {
        let r = EmailAddress.parse("John Doe <john@example.com>")
        #expect(r.name == "John Doe")
        #expect(r.email == "john@example.com")
    }

    @Test("Quoted display name with comma is preserved")
    func quotedDisplayNameComma() {
        let r = EmailAddress.parse("\"Doe, John\" <john@example.com>")
        #expect(r.name == "Doe, John")
        #expect(r.email == "john@example.com")
    }

    @Test("Empty name part falls back to email as name")
    func emptyNamePart() {
        let r = EmailAddress.parse("<john@example.com>")
        #expect(r.name == "john@example.com")
        #expect(r.email == "john@example.com")
    }

    @Test("Whitespace around name is trimmed")
    func whitespaceTrimmed() {
        let r = EmailAddress.parse("  Alice   <alice@example.com>")
        #expect(r.name == "Alice")
        #expect(r.email == "alice@example.com")
    }

    @Test("Surrounding quotes stripped from name")
    func quotesStripped() {
        let r = EmailAddress.parse("\"Bob Smith\" <bob@example.com>")
        #expect(r.name == "Bob Smith")
        #expect(r.email == "bob@example.com")
    }

    @Test("Quoted name with apostrophe preserved")
    func quotedApostrophe() {
        let r = EmailAddress.parse("\"O'Brien\" <ob@test.com>")
        #expect(r.name == "O'Brien")
        #expect(r.email == "ob@test.com")
    }

    // MARK: - Bare addresses

    @Test("Bare address produces name == email == same value")
    func bareAddress() {
        let r = EmailAddress.parse("john@example.com")
        #expect(r.name == "john@example.com")
        #expect(r.email == "john@example.com")
    }

    @Test("Bare address with surrounding whitespace is trimmed")
    func bareAddressWhitespace() {
        let r = EmailAddress.parse("  user@test.com  ")
        #expect(r.name == "user@test.com")
        #expect(r.email == "user@test.com")
    }

    // MARK: - Empty / edge inputs

    @Test("Empty string produces empty EmailAddress")
    func emptyString() {
        let r = EmailAddress.parse("")
        #expect(r.name == "")
        #expect(r.email == "")
    }

    @Test("Whitespace-only string produces empty EmailAddress")
    func whitespaceOnly() {
        let r = EmailAddress.parse("    ")
        #expect(r.name == "")
        #expect(r.email == "")
    }

    // MARK: - RFC 2047 encoded words (not decoded here — decoding is RFC5322Parse's job)

    @Test("RFC 2047 encoded-word name is passed through (decoding happens in RFC5322Parse)")
    func rfc2047Passthrough() {
        let r = EmailAddress.parse("=?UTF-8?B?5pel5pys?= <jp@example.com>")
        #expect(r.email == "jp@example.com")
        // Name passes through — not EmailAddress.parse's responsibility to decode.
        #expect(r.name.contains("=?UTF-8?B?"))
    }

    // MARK: - Parity bridge — GmailProvider.parseFromHeader delegates here

    @Test("GmailProvider.parseFromHeader tuple matches EmailAddress.parse")
    func gmailProviderDelegation() {
        let inputs = [
            "John Doe <john@example.com>",
            "\"Doe, John\" <john@example.com>",
            "user@test.com",
            "<noname@test.com>",
            ""
        ]
        for input in inputs {
            let shared = EmailAddress.parse(input)
            let legacy = GmailProvider.parseFromHeader(input)
            #expect(legacy.displayName == shared.name, "displayName mismatch for '\(input)'")
            #expect(legacy.address == shared.email, "address mismatch for '\(input)'")
        }
    }
}
