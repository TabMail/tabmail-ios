/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Builds the unified `<div class="tm-eml-section">` marker block used to
/// inline-embed attached `.eml` content into a message's `htmlContent`.
///
/// All three providers (IMAP, Gmail, Exchange) call `build(...)` so every
/// nested `.eml` renders identically in `MessageCardView` and
/// `EmlAttachmentPreview`, and so `EmailFilter.parseEmlSectionMetadata` can
/// consume the output uniformly regardless of provider.
///
/// The HTML shape (locked — tested via `IMAPProviderEmlRenderTests` and
/// `EmailFilterStripEmlTests`):
///
/// ```
/// <div class="tm-eml-section" data-filename="..." data-part-section="..."
///      [data-subject="..."] [data-from="..."] [data-date="<ISO8601>"]
///      [data-to="..."] [data-cc="..."]>
///     <div class="tm-eml-headers">
///         <div>...filename banner...</div>
///         <table>...Subject/From/Date/To/CC rows...</table>
///     </div>
///     <div class="tm-email-body">
///         ...the nested body HTML, with <html>/<head>/<style>/<meta> stripped
///     </div>
/// </div>
/// ```
///
/// Pure — no provider types, no I/O. Safe to call from NSE.
enum EmlMarker {

    /// Envelope fields pulled from the nested message's headers. Provider-agnostic
    /// so IMAP `MessageInfo`, Gmail part `headers`, and Exchange `itemAttachment.item`
    /// all map to the same shape.
    struct Envelope: Sendable, Equatable {
        var subject: String?
        var from: String?
        var date: Date?
        var to: [String]
        var cc: [String]

        init(subject: String? = nil, from: String? = nil, date: Date? = nil,
             to: [String] = [], cc: [String] = []) {
            self.subject = subject
            self.from = from
            self.date = date
            self.to = to
            self.cc = cc
        }
    }

    /// Build the complete `<div class="tm-eml-section">…</div>` block for a nested
    /// `.eml` attachment.
    ///
    /// - Parameters:
    ///   - filename: Attachment filename (e.g. `"Re Quarterly Plan.eml"`). Used in
    ///     `data-filename` and as the label in the header banner.
    ///   - partSection: Opaque section identifier — IMAP uses `"2.1"`-style paths,
    ///     Gmail uses the attachment ID, Exchange uses the `itemAttachment.id`.
    ///     Used in `data-part-section` and as the key for
    ///     `AttachmentInfo.parentEmlSection` matching.
    ///   - envelope: Subject/from/date/to/cc carried on the marker.
    ///   - bodyHtml: Raw HTML of the nested message's body. Passed through
    ///     `extractBodyContent` which strips `<html>/<head>/<style>/<meta>` and
    ///     wraps in `<div class="tm-email-body">`.
    static func build(filename: String, partSection: String, envelope: Envelope, bodyHtml: String) -> String {
        var attrs = "data-filename=\"\(escapeHtml(filename))\""
        attrs += " data-part-section=\"\(escapeHtml(partSection))\""
        if let subject = envelope.subject {
            attrs += " data-subject=\"\(escapeHtml(subject))\""
        }
        if let from = envelope.from {
            attrs += " data-from=\"\(escapeHtml(from))\""
        }
        if let date = envelope.date {
            let iso = date.iso8601String()
            attrs += " data-date=\"\(escapeHtml(iso))\""
        }
        if !envelope.to.isEmpty {
            attrs += " data-to=\"\(escapeHtml(envelope.to.joined(separator: ", ")))\""
        }
        if !envelope.cc.isEmpty {
            attrs += " data-cc=\"\(escapeHtml(envelope.cc.joined(separator: ", ")))\""
        }
        var html = "<div class=\"tm-eml-section\" \(attrs)>"
        html += "<div class=\"tm-eml-headers\">"
        html += embeddedHeadersHtml(envelope: envelope, filename: filename)
        html += "</div>"
        html += extractBodyContent(from: bodyHtml)
        html += "</div>"
        return html
    }

    /// Build the plain-text envelope block used when the top-level message is
    /// rendered as `text/plain`. Matches the old IMAP `embeddedHeadersPlainText`
    /// format so FTS plain-text output is unchanged.
    static func embeddedHeadersPlainText(envelope: Envelope, filename: String?) -> String {
        var text = "\n"
        if let filename {
            text += "--- \(filename) ---\n"
        } else {
            text += "---\n"
        }
        if let subject = envelope.subject { text += "Subject: \(subject)\n" }
        if let from = envelope.from { text += "From: \(from)\n" }
        if let date = envelope.date { text += "Date: \(dateFormatter.string(from: date))\n" }
        if !envelope.to.isEmpty { text += "To: \(envelope.to.joined(separator: ", "))\n" }
        if !envelope.cc.isEmpty { text += "CC: \(envelope.cc.joined(separator: ", "))\n" }
        text += "\n"
        return text
    }

    // MARK: - HTML helpers (exposed for reuse)

    /// Render the envelope as an HTML header block (filename banner + Subject/From/Date/To/CC table).
    /// Output is wrapped by `build(...)` in `<div class="tm-eml-headers">` but also exposed so
    /// providers can render the banner without the marker wrapper if needed.
    static func embeddedHeadersHtml(envelope: Envelope, filename: String?) -> String {
        var html = ""
        if let filename {
            html += "<div style=\"border:1px solid #ccc;border-radius:4px;padding:4px 8px;margin:12px 0 8px 0;font-size:13px;color:#555;\">"
            html += "<b>\(escapeHtml(filename))</b></div>"
        }
        var headerRows = ""
        if let subject = envelope.subject {
            headerRows += "<tr><td><b>Subject:</b> \(escapeHtml(subject))</td></tr>"
        }
        if let from = envelope.from {
            headerRows += "<tr><td><b>From:</b> \(escapeHtml(from))</td></tr>"
        }
        if let date = envelope.date {
            headerRows += "<tr><td><b>Date:</b> \(escapeHtml(dateFormatter.string(from: date)))</td></tr>"
        }
        if !envelope.to.isEmpty {
            headerRows += "<tr><td><b>To:</b> \(escapeHtml(envelope.to.joined(separator: ", ")))</td></tr>"
        }
        if !envelope.cc.isEmpty {
            headerRows += "<tr><td><b>CC:</b> \(escapeHtml(envelope.cc.joined(separator: ", ")))</td></tr>"
        }
        if !headerRows.isEmpty {
            html += "<table style=\"border-collapse:collapse;margin-bottom:8px;font-size:13px;color:#333;\">"
            html += headerRows
            html += "</table>"
        }
        return html
    }

    /// Extract only the `<body>` inner content from a full HTML document and
    /// wrap it in `<div class="tm-email-body">`. The wrapper class is what lets
    /// the main-app CSS target embedded-email content for font/spacing
    /// overrides without leaking styles onto the outer wrapper's body.
    ///
    /// Strips `<html>`, `<head>`, `<style>`, `<meta>`, DOCTYPE. If no `<body>`
    /// tag is present (fragment input), strips any `<style>` blocks anywhere
    /// and wraps the remainder.
    static func extractBodyContent(from html: String) -> String {
        var inner: String
        if let bodyStartRange = html.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let bodyEndRange = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            inner = String(html[bodyStartRange.upperBound..<bodyEndRange.lowerBound])
        } else {
            inner = html
            if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>[\s\S]*?</style>"#, options: .caseInsensitive) {
                inner = styleRegex.stringByReplacingMatches(in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")
            }
        }
        // Also strip any <style> blocks left inside body content (Outlook sometimes
        // puts them outside <head>). These are dangerous — they leak globally.
        if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>[\s\S]*?</style>"#, options: .caseInsensitive) {
            inner = styleRegex.stringByReplacingMatches(in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")
        }
        return "<div class=\"tm-email-body\">\(inner)</div>"
    }

    static func escapeHtml(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Long-form date used inside the envelope table (`"Oct 2, 2025 at 01:50"`).
    /// Distinct from the ISO-8601 string stored in `data-date` on the marker,
    /// which is machine-readable for `parseEmlSectionMetadata`.
    static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()
}
