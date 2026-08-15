/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// RFC 2047 "encoded-word" encoding for outgoing email *header* values
/// (Subject, etc.) at TabMail's Gmail and IMAP/SMTP provider boundaries.
///
/// RFC 5322 requires header field bodies to be 7-bit ASCII; non-ASCII text must
/// be wrapped in an encoded-word. Injecting raw 8-bit UTF-8 into a header
/// (which is what we did before) leaves downstream agents — Gmail's ingest MTA,
/// the receiving client — free to apply their own charset guesses, and a chain
/// of "UTF-8-read-as-Latin-1" guesses produces mojibake (e.g. Korean "가" →
/// "ÃªÂ°Â…"). Bodies are unaffected because they carry an explicit charset +
/// Content-Transfer-Encoding; headers have no mechanism other than RFC 2047.
///
/// Decoding is the inverse: `RFC5322Parse.decodeRFC2047`. Exchange is excluded:
/// its Graph JSON `subject` is semantic text, not an RFC 5322 field body.
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

    /// RFC 2047 readers recognize `=?` as an encoded-word introducer at the start
    /// of an unstructured field body or immediately after linear whitespace. If
    /// sender-authored ASCII contains it at either boundary, emitting it literally
    /// lets a reader reinterpret the following bytes instead of preserving the
    /// text. Compare scalars because this is a wire-format decision, not a
    /// user-perceived grapheme operation.
    private static func containsRecognizableEncodedWordIntroducer(_ value: String) -> Bool {
        var canStartEncodedWord = true
        var previousWasBoundaryEquals = false
        for scalar in value.unicodeScalars {
            if previousWasBoundaryEquals, scalar.value == 0x3F { return true } // `?`
            previousWasBoundaryEquals = canStartEncodedWord && scalar.value == 0x3D // `=`
            canStartEncodedWord = scalar.value == 0x20 || scalar.value == 0x09 // SP / HTAB
        }
        return false
    }

    /// Encode `value` as one or more RFC 2047 Base64 encoded-words when it
    /// contains any non-ASCII scalar, any scalar that cannot appear literally in
    /// a header field body, or the encoded-word introducer `=?`; otherwise it is
    /// returned unchanged (already a valid header value).
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
    /// 75-octet limit; a Unicode scalar's UTF-8 bytes are never split across
    /// words, so every word is independently valid UTF-8. Round-trips through
    /// `RFC5322Parse.decodeRFC2047`.
    static func encodeHeaderValue(_ value: String) -> String {
        let needsEncoding = value.unicodeScalars.contains { scalar in
            scalar.value > 0x7F || isForbiddenLiteralInHeader(scalar)
        } || containsRecognizableEncodedWordIntroducer(value)
        guard needsEncoding else { return value }
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

        for scalar in value.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
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
