/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

/// Covers the RFC 2047 round-trip for the Gmail send path: outgoing subjects are
/// encoded (`RFC2047.encodeHeaderValue`, wired into `buildRFC822`/`buildMIMEMessage`)
/// and decoded on readback (`GmailParse.parseMessage` → `RFC5322Parse.decodeRFC2047`).
@Suite("Gmail subject RFC 2047 encoding")
struct GmailSubjectEncodingTests {

    private func makeProvider() -> GmailProvider {
        GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
    }

    // MARK: - Encoder

    @Test("ASCII subject passes through unchanged")
    func asciiPassthrough() {
        #expect(RFC2047.encodeHeaderValue("Hello, world") == "Hello, world")
        #expect(RFC2047.encodeHeaderValue("") == "")
    }

    @Test("Korean subject encodes to pure ASCII and round-trips both decoders")
    func koreanRoundTrip() {
        let subject = "가입정보 변경 안내 신청"
        let encoded = RFC2047.encodeHeaderValue(subject)
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(encoded.hasPrefix("=?UTF-8?B?"))
        #expect(!encoded.contains("가"))
        // App-side decoder (used by the Gmail + EML read paths).
        #expect(RFC5322Parse.decodeRFC2047(encoded) == subject)
        // SwiftMail decoder (used by the IMAP read path).
        #expect(encoded.decodeMIMEHeader() == subject)
    }

    @Test("Long Korean subject folds into multiple words and still round-trips")
    func longSubjectRoundTrip() {
        let subject = String(repeating: "한국어제목", count: 10)
        let encoded = RFC2047.encodeHeaderValue(subject)
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(encoded.contains("\r\n "), "expected folding into multiple encoded-words")
        #expect(RFC5322Parse.decodeRFC2047(encoded) == subject)
        #expect(encoded.decodeMIMEHeader() == subject)
    }

    @Test("Emoji subject round-trips")
    func emojiRoundTrip() {
        let subject = "Launch 🚀 완료 🎉"
        let encoded = RFC2047.encodeHeaderValue(subject)
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(RFC5322Parse.decodeRFC2047(encoded) == subject)
    }

    // MARK: - buildRFC822 integration (no-attachment send path)

    @Test("buildRFC822 emits an encoded Subject, not raw 8-bit Korean")
    func buildRFC822EncodesSubject() async {
        let draft = DraftMessage(to: ["you@example.com"], subject: "테스트 제목", body: "본문")
        let raw = makeProvider().buildRFC822(draft: draft)

        #expect(raw.contains("Subject: =?UTF-8?B?"))
        #expect(!raw.contains("Subject: 테스트"))

        let subjectLine = raw.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject: ") }
        #expect(subjectLine != nil)
        if let subjectLine {
            let value = String(subjectLine.dropFirst("Subject: ".count))
            #expect(RFC5322Parse.decodeRFC2047(value) == "테스트 제목")
        }
    }

    @Test("buildRFC822 leaves an ASCII Subject untouched")
    func buildRFC822AsciiSubject() async {
        let draft = DraftMessage(to: ["you@example.com"], subject: "Plain subject", body: "body")
        let raw = makeProvider().buildRFC822(draft: draft)
        #expect(raw.contains("Subject: Plain subject\r\n"))
    }

    // MARK: - GmailParse read-side decode

    @Test("GmailParse decodes an RFC 2047-encoded Subject header")
    func gmailParseDecodesEncodedSubject() {
        // "가입정보" Base64-encoded as an RFC 2047 word.
        let json: [String: Any] = [
            "id": "m1",
            "internalDate": "1700000000000",
            "payload": ["headers": [
                ["name": "Subject", "value": "=?UTF-8?B?6rCA7J6F7KCV67O0?="],
                ["name": "From", "value": "a@example.com"],
            ]],
        ]
        #expect(GmailParse.parseMessage(json)?.subject == "가입정보")
    }

    @Test("GmailParse leaves a plain Subject unchanged (decode is a no-op)")
    func gmailParsePlainSubject() {
        let json: [String: Any] = [
            "id": "m2",
            "internalDate": "1700000000000",
            "payload": ["headers": [["name": "Subject", "value": "Quarterly update"]]],
        ]
        #expect(GmailParse.parseMessage(json)?.subject == "Quarterly update")
    }

    @Test("Round-trip: encode a subject, parse it back through GmailParse")
    func endToEndRoundTrip() {
        let subject = "회의 일정 안내"
        let encoded = RFC2047.encodeHeaderValue(subject)
        let json: [String: Any] = [
            "id": "m3",
            "internalDate": "1700000000000",
            "payload": ["headers": [["name": "Subject", "value": encoded]]],
        ]
        #expect(GmailParse.parseMessage(json)?.subject == subject)
    }
}
