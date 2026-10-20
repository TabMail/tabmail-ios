/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Parsed `mailto:` URL. Populated from in-app WKWebView link taps, external
/// `.onOpenURL` callbacks, and internal contact-pill compose posts.
///
/// RFC 6068: `mailto:to?subject=...&cc=...&bcc=...&body=...`. Multiple
/// recipients are comma-separated in the path (or in `to=` query) and also
/// allowed as comma-separated strings in `cc=` / `bcc=`. Each value is kept
/// whole; compose splits it into recipients.
struct MailtoRequest: Equatable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String?
    var body: String?

    init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String? = nil, body: String? = nil) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Parse an RFC 6068 `mailto:` URL. Returns `nil` for non-mailto schemes or
    /// URLs with no recipients at all.
    static func parse(_ url: URL) -> MailtoRequest? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        // URLComponents on a mailto: URL exposes the recipient list via
        // `path` and the header fields via `queryItems`. We also support the
        // query-form `to=` (non-standard but used by some clients).
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var to = recipientText(components?.path ?? "")
        var cc: [String] = []
        var bcc: [String] = []
        var subject: String?
        var body: String?

        for item in components?.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "to": to.append(contentsOf: recipientText(value))
            case "cc": cc.append(contentsOf: recipientText(value))
            case "bcc": bcc.append(contentsOf: recipientText(value))
            case "subject": subject = value
            case "body": body = value
            default: break
            }
        }

        if to.isEmpty && cc.isEmpty && bcc.isEmpty { return nil }
        return MailtoRequest(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    /// Read a MailtoRequest out of a NotificationCenter userInfo dict.
    /// Accepts either the structured form (`to`/`cc`/`bcc`/`subject`/`body`)
    /// or the legacy contact-pill form (`email`) used by MarkdownChatText.
    static func from(userInfo: [AnyHashable: Any]?) -> MailtoRequest? {
        let to = userInfo?["to"] as? [String] ?? []
        let cc = userInfo?["cc"] as? [String] ?? []
        let bcc = userInfo?["bcc"] as? [String] ?? []
        let subject = userInfo?["subject"] as? String
        let body = userInfo?["body"] as? String
        if !to.isEmpty || !cc.isEmpty || !bcc.isEmpty {
            return MailtoRequest(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        }
        if let email = userInfo?["email"] as? String, !email.isEmpty {
            return MailtoRequest(to: [email], subject: subject, body: body)
        }
        return nil
    }

    /// Serialize this request to a NotificationCenter userInfo dict so it can
    /// round-trip through `.contactPillComposeTapped`.
    func toUserInfo() -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if !to.isEmpty { info["to"] = to }
        if !cc.isEmpty { info["cc"] = cc }
        if !bcc.isEmpty { info["bcc"] = bcc }
        if let subject { info["subject"] = subject }
        if let body { info["body"] = body }
        // Backward-compat: older listeners read `email` as a single string.
        if let first = to.first { info["email"] = first }
        return info
    }

    /// The recipient text as the link wrote it. Compose splits it
    /// (`RecipientEntry`, ADR-IOS-092); splitting here on every comma would
    /// break a quoted name such as `"Doe, John" <john@example.com>`.
    private static func recipientText(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }
}
