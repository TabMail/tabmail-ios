/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Pure RFC 5322 header parsing utilities for IMAP-fetched messages.
/// Mirror of `GmailParse` / `GraphParse` for the IMAP code path — produces
/// the same `MessageMetadata` DTO so downstream consumers (main app, future
/// NSE IMAP client) can be provider-agnostic.
///
/// Consumed on the main-app side by `IMAPProvider` (once adopted); the NSE
/// IMAP client (when IMAP NSE ships) will also use it. Note: this parser works
/// against pre-parsed header key/value pairs — it does not tokenize raw RFC 822
/// bytes, which SwiftMail already does on the main-app side.
enum RFC5322Parse {
    /// Build a `MessageMetadata` from already-parsed IMAP header fields.
    /// - Parameters:
    ///   - uid: IMAP UID as a String (used as `providerMessageId`).
    ///   - headers: Key→value pairs (last-wins on duplicates). Case-insensitive keys.
    ///   - internalDate: Fallback date when `Date` header is missing/unparseable.
    ///   - flags: IMAP flags (\Seen, \Flagged, $Replied, etc.) and custom keywords.
    ///   - hasAttachments: True if BODYSTRUCTURE indicates any attachments.
    ///   - snippet: Preview text extracted from body (may be empty).
    static func buildMetadata(
        uid: String,
        headers: [String: String],
        internalDate: Date?,
        flags: [String],
        hasAttachments: Bool,
        snippet: String = ""
    ) -> MessageMetadata? {
        func h(_ name: String) -> String? {
            for (k, v) in headers {
                if k.caseInsensitiveCompare(name) == .orderedSame { return v }
            }
            return nil
        }

        let subject = decodeRFC2047(h("Subject") ?? "")
        let fromRaw = h("From") ?? ""
        let toRaw = h("To") ?? ""
        let ccRaw = h("Cc") ?? ""
        let bccRaw = h("Bcc") ?? ""
        let replyToRaw = h("Reply-To")

        let rfc822 = h("Message-Id").map { EmailFilter.normalizeMessageId($0) }
        let inReplyTo = h("In-Reply-To").flatMap { EmailFilter.extractFirstMessageId($0) }
        let references: [String] = {
            guard let raw = h("References") else { return [] }
            return raw.components(separatedBy: .whitespacesAndNewlines)
                .compactMap { EmailFilter.extractFirstMessageId($0) }
        }()

        // Prefer RFC 5322 Date header; fall back to INTERNALDATE when missing or bogus.
        let date: Date = {
            if let dateStr = h("Date"), let parsed = parseRFC5322Date(dateStr) { return parsed }
            if let id = internalDate { return id }
            return Date()
        }()

        let from = EmailAddress.parse(decodeRFC2047(fromRaw))
        let to = splitAddressList(toRaw).map { EmailAddress.parse(decodeRFC2047($0)) }
        let cc = splitAddressList(ccRaw).map { EmailAddress.parse(decodeRFC2047($0)) }
        let bcc = splitAddressList(bccRaw).map { EmailAddress.parse(decodeRFC2047($0)) }
        let replyTo = replyToRaw.map { EmailAddress.parse(decodeRFC2047($0)) }

        let isRead = flags.contains("\\Seen")
        let isFlagged = flags.contains("\\Flagged")

        return MessageMetadata(
            providerMessageId: uid,
            threadId: nil,  // IMAP has no native thread id; consumer assembles via References.
            rfc822MessageId: rfc822,
            inReplyTo: inReplyTo,
            references: references,
            from: from,
            to: to, cc: cc, bcc: bcc,
            replyTo: replyTo,
            subject: subject,
            date: date,
            snippet: snippet,
            isRead: isRead, isFlagged: isFlagged,
            hasAttachments: hasAttachments,
            providerLabels: flags,  // Includes custom keywords (e.g. tm_reply, user labels).
            // IMAP push always targets INBOX (server-side IDLE proxy fires only
            // on INBOX). If an IMAP NSE client ever parses a non-INBOX message
            // it should fill this in from the SELECTed mailbox name.
            folderPath: "INBOX"
        )
    }

    /// Parse RFC 5322 date strings: "Wed, 12 Apr 2026 10:30:00 -0400" etc.
    /// Falls back through several common formats.
    static func parseRFC5322Date(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatters = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss ZZZZ",
            "EEE, d MMM yyyy HH:mm Z",
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in formatters {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Decode RFC 2047 encoded-word headers: `=?UTF-8?B?...?=` / `=?UTF-8?Q?...?=`.
    /// Minimal implementation — handles the common UTF-8 B/Q encodings seen in
    /// email Subject/From headers. Non-encoded content passes through unchanged.
    static func decodeRFC2047(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([BQbq])\\?([^?]*)\\?=",
                                              options: [])
        guard let regex else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var out = ""
        var cursor = 0
        var prevWasEncodedWord = false
        for m in matches {
            if m.range.location > cursor {
                let between = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                // RFC 2047 §6.2: linear whitespace separating two adjacent
                // encoded-words is removed on decode (it only existed to allow
                // folding). Whitespace between an encoded-word and plain text is
                // preserved.
                let isInterWordFold = prevWasEncodedWord
                    && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !isInterWordFold {
                    out += between
                }
            }
            let charsetName = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let charset = charsetFor(charsetName)
            if enc == "B", let data = Data(base64Encoded: payload),
               let decoded = String(data: data, encoding: charset) {
                out += decoded
            } else if enc == "Q" {
                let unquoted = payload.replacingOccurrences(of: "_", with: " ")
                if let decoded = decodeQuotedPrintable(unquoted, encoding: charset) {
                    out += decoded
                } else {
                    out += payload
                }
            } else {
                out += payload
            }
            cursor = m.range.location + m.range.length
            prevWasEncodedWord = true
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func charsetFor(_ name: String) -> String.Encoding {
        switch name.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "ISO-8859-1", "LATIN1": return .isoLatin1
        case "US-ASCII", "ASCII": return .ascii
        case "UTF-16": return .utf16
        default: return .utf8
        }
    }

    private static func decodeQuotedPrintable(_ s: String, encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "=" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                let after = s.index(after: next)
                guard after <= s.endIndex, after != next else { break }
                let hex = String(s[next..<s.index(next, offsetBy: min(2, s.distance(from: next, to: s.endIndex)))])
                if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    i = s.index(i, offsetBy: 3)
                    continue
                }
            }
            for b in String(c).utf8 { bytes.append(b) }
            i = s.index(after: i)
        }
        return String(data: Data(bytes), encoding: encoding)
    }

    /// Split an RFC 2822 address list handling quoted display names with commas.
    private static func splitAddressList(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for c in trimmed {
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if c == "," && !inQuotes {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
                continue
            }
            current.append(c)
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
