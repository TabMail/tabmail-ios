/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// RFC 2047 "encoded-word" encoding for outgoing email Subject values at
/// TabMail's Gmail and IMAP/SMTP raw-header boundaries.
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
    /// Max UTF-8 bytes per continuation encoded-word. `=?UTF-8?B?` (10) + `?=` (2) is 12
    /// octets of overhead and Base64 of N bytes is `4*ceil(N/3)`; 45 bytes → 60
    /// Base64 chars → a 72-octet word, safely under RFC 2047 §2's 75-octet
    /// per-encoded-word ceiling.
    private static let maxBytesPerContinuationWord = 45

    /// The first word shares its physical line with the nine-octet `Subject: `
    /// prefix. 39 UTF-8 bytes become a 64-octet encoded-word, so the complete
    /// first encoded line is 73 octets. 40 bytes would expand to a 68-octet word
    /// and a 77-octet line. Continuation lines spend one leading WSP octet and
    /// use the wider continuation budget above.
    private static let maxBytesPerFirstSubjectWord = 39

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

    /// The app's two shipped readers use the same unanchored encoded-word pattern:
    /// `RFC5322Parse.decodeRFC2047` for Gmail and `String.decodeMIMEHeader` from
    /// SwiftMail for IMAP. They therefore consume a complete syntactically shaped
    /// substring even when it is not at the RFC 2047 §6.1 word boundary. Protect
    /// every substring they would consume so send -> readback preserves the exact
    /// semantic Subject value. Bare and unterminated shapes do not match.
    private static func containsDecoderConsumableEncodedWordSubstring(_ value: String) -> Bool {
        value.range(
            of: #"=\?[^?]+\?[BQbq]\?[^?]*\?="#,
            options: .regularExpression
        ) != nil
    }

    /// Find complete encoded-word-like tokens at the field start or after SP/HTAB.
    /// RFC 2047 §6.1 reader recognition additionally requires the complete §2
    /// syntax and 75-octet ceiling. RFC 2047 §7 gives composers a stronger
    /// obligation: a boundary word that begins with `=?` and ends with `?=` must
    /// be a valid encoded-word. Protecting the entire value therefore also covers
    /// complete malformed/oversized composer words, including the minimal `=?=`,
    /// without over-encoding a bare or unterminated shape.
    ///
    /// Split the scalar view because SP/HTAB and the ASCII delimiters are wire
    /// syntax, not user-perceived grapheme boundaries. CR/LF never reaches this
    /// classification as a literal: the forbidden-control trigger encodes it.
    private static func containsBoundaryEncodedWordLikeToken(_ value: String) -> Bool {
        value.unicodeScalars.split(whereSeparator: { scalar in
            scalar.value == 0x20 || scalar.value == 0x09 // SP / HTAB
        }).contains { token in
            guard token.count >= 3,
                  token.first?.value == 0x3D, // `=`
                  token.dropFirst().first?.value == 0x3F, // `?`
                  token.dropLast().last?.value == 0x3F, // `?`
                  token.last?.value == 0x3D // `=`
            else { return false }
            return true
        }
    }

    /// Encode `value` as one or more RFC 2047 Base64 encoded-words when it
    /// contains any non-ASCII scalar, any scalar that cannot appear literally in
    /// a header field body, a complete substring consumed by either shipped
    /// decoder, or a complete boundary composer word shaped like an encoded-word;
    /// otherwise it is returned unchanged (already a valid header value).
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
        } || containsDecoderConsumableEncodedWordSubstring(value)
            || containsBoundaryEncodedWordLikeToken(value)
        guard needsEncoding else { return value }
        return encodeAsWords(value)
    }

    private static func encodeAsWords(_ value: String) -> String {

        var words: [String] = []
        var chunk: [UInt8] = []
        var byteBudget = maxBytesPerFirstSubjectWord

        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
            chunk.removeAll(keepingCapacity: true)
            byteBudget = maxBytesPerContinuationWord
        }

        for scalar in value.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > byteBudget {
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
