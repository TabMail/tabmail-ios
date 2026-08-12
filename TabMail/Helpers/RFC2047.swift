/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// RFC 2047 "encoded-word" ENCODING for non-ASCII email *header* values
/// (Subject, etc.) on the outgoing Gmail-API path (`GmailProvider.buildRFC822` /
/// `buildMIMEMessage`).
///
/// RFC 5322 requires header field bodies to be 7-bit ASCII; non-ASCII text must
/// be wrapped in an encoded-word. Injecting raw 8-bit UTF-8 into a header
/// (which is what we did before) leaves downstream agents — Gmail's ingest MTA,
/// the receiving client — free to apply their own charset guesses, and a chain
/// of "UTF-8-read-as-Latin-1" guesses produces mojibake (e.g. Korean "가" →
/// "ÃªÂ°Â…"). Bodies are unaffected because they carry an explicit charset +
/// Content-Transfer-Encoding; headers have no mechanism other than RFC 2047.
///
/// Decoding is the inverse: `RFC5322Parse.decodeRFC2047`. Kept byte-for-byte in
/// step with SwiftMail's `String.rfc2047EncodedHeader()` (the IMAP/SMTP path);
/// the two repos can't share code because SwiftMail is a remote SPM dependency.
enum RFC2047 {
    /// Max UTF-8 bytes per encoded-word. `=?UTF-8?B?` (10) + `?=` (2) is 12
    /// octets of overhead and Base64 of N bytes is `4*ceil(N/3)`; 45 bytes → 60
    /// Base64 chars → a 72-octet word, safely under RFC 2047 §2's 75-octet
    /// per-encoded-word ceiling.
    private static let maxBytesPerWord = 45

    /// A control character can never appear literally in a header field body
    /// (RFC 5322 §2.2 restricts it to printable US-ASCII plus SP and HTAB), and a
    /// CR or LF among them *ends the field* — everything after it is read as a new
    /// header. C0, DEL, and C1.
    ///
    /// Membership is on the SCALAR, not on `Character.isASCII`: a `Character` is a
    /// grapheme cluster, and CR-LF is a single one, so a `\r\n` pair must be
    /// recognised through its scalars.
    private static func isForbiddenLiteralInHeader(_ scalar: Unicode.Scalar) -> Bool {
        // HTAB is WSP, and RFC 5322 §3.2.5 permits WSP in an unstructured field
        // body, so it is legal literal text and must NOT trigger encoding — the
        // non-vacuity test `benignSubjectsStillPassThrough` caught an earlier
        // version of this predicate encoding "a b\tc" for no reason.
        if scalar.value == 0x09 { return false }
        return scalar.value <= 0x1F || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    /// Encode `value` as one or more RFC 2047 Base64 encoded-words when it
    /// contains any non-ASCII character **or any character that cannot appear
    /// literally in a header field body**; otherwise it is returned unchanged
    /// (already a valid header value).
    ///
    /// ⚠️ **The control-character half of that trigger is load-bearing, and the
    /// obvious-looking `!$0.isASCII` test is not sufficient — CR and LF ARE
    /// ASCII.** With the narrower trigger this function returned a CRLF-bearing
    /// subject *unchanged* while dutifully encoding a Korean one, so the only
    /// input that could break a header was the one input it passed through. A
    /// sender reaches this: `RFC5322Parse.decodeRFC2047` applies no control
    /// filtering, so a legal `=?UTF-8?B?…?=` Subject decodes to arbitrary octets,
    /// `ThreadUtils.normalizeSubject` trims `.whitespaces` (which contains neither
    /// CR nor LF), and reply/forward carries the result into `draft.subject`. The
    /// emitted `Subject:` then gained a second line — an attacker-chosen `Bcc:`
    /// on the user's own outgoing mail. Pinned by
    /// `GmailSubjectEncodingTests.bothBuildersRefuseInjectedHeader`.
    ///
    /// Encoding rather than rejecting is deliberate: an encoded-word is the
    /// standard carrier for octets a header cannot hold literally, so the value is
    /// neutralised structurally with nothing dropped and no send refused — the
    /// recipient still sees exactly what the sender wrote.
    ///
    /// Multiple words are folded with `CRLF SPACE` so each stays within the
    /// 75-octet limit; a character's UTF-8 bytes are never split across words, so
    /// each word decodes independently. Round-trips through
    /// `RFC5322Parse.decodeRFC2047`.
    static func encodeHeaderValue(_ value: String) -> String {
        let needsEncoding = value.contains { character in
            !character.isASCII || character.unicodeScalars.contains(where: isForbiddenLiteralInHeader)
        }
        guard needsEncoding else { return value }
        return encodeAsWords(value)
    }

    /// Encode ONLY when `value` cannot be emitted literally in a header body —
    /// non-ASCII text is returned unchanged.
    ///
    /// For the IMAP/SMTP path, where **SwiftMail is the emitter**: it already
    /// applies `String.rfc2047EncodedHeader()` to the subject, so non-ASCII is its
    /// job and re-encoding here would change nothing on the wire while enlarging
    /// the diff. What it does *not* do is catch a control character — its guard is
    /// the same `!$0.isASCII` this file's used to be — so that half, and only that
    /// half, has to happen before the value crosses the boundary. Deliberately
    /// narrower than `encodeHeaderValue`, which the Gmail builders need because
    /// there we are the emitter.
    static func encodeIfNotEmittableLiterally(_ value: String) -> String {
        // Not named `unsafe`: that is a contextual keyword for Swift's strict
        // memory-safety expression marker and the parser rejects it here.
        let hasForbiddenLiteral = value.unicodeScalars.contains(where: isForbiddenLiteralInHeader)
        guard hasForbiddenLiteral else { return value }
        return encodeAsWords(value)
    }

    private static func encodeAsWords(_ value: String) -> String {

        var words: [String] = []
        var chunk: [UInt8] = []

        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
            chunk.removeAll(keepingCapacity: true)
        }

        for character in value {
            let bytes = Array(String(character).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > maxBytesPerWord {
                flush()
            }
            chunk.append(contentsOf: bytes)
        }
        flush()

        // CRLF+SPACE between adjacent encoded-words: the linear whitespace is
        // dropped on decode (RFC 2047 §6.2), reassembling the original text.
        return words.joined(separator: "\r\n ")
    }
}
