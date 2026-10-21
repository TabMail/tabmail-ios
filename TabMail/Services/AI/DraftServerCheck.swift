/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum DraftServerCheckConfig {
    /// How long Save waits for the server check before saving locally anyway.
    /// The upload re-checks, so a slow or offline check never blocks a save.
    static let saveCheckTimeoutSeconds: TimeInterval = 8
}

/// #217 (ADR-IOS-091): the text a draft check compares — subject, To, Cc and body,
/// each normalized so that a server re-formatting the same draft never reads as an
/// edit:
/// - subject: whitespace collapsed; the "(no subject)" servers substitute for an
///   empty subject counts as empty;
/// - To / Cc: the bare addresses, lowercased and sorted (display names dropped);
/// - body: through the same HTML-to-text conversion on both sides, with every
///   whitespace character removed. Only the body is HTML.
/// Bcc is not compared: TabMail's IMAP and Gmail drafts never carry it to the
/// server, so the server copy cannot be compared on it.
enum DraftServerText {
    /// A draft as this device writes it (`pushDraftToServer` sends this content).
    static func local(subject: String, to: [String], cc: [String], body: String) -> String {
        combine(subject: subject,
                to: Draft.parseRecipients(to.joined(separator: ", ")),
                cc: Draft.parseRecipients(cc.joined(separator: ", ")),
                bodyHTML: EmailFilter.plainTextToHTML(body))
    }

    static func local(_ draft: Draft) -> String {
        local(subject: draft.subject, to: draft.toArray, cc: draft.ccArray, body: draft.body)
    }

    /// A copy read from the server.
    static func of(_ copy: FullMessageInfo) -> String {
        server(subject: copy.header.subject, to: copy.header.to, cc: copy.header.cc,
               html: copy.htmlBody, text: copy.textBody)
    }

    /// A copy synced into a Drafts header plus its fetched body (adoption, reload).
    static func of(_ header: MessageHeader, html: String?) -> String {
        server(subject: header.subject, to: header.to, cc: header.cc, html: html, text: nil)
    }

    private static func server(
        subject: String, to: String, cc: String, html: String?, text: String?
    ) -> String {
        let bodyHTML: String
        if let html, !html.isEmpty {
            bodyHTML = html
        } else {
            bodyHTML = EmailFilter.plainTextToHTML(text ?? "")
        }
        return combine(subject: subject,
                       to: Draft.parseRecipients(to),
                       cc: Draft.parseRecipients(cc),
                       bodyHTML: bodyHTML)
    }

    private static func combine(subject: String, to: [String], cc: [String], bodyHTML: String) -> String {
        [normalizedSubject(subject), addresses(to), addresses(cc), bodyText(bodyHTML)]
            .joined(separator: "\n")
    }

    static func normalizedSubject(_ subject: String) -> String {
        let collapsed = subject.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.lowercased() == "(no subject)" ? "" : collapsed
    }

    private static func addresses(_ list: [String]) -> String {
        list.map { $0.lowercased() }.filter { !$0.isEmpty }.sorted().joined(separator: ",")
    }

    static func bodyText(_ html: String) -> String {
        let plain = EmailFilter.htmlToPlainText(html)
        return String(String.UnicodeScalarView(
            plain.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
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

    enum OpenAction: Equatable, Sendable {
        /// Open the row as it is.
        case open
        /// The row has no unsent edits and the server copy changed: refresh it first.
        case reload
        /// The row has unsent edits and the server copy changed: ask the user.
        case ask(text: String)
        /// The row has no unsent edits and the server copy is gone.
        case unavailable
    }

    /// What opening a draft does. A clean row (`"pushed"`) holds nothing the server
    /// lacks, so it simply follows the server. A row with unsent edits keeps them
    /// unless the server copy provably changed since they were started.
    static func openAction(
        base: String?,
        status: String?,
        current: String?
    ) -> OpenAction {
        let clean = status == "pushed"
        guard let current else {
            // Unsent edits on a vanished draft open as they are; the upload then
            // saves them as a new draft.
            return clean ? .unavailable : .open
        }
        if current == base { return .open }
        if clean { return .reload }
        return base == nil ? .open : .ask(text: current)
    }
}
