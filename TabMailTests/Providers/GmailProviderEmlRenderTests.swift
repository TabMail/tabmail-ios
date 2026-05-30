/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for Gmail's `envelopeFromHeaders` — the pure piece of the Gmail
/// `.eml` marker embedding that doesn't require an HTTP mock. The full body
/// extraction path is covered indirectly via `EmlMarker` + the parser
/// round-trip tests.
///
/// All content synthetic.
@Suite("GmailProvider.envelopeFromHeaders — rfc822 part header parsing")
struct GmailProviderEnvelopeTests {

    @Test("Extracts Subject/From/Date/To/Cc from part headers")
    func fullEnvelope() {
        let headers: [GmailHeader] = [
            GmailHeader(name: "Subject", value: "Synthetic Subject"),
            GmailHeader(name: "From", value: "\"Alice\" <alice@example.com>"),
            GmailHeader(name: "To", value: "bob@example.com, carol@example.com"),
            GmailHeader(name: "Cc", value: "dan@example.com"),
            GmailHeader(name: "Date", value: "Wed, 2 Oct 2025 01:50:00 +0000"),
        ]
        let env = GmailProvider.envelopeFromHeaders(headers)
        #expect(env.subject == "Synthetic Subject")
        #expect(env.from == "\"Alice\" <alice@example.com>")
        #expect(env.to == ["bob@example.com", "carol@example.com"])
        #expect(env.cc == ["dan@example.com"])
        #expect(env.date != nil)
        // Verify the date parsed approximately correct (UTC 2025-10-02 01:50:00)
        if let d = env.date {
            let iso = d.iso8601String()
            #expect(iso.hasPrefix("2025-10-02T01:50:00"))
        }
    }

    @Test("Header name matching is case-insensitive")
    func caseInsensitiveNames() {
        let headers: [GmailHeader] = [
            GmailHeader(name: "subject", value: "lowercased"),
            GmailHeader(name: "FROM", value: "uppercased@example.com"),
        ]
        let env = GmailProvider.envelopeFromHeaders(headers)
        #expect(env.subject == "lowercased")
        #expect(env.from == "uppercased@example.com")
    }

    @Test("Missing headers produce nil/empty fields")
    func missingFields() {
        let env = GmailProvider.envelopeFromHeaders([])
        #expect(env.subject == nil)
        #expect(env.from == nil)
        #expect(env.date == nil)
        #expect(env.to.isEmpty)
        #expect(env.cc.isEmpty)
    }

    @Test("Multiple comma-separated recipients are trimmed and split")
    func multiRecipientSplit() {
        let headers: [GmailHeader] = [
            GmailHeader(name: "To", value: "  a@x.com ,b@x.com  , c@x.com"),
        ]
        let env = GmailProvider.envelopeFromHeaders(headers)
        #expect(env.to == ["a@x.com", "b@x.com", "c@x.com"])
    }

    @Test("Empty recipient string produces empty array (not array with empty string)")
    func emptyRecipientString() {
        let headers: [GmailHeader] = [GmailHeader(name: "To", value: "")]
        let env = GmailProvider.envelopeFromHeaders(headers)
        #expect(env.to.isEmpty)
    }

    @Test("Malformed Date header leaves date nil (no crash)")
    func malformedDate() {
        let headers: [GmailHeader] = [
            GmailHeader(name: "Date", value: "not-a-date"),
        ]
        let env = GmailProvider.envelopeFromHeaders(headers)
        #expect(env.date == nil)
    }

    @Test("Envelope from headers round-trips through EmlMarker + parser")
    func roundTripThroughMarker() {
        let headers: [GmailHeader] = [
            GmailHeader(name: "Subject", value: "Round trip"),
            GmailHeader(name: "From", value: "x@y.z"),
            GmailHeader(name: "To", value: "a@b.c"),
        ]
        let env = GmailProvider.envelopeFromHeaders(headers)
        let marker = EmlMarker.build(
            filename: "g.eml",
            partSection: "gmail-att-id-123",
            envelope: env,
            bodyHtml: "<p>body</p>"
        )
        let md = EmailFilter.parseEmlSectionMetadata(html: marker, filename: "g.eml")
        #expect(md?.subject == "Round trip")
        #expect(md?.from == "x@y.z")
        #expect(md?.toList == "a@b.c")
        #expect(md?.partSection == "gmail-att-id-123")
    }
}
