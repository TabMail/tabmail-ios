/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// #272: one text/plain or text/html body part of a draft, in the order its MIME
/// tree gives it. A draft reader narrows each `multipart/alternative` to one
/// representation first (RFC 2046 section 5.1.4: alternatives are versions of one
/// body); the pieces of every other multipart (mixed, related, ...) are one body,
/// joined in order.
enum DraftBodyPiece: Equatable {
    case text(String)
    case html(String)

    /// The body fields of a draft copy. A body all of one kind keeps it, and its
    /// HTML is converted once, by `ExternalDraftAdoption.editableBody`. A body of
    /// both kinds is converted here, piece by piece, with that same converter, so
    /// neither kind is dropped for the other. Nil fields: no body part at all.
    static func body(of pieces: [DraftBodyPiece]) -> (text: String?, html: String?) {
        guard !pieces.isEmpty else { return (nil, nil) }
        let texts = pieces.compactMap { piece -> String? in
            if case .text(let text) = piece { return text }
            return nil
        }
        let htmls = pieces.compactMap { piece -> String? in
            if case .html(let html) = piece { return html }
            return nil
        }
        if htmls.isEmpty { return (joinedOnLines(texts), nil) }
        if texts.isEmpty { return (nil, htmls.joined()) }
        return (joinedOnLines(pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .html(let html): EmailFilter.htmlToPlainText(html, keepingSpacing: true)
            }
        }), nil)
    }

    /// The pieces joined in order. A line break is added only where neither side of
    /// a join has one, so one piece never runs into the next.
    private static func joinedOnLines(_ pieces: [String]) -> String {
        pieces.reduce(into: "") { body, piece in
            if let last = body.last, !last.isNewline, let first = piece.first, !first.isNewline {
                body += "\n"
            }
            body += piece
        }
    }
}
