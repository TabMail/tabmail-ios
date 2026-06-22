/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates `Shared/Parse/RFC5322Parse.buildMetadata` — the IMAP-side parser
/// that consumes already-tokenized header key/value pairs from SwiftMail and
/// emits the canonical `MessageMetadata`. Shared with any future NSE IMAP
/// client (when IMAP NSE ships).
@Suite("Shared/Parse RFC5322Parse")
struct RFC5322ParseTests {

    // MARK: - buildMetadata core

    @Test("buildMetadata assembles canonical MessageMetadata from IMAP fields")
    func buildFromFields() {
        let m = RFC5322Parse.buildMetadata(
            uid: "42",
            headers: [
                "Subject": "Quarterly update",
                "From": "Alice <alice@example.com>",
                "To": "Bob <bob@example.com>",
                "Message-Id": "<rfc-42@example.com>",
                "Date": "Wed, 15 Nov 2023 10:30:00 +0000",
            ],
            internalDate: nil,
            flags: ["\\Seen"],
            hasAttachments: false,
            snippet: "preview"
        )
        #expect(m?.providerMessageId == "42")
        #expect(m?.subject == "Quarterly update")
        #expect(m?.from.name == "Alice")
        #expect(m?.from.email == "alice@example.com")
        #expect(m?.to.first?.email == "bob@example.com")
        #expect(m?.rfc822MessageId == "rfc-42@example.com")  // brackets stripped
        #expect(m?.isRead == true)   // \Seen present
        #expect(m?.isFlagged == false)
        #expect(m?.snippet == "preview")
        #expect(m?.threadId == nil)  // IMAP has no native thread id
    }

    @Test("buildMetadata uses internalDate when Date header is missing")
    func internalDateFallback() {
        let internalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let m = RFC5322Parse.buildMetadata(
            uid: "1",
            headers: ["From": "a@b.c"],
            internalDate: internalDate,
            flags: [], hasAttachments: false
        )
        #expect(m?.date == internalDate)
    }

    @Test("buildMetadata header lookup is case-insensitive")
    func caseInsensitiveHeaders() {
        let m = RFC5322Parse.buildMetadata(
            uid: "1",
            headers: ["message-id": "<abc@x.com>", "FROM": "a@b.c"],
            internalDate: Date(), flags: [], hasAttachments: false
        )
        #expect(m?.rfc822MessageId == "abc@x.com")
        #expect(m?.from.email == "a@b.c")
    }

    @Test("buildMetadata \\Flagged flag maps to isFlagged=true")
    func flaggedFlag() {
        let m = RFC5322Parse.buildMetadata(
            uid: "1", headers: ["From": "a@b.c"], internalDate: Date(),
            flags: ["\\Flagged", "\\Seen"], hasAttachments: false
        )
        #expect(m?.isFlagged == true)
    }

    @Test("buildMetadata preserves custom keywords in providerLabels")
    func customKeywordsPreserved() {
        let m = RFC5322Parse.buildMetadata(
            uid: "1", headers: ["From": "a@b.c"], internalDate: Date(),
            flags: ["\\Seen", "tm_reply", "$Important"], hasAttachments: false
        )
        #expect(m?.providerLabels.contains("tm_reply") == true)
        #expect(m?.providerLabels.contains("$Important") == true)
    }

    @Test("buildMetadata extracts References into ordered normalized IDs")
    func referencesList() {
        let m = RFC5322Parse.buildMetadata(
            uid: "1",
            headers: [
                "From": "a@b.c",
                "References": "<a@x.com> <b@y.com>\n <c@z.com>"
            ],
            internalDate: Date(), flags: [], hasAttachments: false
        )
        #expect(m?.references == ["a@x.com", "b@y.com", "c@z.com"])
    }

    // MARK: - parseRFC5322Date

    @Test("parseRFC5322Date handles standard RFC 5322 format")
    func rfc5322StandardDate() {
        let d = RFC5322Parse.parseRFC5322Date("Wed, 15 Nov 2023 10:30:00 +0000")
        #expect(d != nil)
        if let d {
            let components = Calendar(identifier: .gregorian).dateComponents(
                in: TimeZone(secondsFromGMT: 0)!, from: d)
            #expect(components.year == 2023)
            #expect(components.month == 11)
            #expect(components.day == 15)
            #expect(components.hour == 10)
        }
    }

    @Test("parseRFC5322Date handles missing weekday prefix")
    func rfc5322NoWeekday() {
        let d = RFC5322Parse.parseRFC5322Date("15 Nov 2023 10:30:00 +0000")
        #expect(d != nil)
    }

    @Test("parseRFC5322Date returns nil for garbage")
    func rfc5322Garbage() {
        #expect(RFC5322Parse.parseRFC5322Date("not-a-date") == nil)
        #expect(RFC5322Parse.parseRFC5322Date("") == nil)
    }

    // MARK: - decodeRFC2047

    @Test("decodeRFC2047 passes through non-encoded strings")
    func rfc2047Passthrough() {
        #expect(RFC5322Parse.decodeRFC2047("plain text") == "plain text")
        #expect(RFC5322Parse.decodeRFC2047("") == "")
    }

    @Test("decodeRFC2047 decodes UTF-8 B encoding")
    func rfc2047BEncoding() {
        // "日本" encoded as =?UTF-8?B?5pel5pys?=
        let decoded = RFC5322Parse.decodeRFC2047("=?UTF-8?B?5pel5pys?=")
        #expect(decoded == "日本")
    }

    @Test("decodeRFC2047 decodes UTF-8 Q encoding with underscore=space rule")
    func rfc2047QEncodingUnderscore() {
        // Q-encoding uses "_" for space.
        let decoded = RFC5322Parse.decodeRFC2047("=?UTF-8?Q?Hello_World?=")
        #expect(decoded == "Hello World")
    }

    @Test("decodeRFC2047 decodes UTF-8 Q encoding with =XX byte escapes")
    func rfc2047QEncodingBytes() {
        // "é" = 0xC3 0xA9 in UTF-8.
        let decoded = RFC5322Parse.decodeRFC2047("=?UTF-8?Q?=C3=A9?=")
        #expect(decoded == "é")
    }

    @Test("decodeRFC2047 interleaves encoded and plain text")
    func rfc2047Interleaved() {
        let decoded = RFC5322Parse.decodeRFC2047("Hello =?UTF-8?B?5pel5pys?= World")
        #expect(decoded == "Hello 日本 World")
    }

    @Test("decodeRFC2047 merges adjacent encoded-words, dropping fold whitespace")
    func rfc2047AdjacentWordsMerge() {
        // RFC 2047 §6.2: linear whitespace between two adjacent encoded-words is
        // removed. Covers both a plain space and a CRLF+SPACE fold (the form our
        // own RFC2047 encoder emits for long subjects).
        #expect(RFC5322Parse.decodeRFC2047("=?UTF-8?B?5pel?= =?UTF-8?B?5pys?=") == "日本")
        #expect(RFC5322Parse.decodeRFC2047("=?UTF-8?B?5pel?=\r\n =?UTF-8?B?5pys?=") == "日本")
    }

    @Test("decodeRFC2047 keeps whitespace between an encoded-word and plain text")
    func rfc2047WhitespaceWithPlainTextPreserved() {
        // Only inter-encoded-word whitespace is dropped; spacing around plain
        // text must survive.
        #expect(RFC5322Parse.decodeRFC2047("=?UTF-8?B?5pel?= and =?UTF-8?B?5pys?=") == "日 and 本")
    }
}
