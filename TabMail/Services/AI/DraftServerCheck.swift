/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum DraftServerCheckConfig {
    /// How long opening or saving a draft waits for the server check before going
    /// ahead with the local copy. Save and the upload re-check, so a slow or offline
    /// check never blocks the user.
    static let checkTimeoutSeconds: TimeInterval = 8
}

/// #217 (ADR-IOS-091): the text a draft check compares — subject, To, Cc, Bcc,
/// attachment names and body, each normalized so that a server re-formatting the
/// same draft never reads as an edit:
/// - subject: whitespace collapsed; the "(no subject)" servers substitute for an
///   empty subject counts as empty;
/// - To / Cc / Bcc: the addresses `RecipientEntry` reads, lowercased and sorted
///   (display names and text that is no address dropped). ACCEPTED LIMITATION
///   (owner 2026-10-21, #230): IMAP servers rewrite text that is no address in
///   the summary we read, so comparing it would report a change after every save;
///   a change to that text alone goes unnoticed;
/// - attachments: the file names, sorted. Inline images count under the name
///   adoption gives them (`ExternalDraftAdoption.inlineImageFilename`), so a copy
///   this device uploads after adopting them compares equal to the original.
///   ACCEPTED LIMITATION (owner 2026-10-21, #229): names only, so a file swapped
///   for another under the same name goes unnoticed;
/// - body: through the same HTML-to-text conversion on both sides, every run of
///   whitespace collapsed to one space. Only the body is HTML.
enum DraftServerText {
    /// A draft as this device sends it (`pushDraftToServer`'s payload).
    static func of(_ message: DraftMessage) -> String {
        combine(subject: message.subject,
                to: RecipientEntry(message.to), cc: RecipientEntry(message.cc),
                bcc: RecipientEntry(message.bcc),
                // A calendar invitation part is not an attachment on the server.
                attachmentNames: message.attachments.filter { !$0.isAlternative }.map(\.filename),
                bodyHTML: message.isHTML ? message.body : EmailFilter.plainTextToHTML(message.body))
    }

    /// A copy read from the server.
    static func of(_ copy: FullMessageInfo) -> String {
        let bodyHTML: String
        if let html = copy.htmlBody, !html.isEmpty {
            bodyHTML = html
        } else {
            bodyHTML = EmailFilter.plainTextToHTML(copy.textBody ?? "")
        }
        // Top-level only: parts nested inside an attached `.eml` travel inside it.
        let attachmentNames = copy.attachments.filter { $0.parentEmlSection == nil }.map(\.filename)
            + copy.inlineImages.enumerated().map { ExternalDraftAdoption.inlineImageFilename($1, index: $0) }
        return combine(subject: copy.header.subject,
                       to: RecipientEntry(copy.header.to),
                       cc: RecipientEntry(copy.header.cc),
                       bcc: RecipientEntry(copy.header.bcc),
                       attachmentNames: attachmentNames,
                       bodyHTML: bodyHTML)
    }

    private static func combine(
        subject: String, to: RecipientEntry, cc: RecipientEntry, bcc: RecipientEntry,
        attachmentNames: [String], bodyHTML: String
    ) -> String {
        [normalizedSubject(subject), addresses(to), addresses(cc), addresses(bcc),
         attachmentNames.sorted().joined(separator: "/"), bodyText(bodyHTML)]
            .joined(separator: "\n")
    }

    static func normalizedSubject(_ subject: String) -> String {
        let collapsed = collapsedWhitespace(subject)
        return collapsed.lowercased() == "(no subject)" ? "" : collapsed
    }

    private static func addresses(_ entry: RecipientEntry) -> String {
        entry.addresses.map { $0.lowercased() }.sorted().joined(separator: ",")
    }

    static func bodyText(_ html: String) -> String {
        collapsedWhitespace(EmailFilter.htmlToPlainText(html))
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// #217 (ADR-IOS-091): has another app changed a draft's server copy since this
/// device last wrote or loaded it? `Draft.serverDraftText` is that local copy of
/// the draft's text (`DraftServerText`); a server copy whose text no longer matches
/// it was changed elsewhere.
///
/// OWNER RULING (2026-10-17): never keep a stale local copy; before saving, check
/// the server; if it changed, ask the user to Overwrite, Reload or Save as new.
/// The gap between a check and the write that follows it is an ACCEPTED race:
/// another app can save inside it, and ours then overwrites (`IOS-DRAFT-021`).
///
/// Pure, so the decisions are pinned by tests rather than by comments.
enum DraftServerCheck: Equatable, Sendable {
    case unchanged
    /// `text` is the server copy's current text (`DraftServerText`).
    case changed(text: String)
    case gone

    /// `base` is `Draft.serverDraftText`; `current` is the server copy's text, nil
    /// when the server no longer has the draft. A nil base is no evidence either way
    /// (a pre-v92 row), so it keeps the old last-save-wins behaviour instead of
    /// blocking every legacy draft.
    static func compare(base: String?, current: String?) -> DraftServerCheck {
        guard let current else { return .gone }
        guard let base else { return .unchanged }
        return current == base ? .unchanged : .changed(text: current)
    }
}
