/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

/// Canonical builder for AI completion variable dictionaries. Consumed by both
/// the main app (AISummary/AIAction) and the NSE. Any new prompt variable is
/// added here once and automatically flows into every call path — this keeps
/// main-app and NSE prompt variables in parity.
///
/// Reply prompt variables are NOT here — NSE never generates replies (30s
/// window is summary + action only). Reply precompute stays in main app.
enum PromptVariables {
    /// Variables required for the `system_prompt_summary` completions template.
    /// Produces the canonical [String: Any] dict; serialization to JSONValue is
    /// left to each caller (main app wraps in CompletionsMessage.vars; NSE's
    /// BackendNSEClient builds the payload directly).
    static func summaryVariables(
        metadata: MessageMetadata,
        body: RenderedBody,
        account: AccountContext,
        recipientStatus: String = ""
    ) -> [String: Any] {
        let subject = metadata.subject.isEmpty ? "Not Available" : metadata.subject
        let fromSender = formatFromSender(metadata.from)
        let emailDate = PromptFormatters.formatTimestampForAgent(metadata.date)
        let emailDayOfWeek = PromptFormatters.dayOfWeek(metadata.date)
        let bodyText = body.textContent ?? ""
        let isNoReply = EmailFilter.isNoReply(metadata.from.email)
        let hasUnsubscribe = EmailFilter.hasUnsubscribeLink(body.htmlContent)

        var vars: [String: Any] = [
            "user_name": account.userName,
            "user_kb_content": account.kbText,
            "subject": subject,
            "from_sender": fromSender,
            "email_date": emailDate,
            "email_day_of_week": emailDayOfWeek,
            "body": bodyText,
            "is_noreply_address": isNoReply,
            "has_unsubscribe_link": hasUnsubscribe,
        ]
        // Field is omitted (not sent empty) when the user is a direct recipient
        // or their addresses can't be determined — backend injects the cc notice
        // only on a non-empty "cc" value (TB parity: summaryGenerator.js).
        if !recipientStatus.isEmpty {
            vars["recipient_status"] = recipientStatus
        }
        return vars
    }

    /// Recipient-status classification for the summary and action requests — parity with the
    /// TB addon's `senderFilter.classifyRecipientStatus`. Returns "cc" ONLY on
    /// positive evidence: one of `claimEmails` (the RECEIVING account's
    /// addresses) is literally present in the Cc field as an actual mailbox
    /// address (and not in To, and the user is not the author). Everything
    /// uncertain — aliases, Bcc, mailing-list delivery, empty `claimEmails` —
    /// returns "" (never claim cc without being sure).
    ///
    /// `suppressEmails` may carry EVERY address we know for the user (all
    /// registered accounts); it is unioned with `claimEmails` and used only
    /// for the suppress checks — more suppression can only prevent wrong claims.
    ///
    /// Matching asymmetry, on purpose: the SUPPRESS checks (author, To) use
    /// liberal extraction + loose matching (plus-tags stripped) since a wrong
    /// suppress is harmless; the CLAIM check (Cc) reads the field's mailboxes
    /// with SwiftMail's `AddressParser` + strict exact-address matching since a
    /// wrong claim is the failure mode this feature works hardest to avoid. An
    /// address inside a display name, comment or domain literal is never a
    /// mailbox, given producers that write RFC 5322 text
    /// (`IMAPFetchMapping.addressField`; Gmail keeps the raw header; Exchange
    /// stores bare addresses). TB reads Thunderbird's own field with its own
    /// scanner; the two differ only on malformed or crafted text.
    ///
    /// Fields are raw header strings (`"Name" <a@b>, c@d` shapes across
    /// Gmail/Graph/IMAP).
    static func classifyRecipientStatus(
        toField: String, ccField: String, fromField: String,
        claimEmails: [String], suppressEmails: [String] = []
    ) -> String {
        // Degenerate/adversarial header sizes → skip classification entirely
        // (omit, the safe answer) rather than feed the matchers unbounded input.
        guard toField.count <= maxRecipientFieldChars,
              ccField.count <= maxRecipientFieldChars,
              fromField.count <= maxRecipientFieldChars else { return "" }
        let claimSet = normalizeEmailSet(claimEmails)
        guard !claimSet.isEmpty else { return "" }
        let suppressSet = normalizeEmailSet(suppressEmails).union(claimSet)
        let suppressLoose = Set(suppressSet.map(stripPlusTag))

        // Self-authored → never claim (loose: self-sent via a plus-alias counts).
        if extractAllEmails(fromField).contains(where: { suppressLoose.contains(stripPlusTag($0)) }) {
            return ""
        }
        // Direct recipient → omit (loose: To hitting a plus-alias is still direct).
        if extractAllEmails(toField).contains(where: { suppressLoose.contains(stripPlusTag($0)) }) {
            return ""
        }
        // Positive evidence: user's exact mailbox address in Cc → claim.
        return AddressParser.parseAddressList(ccField).flatMap(\.mailboxes)
            .contains(where: { claimSet.contains($0.address.lowercased()) }) ? "cc" : ""
    }

    private static func normalizeEmailSet(_ emails: [String]) -> Set<String> {
        Set(emails.compactMap { addr -> String? in
            let e = addr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return e.isEmpty ? nil : e
        })
    }

    // Matcher-input bounds — ReDoS guards, NOT stored-content truncation (rule
    // 11: full headers stay stored/displayed elsewhere; only the ephemeral
    // input to the address matcher is bounded). The atext regex backtracks
    // quadratically on long unbroken character runs, so tokens are bounded
    // near the RFC 5321 path maximum (254 chars; 320 leaves headroom) and
    // whole fields are sanity-capped.
    private static let maxRecipientFieldChars = 65536
    private static let maxAddrTokenChars = 320

    /// Liberal extraction — SUPPRESS path only. Pulls every address-shaped
    /// token out of the raw header string (including display-name text).
    /// Over-extraction here is safe: it can only suppress a claim.
    ///
    /// Input is pre-split on structural delimiters (whitespace, commas,
    /// brackets, quotes, parens — never legal inside an addr-spec) with
    /// over-long tokens dropped: keeps the regex scan linear in field length
    /// instead of quadratic on unbroken runs.
    ///
    /// Full RFC 5322 atext local-part class. A narrower class (e.g. missing
    /// ' ! ~) restarts matching MID-TOKEN and extracts a truncated tail —
    /// `o'brien@x.com` would yield `brien@x.com`, colliding with a different
    /// user's real address. `.unicodeScalar` semantics match JS's code-unit
    /// behavior (grapheme semantics silently absorb trailing combining marks
    /// into the last matched character). (Literals are inlined: `Regex` is not
    /// Sendable, so a stored static breaks Swift 6 strict concurrency.)
    private static func extractAllEmails(_ field: String) -> [String] {
        // Built ONCE per call and reused across tokens: constructing a Swift
        // Regex from its literal costs ~0.18ms — per-token construction made a
        // 500-address field ~90ms. (A local, not a stored static: Regex is not
        // Sendable under Swift 6 strict concurrency.)
        let emailRegex = #/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#
            .matchingSemantics(.unicodeScalar)
        var out: [String] = []
        var token: [Unicode.Scalar] = []
        func flushToken() {
            defer { token.removeAll(keepingCapacity: true) }
            guard !token.isEmpty, token.count <= maxAddrTokenChars else { return }
            out.append(contentsOf: String(String.UnicodeScalarView(token))
                .matches(of: emailRegex)
                .map { String($0.output).lowercased() })
        }
        // Manual scalar tokenizer instead of a regex split: linear by
        // construction, and scalar-level so an ASCII delimiter is recognized
        // even with a trailing combining mark (grapheme search would miss it —
        // JS indexOf/split sees the code unit; this keeps the platforms
        // byte-parallel).
        for sc in field.unicodeScalars {
            if _isStructuralDelimiter(sc) {
                flushToken()
            } else {
                token.append(sc)
            }
        }
        flushToken()
        return out
    }

    private static func _isStructuralDelimiter(_ sc: Unicode.Scalar) -> Bool {
        // U+FEFF (BOM/ZWNBSP) is in JS's \s but not in Scalar.isWhitespace —
        // include it explicitly so the platforms tokenize identically.
        sc.properties.isWhitespace || sc == "\u{FEFF}" || sc == "," || sc == ";"
            || sc == "<" || sc == ">" || sc == "(" || sc == ")" || sc == "\""
    }

    /// Strip a `+tag` local-part suffix (me+orders@x → me@x). Lowercased input expected.
    private static func stripPlusTag(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex,
              let plus = email.firstIndex(of: "+"), plus > email.startIndex,
              plus < at else { return email }
        return String(email[..<plus]) + String(email[at...])
    }

    /// Variables required for the `system_prompt_action` completions template.
    /// Requires a summary result from a prior summary call.
    static func actionVariables(
        metadata: MessageMetadata,
        body: RenderedBody,
        summary: SummaryContext,
        account: AccountContext,
        recipientStatus: String
    ) -> [String: Any] {
        let subject = metadata.subject.isEmpty ? "Not Available" : metadata.subject
        let fromSender = formatFromSender(metadata.from)
        let bodyText = body.textContent ?? ""
        let isNoReply = EmailFilter.isNoReply(metadata.from.email)
        let hasUnsubscribe = EmailFilter.hasUnsubscribeLink(body.htmlContent)

        var vars: [String: Any] = [
            "user_name": account.userName,
            "user_action_prompt": account.actionPrompt,
            "body": bodyText,
            "subject": subject,
            "from_sender": fromSender,
            "todo": summary.todos ?? "Not Available",
            "summary": summary.blurb ?? "Not Available",
            "is_noreply_address": isNoReply,
            "has_unsubscribe_link": hasUnsubscribe,
        ]
        // Same field and policy as the summary request: sent only as "cc", omitted
        // otherwise (TB parity: actionGenerator.js). The general action rules never
        // send a cc'd email to reply/none.
        if !recipientStatus.isEmpty {
            vars["recipient_status"] = recipientStatus
        }
        return vars
    }

    /// Mirrors the pre-refactor `AISummary` / `AIAction` formatting exactly:
    ///   `fromAddress.isEmpty ? from : "\(from) <\(fromAddress)>"`
    ///   then fallback to "Unknown" if the result is empty.
    /// Keeping byte-for-byte parity with the legacy shape — the backend prompt
    /// templates have been tuned against this exact format.
    private static func formatFromSender(_ from: EmailAddress) -> String {
        let sender = from.email.isEmpty ? from.name : "\(from.name) <\(from.email)>"
        return sender.isEmpty ? "Unknown" : sender
    }
}

/// Per-account context bundle. Main app pulls from Account + PromptStore;
/// NSE pulls from SharedNSEData mirror.
struct AccountContext: Sendable {
    let userName: String
    let kbText: String
    let actionPrompt: String
}

/// Summary-call output needed as input to the action call.
struct SummaryContext: Sendable {
    let blurb: String?
    let todos: String?

    init(blurb: String?, todos: String?) {
        self.blurb = blurb
        self.todos = todos
    }
}
