/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// An online meeting's HTML body as Microsoft Graph stores it: the organizer's
/// notes, then the join section the meeting provider adds (a line of
/// underscores, the join links and dial-in details, a closing line).
///
/// Graph's event-update: "Before updating the body of an event that has been set
/// up as an online meeting, be sure to first get the body property, apply the
/// appropriate changes to the content, and preserve the meeting blob for online
/// meeting. Inadvertently removing the meeting blob from the body would disable
/// meeting online." So a description edit of an online meeting replaces only the
/// notes (#511).
///
/// Checked live on a meeting made in Teams on a work account (#555): a text body
/// write turned the meeting off (`isOnlineMeeting` false, `onlineMeeting` null,
/// the join section gone), and an HTML write that changed only the notes kept
/// it. That meeting's join section was an outer `<div>` opening with three
/// `<br>`, holding a block that starts and ends with a line of 80 underscores,
/// with two join links (a short "Join:" link and the long `meetup-join` one).
/// Graph's online-meeting samples
/// (learn.microsoft.com/en-us/graph/outlook-calendar-online-meetings) show an
/// older layout with the same lines. Both are recognised.
enum GraphOnlineMeetingBody {
    /// The fewest underscores in a row that make the join section's separator
    /// line. Graph's samples draw it with 80.
    static let separatorMinUnderscores = 20

    /// `html` with its notes replaced by `notes` (plain text), and the join
    /// section and everything after it kept exactly as stored. Nil when the join
    /// section is not recognised (`joinSection`).
    static func replacingNotes(in html: String, joinUrl: String, with notes: String) -> String? {
        guard let found = joinSection(in: html, joinUrl: joinUrl) else { return nil }
        return String(html[..<found.notesStart]) + "\r\n" + notesHTML(notes) + "\r\n" + String(html[found.sectionStart...])
    }

    /// `html` up to its join section: the document's start and the notes, which
    /// `ExchangeCalendarProvider.notes(of:)` reads as the description. Nil when
    /// the join section is not recognised.
    static func beforeJoinSection(_ html: String, joinUrl: String) -> Substring? {
        joinSection(in: html, joinUrl: joinUrl).map { html[..<$0.sectionStart] }
    }

    /// Where the notes start (after the `<body>` tag, or at the start when there
    /// is none) and where the join section starts: at the element holding the
    /// last separator line before the first link to `joinUrl` (as written, or
    /// with `&` as `&amp;`) that has one before it. A copy of the link in the
    /// notes, with no separator line above it, is passed over. Nil when no link
    /// has a separator line before it, or the `<body` tag never closes.
    ///
    /// Taking the first such link can only place the section too EARLY (at a
    /// separator-like line in the notes above a copy of the link), which keeps
    /// the whole join section; it never places it inside the section.
    ///
    /// A link has a separator line before it exactly when it starts after the
    /// point where the first separator line is complete, so the link is found by
    /// one search from there. Each step is a single pass, so the work stays
    /// linear in the body however many copies of the link the organizer's notes
    /// hold.
    private static func joinSection(in html: String, joinUrl: String) -> (notesStart: String.Index, sectionStart: String.Index)? {
        guard !joinUrl.isEmpty, let notesStart = bodyContentStart(html),
              let firstSeparatorEnd = firstSeparatorEnd(in: html, from: notesStart) else { return nil }
        let forms = [joinUrl, joinUrl.replacingOccurrences(of: "&", with: "&amp;")]
        guard let link = forms.compactMap({ html.range(of: $0, range: firstSeparatorEnd..<html.endIndex)?.lowerBound }).min(),
              let separator = lastSeparator(in: html, from: notesStart, before: link) else { return nil }
        return (notesStart, openingTagsStart(in: html, before: separator, floor: notesStart))
    }

    /// Just past the underscore at which the first run in `html[from...]`
    /// reaches `separatorMinUnderscores`. Nil when no run does.
    private static func firstSeparatorEnd(in html: String, from: String.Index) -> String.Index? {
        var runLength = 0
        var i = from
        while i < html.endIndex {
            if html[i] == "_" {
                runLength += 1
                if runLength == separatorMinUnderscores { return html.index(after: i) }
            } else {
                runLength = 0
            }
            i = html.index(after: i)
        }
        return nil
    }

    /// Where the body's content starts: after the `<body …>` tag, or at the start
    /// when there is none. Nil for a `<body` tag that never closes.
    private static func bodyContentStart(_ html: String) -> String.Index? {
        var from = html.startIndex
        while let open = html.range(of: "<body", options: .caseInsensitive, range: from..<html.endIndex) {
            let next = open.upperBound
            if next < html.endIndex, html[next] == ">" || html[next].isWhitespace {
                guard let close = html[next...].firstIndex(of: ">") else { return nil }
                return html.index(after: close)
            }
            from = next
        }
        return html.startIndex
    }

    /// The start of the last run of at least `separatorMinUnderscores`
    /// underscores in `html[from..<end]`.
    private static func lastSeparator(in html: String, from: String.Index, before end: String.Index) -> String.Index? {
        var found: String.Index?
        var runStart: String.Index?
        var runLength = 0
        var i = from
        while i < end {
            if html[i] == "_" {
                if runStart == nil {
                    runStart = i
                    runLength = 0
                }
                runLength += 1
                if runLength == separatorMinUnderscores { found = runStart }
            } else {
                runStart = nil
            }
            i = html.index(after: i)
        }
        return found
    }

    /// `index`, moved back over the opening tags (and the whitespace between
    /// them) that directly precede it, so the separator's elements belong to the
    /// join section. Stops at a closing tag, a comment, a self-closing tag, text,
    /// or `floor`.
    private static func openingTagsStart(in html: String, before index: String.Index, floor: String.Index) -> String.Index {
        var start = index
        while true {
            var end = start
            while end > floor, html[html.index(before: end)].isWhitespace { end = html.index(before: end) }
            guard end > floor, html[html.index(before: end)] == ">",
                  let open = html[floor..<end].lastIndex(of: "<")
            else { return start }
            let tag = html[open..<end]
            guard !tag.hasPrefix("</"), !tag.hasPrefix("<!"), !tag.hasSuffix("/>") else { return start }
            start = open
        }
    }

    /// Plain-text notes as HTML: escaped, each line break a `<br>`. Trailing line
    /// breaks are dropped: a `<br>` right before the join section would be read
    /// as part of it (`openingTagsStart`) and kept by every later edit.
    private static func notesHTML(_ notes: String) -> String {
        var text = Substring(notes)
        while text.last?.isNewline == true { text = text.dropLast() }
        return ICSBuilder.escapeHTML(String(text))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>\r\n")
    }
}
