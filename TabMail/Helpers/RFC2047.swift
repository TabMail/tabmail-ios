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

    /// Encode `value` as one or more RFC 2047 Base64 encoded-words when it
    /// contains any non-ASCII character; pure-ASCII input is returned unchanged
    /// (already a valid header value).
    ///
    /// Multiple words are folded with `CRLF SPACE` so each stays within the
    /// 75-octet limit; a character's UTF-8 bytes are never split across words, so
    /// each word decodes independently. Round-trips through
    /// `RFC5322Parse.decodeRFC2047`.
    static func encodeHeaderValue(_ value: String) -> String {
        guard value.contains(where: { !$0.isASCII }) else { return value }

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
