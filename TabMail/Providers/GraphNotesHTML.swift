/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// An Outlook event's notes, as the app reads and edits them (plain text, links as
/// `[label](destination)`), written back as the HTML `body` Graph stores (#577).
/// A read of what this writes gives the same notes again, up to white space
/// at the ends of lines and of the notes.
enum GraphNotesHTML {
    /// The link schemes new notes write as links: web, mail and phone. A link with
    /// any other destination stays as its text.
    static let linkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Plain-text notes as HTML, the reverse of how a read gives them
    /// (`EmailFilter.htmlToPlainText` keeping the spacing): each line break a
    /// `<br>`, each `[label](destination)` link (`EmailFilter.markdownPieces`)
    /// with a `linkSchemes` destination an `<a>`, and runs of spaces kept with
    /// no-break spaces. Everything else is escaped text. Trailing line breaks are
    /// dropped: in an online meeting's body a `<br>` right before the join section
    /// would be read as part of it (`GraphOnlineMeetingBody`) and kept by every
    /// later edit.
    static func html(_ notes: String) -> String {
        var text = Substring(notes)
        while text.last?.isNewline == true { text = text.dropLast() }
        return String(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { lineHTML(String($0)) }
            .joined(separator: "<br>\r\n")
    }

    /// One line of notes as HTML. A Markdown link never spans a line.
    private static func lineHTML(_ line: String) -> String {
        var spacing = Spacing()
        var html = ""
        for piece in EmailFilter.markdownPieces(line) {
            switch piece {
            case .text(let text):
                html += spacing.html(text)
            case .link(let label, let destination, let source):
                guard isWritableLink(destination) else {
                    html += spacing.html(source)
                    continue
                }
                html += "<a href=\"" + escaped(destination, inAttribute: true) + "\">" + spacing.html(label) + "</a>"
            }
        }
        return spacing.endingLine(html)
    }

    private static func isWritableLink(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return false }
        return linkSchemes.contains(destination[..<colon].lowercased())
    }

    /// `text` with `&`, `<` and `>` as entities, and `"` too in an attribute value.
    private static func escaped(_ text: String, inAttribute: Bool) -> String {
        var out = ""
        for scalar in text.unicodeScalars { append(scalar, to: &out, inAttribute: inAttribute) }
        return out
    }

    /// One Unicode scalar, escaped. Scalar by scalar, never by character: a quote or
    /// `<` joined to a combining mark is one character, and a match on characters
    /// would leave it raw.
    private static func append(_ scalar: Unicode.Scalar, to out: inout String, inAttribute: Bool) {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"" where inAttribute: out += "&quot;"
        default: out.unicodeScalars.append(scalar)
        }
    }

    /// Escapes text and keeps its spaces as a page shows them: a space that starts
    /// the line, follows another space or ends the line is a no-break space.
    private struct Spacing {
        private var afterSpace = true

        mutating func html(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case " ":
                    out += afterSpace ? "&nbsp;" : " "
                    afterSpace = true
                    continue
                default: GraphNotesHTML.append(scalar, to: &out, inAttribute: false)
                }
                afterSpace = false
            }
            return out
        }

        /// `html` with a space it ends in made a no-break space.
        func endingLine(_ html: String) -> String {
            guard html.hasSuffix(" ") else { return html }
            return String(html.dropLast()) + "&nbsp;"
        }
    }
}
