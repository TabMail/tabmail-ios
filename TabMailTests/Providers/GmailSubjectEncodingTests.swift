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

    // MARK: - Control characters reaching an outbound header line

    /// Every CRLF in a legal header field is a FOLD, so it is always followed by
    /// SP or HTAB (RFC 5322 §2.2.3). A CRLF followed by anything else has ended
    /// the field and started a new header — which is the injection. Asserting the
    /// property this way covers payloads nobody enumerated, unlike checking for a
    /// particular injected header name.
    private func unfoldedBreaks(in header: String) -> [String] {
        var offenders: [String] = []
        let scalars = Array(header.unicodeScalars)
        for index in scalars.indices {
            let scalar = scalars[index]
            guard scalar == "\r" || scalar == "\n" else { continue }
            // Skip the LF of a CRLF pair; the CR already decided the verdict.
            if scalar == "\n", index > 0, scalars[index - 1] == "\r" { continue }
            var next = index + 1
            if scalar == "\r", next < scalars.count, scalars[next] == "\n" { next += 1 }
            guard next < scalars.count else { continue }  // trailing terminator
            let following = scalars[next]
            if following != " " && following != "\t" {
                offenders.append(String(String.UnicodeScalarView(scalars[index...min(next + 24, scalars.count - 1)])))
            }
        }
        return offenders
    }

    /// A sender-authored RFC 2047 encoded-word decodes to arbitrary octets — the
    /// decoder applies no control filtering — so a reply/forward can carry a real
    /// CRLF in `draft.subject`. The encoder must not hand that to a header line.
    /// It used to: its trigger was `!$0.isASCII`, and CR and LF are ASCII, so the
    /// one value that must be encoded was the one returned unchanged.
    @Test("A subject carrying CRLF is encoded, never emitted as a second header")
    func controlBearingSubjectIsEncoded() {
        let injected = "Fwd: Hi\r\nBcc: attacker@evil.example"
        let encoded = RFC2047.encodeHeaderValue(injected)

        #expect(encoded.hasPrefix("=?UTF-8?B?"), "a control-bearing value must become an encoded-word")
        #expect(unfoldedBreaks(in: "Subject: \(encoded)").isEmpty)
        #expect(!encoded.contains("Bcc:"), "the payload must not survive as readable header text")
        // Nothing is lost — the recipient still sees what the sender wrote.
        #expect(RFC5322Parse.decodeRFC2047(encoded) == injected)
    }

    @Test("Every C0/C1 control in a subject is encoded, not just CR and LF")
    func allControlsAreEncoded() {
        var unencoded: [String] = []
        // 0x09 (HTAB) is excluded on purpose: it is WSP and legal literal text in
        // an unstructured field body, so encoding it would be over-reach. Every
        // other C0, DEL, and C1 must be encoded.
        for scalar in Array(0x00...0x1F).filter({ $0 != 0x09 }) + [0x7F] + Array(0x80...0x9F) {
            guard let unicode = Unicode.Scalar(UInt32(scalar)) else { continue }
            let subject = "Report \(Character(unicode)) update"
            let encoded = RFC2047.encodeHeaderValue(subject)
            if !encoded.hasPrefix("=?UTF-8?B?") || !unfoldedBreaks(in: "Subject: \(encoded)").isEmpty {
                unencoded.append(String(format: "U+%04X", scalar))
            }
        }
        #expect(unencoded.isEmpty, "controls emitted into a header raw: \(unencoded.joined(separator: ", "))")
    }

    /// Non-vacuity for the two tests above: the widened trigger must not have
    /// turned into "encode everything". A benign ASCII subject still passes
    /// through untouched, so a green result above cannot be bought by refusing or
    /// encoding all input.
    @Test("Widening the trigger did not start encoding benign subjects")
    func benignSubjectsStillPassThrough() {
        for subject in ["Plain subject", "Re: Q3 numbers (final)", "a b\tc", "", "50% off — no"] {
            let encoded = RFC2047.encodeHeaderValue(subject)
            if subject.allSatisfy({ $0.isASCII }) {
                #expect(encoded == subject, "benign ASCII subject was altered: \(subject.debugDescription)")
            }
        }
    }

    /// Field names in a header block: lines that do not begin with SP/HTAB (a
    /// folded continuation belongs to the field above it).
    private func headerFieldNames(in block: String) -> [String] {
        block.components(separatedBy: "\r\n")
            .filter { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }
            .compactMap { line in line.firstIndex(of: ":").map { String(line[line.startIndex..<$0]) } }
    }

    /// The invariant, stated so it cannot be satisfied by anticipating a payload:
    /// **a hostile subject must produce exactly the same set of header FIELDS as a
    /// benign one.** Any injected field — `Bcc`, `Reply-To`, a second `From`, or
    /// something nobody thought of — breaks the comparison. Asserting
    /// `!contains("Bcc:")` would pass a `Reply-To:` payload.
    @Test("Both Gmail builders emit the same header fields for a hostile subject as a benign one")
    func bothBuildersRefuseInjectedHeader() async {
        let injected = "Fwd: Hi\r\nBcc: attacker@evil.example"
        let hostile = DraftMessage(to: ["you@example.com"], subject: injected, body: "body")
        let benign = DraftMessage(to: ["you@example.com"], subject: "Fwd: Hi", body: "body")
        let provider = makeProvider()

        func headerBlock(_ raw: String) -> String { raw.components(separatedBy: "\r\n\r\n").first ?? raw }

        let hostileRFC = headerBlock(provider.buildRFC822(draft: hostile))
        let benignRFC = headerBlock(provider.buildRFC822(draft: benign))
        #expect(headerFieldNames(in: hostileRFC) == headerFieldNames(in: benignRFC),
                "buildRFC822 gained a header field: \(headerFieldNames(in: hostileRFC))")

        let hostileMIME = headerBlock(String(decoding: provider.buildMIMEMessage(draft: hostile), as: UTF8.self))
        let benignMIME = headerBlock(String(decoding: provider.buildMIMEMessage(draft: benign), as: UTF8.self))
        #expect(headerFieldNames(in: hostileMIME) == headerFieldNames(in: benignMIME),
                "buildMIMEMessage gained a header field: \(headerFieldNames(in: hostileMIME))")

        // And the subject the recipient sees is still the sender's text, intact.
        let subjectLine = hostileRFC.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject: ") }
        #expect(subjectLine != nil)
        if let subjectLine {
            #expect(RFC5322Parse.decodeRFC2047(String(subjectLine.dropFirst("Subject: ".count))) == injected)
        }
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
