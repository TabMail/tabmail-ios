/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

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

    /// Recipient-status classification for the summary request — parity with the
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
    /// suppress is harmless; the CLAIM check (Cc) uses claim-grade extraction
    /// + strict exact-address matching since a wrong claim is the failure mode
    /// this feature works hardest to avoid (see `extractAddressEmails` for the
    /// one accepted, low-impact residual it cannot fully close).
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
        return extractAddressEmails(ccField).contains(where: { claimSet.contains($0) }) ? "cc" : ""
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

    /// Trim set for claim candidates. JS `trim()` strips U+FEFF (BOM/ZWNBSP);
    /// Swift's `.whitespacesAndNewlines` does not — align them. (CharacterSet
    /// is a Sendable value type, so a stored static is fine.)
    private static let candidateTrimSet: CharacterSet = {
        var s = CharacterSet.whitespacesAndNewlines
        s.insert(charactersIn: "\u{FEFF}")
        return s
    }()

    /// Whole-token address check for the claim path. Returns the normalized
    /// address iff the trimmed candidate is EXACTLY one addr-spec — anchored,
    /// so a truncated head/tail (non-ASCII prefix, trailing junk, combining
    /// mark) can never be misread as the user's mailbox. The compiled regex is
    /// passed in (built once per extraction call) — constructing a Swift Regex
    /// literal costs ~0.18ms, which made 5000 candidates take ~860ms.
    private static func exactAddr(_ candidate: some StringProtocol, _ emailRegex: Regex<Substring>) -> String? {
        let c = candidate.trimmingCharacters(in: candidateTrimSet)
        guard !c.isEmpty, c.count <= maxAddrTokenChars else { return nil }
        guard c.wholeMatch(of: emailRegex) != nil else { return nil }
        return c.lowercased()
    }

    /// Index of the next occurrence of `needle` at/after `from`. Naive scan —
    /// needles are 1-2 scalars, so this is linear in practice.
    private static func _indexOf(_ s: [Unicode.Scalar], _ needle: [Unicode.Scalar], from: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var i = max(0, from)
        while i + needle.count <= s.count {
            var k = 0
            while k < needle.count, s[i + k] == needle[k] { k += 1 }
            if k == needle.count { return i }
            i += 1
        }
        return nil
    }

    /// Next occurrence of `close` at/after `from` that is NOT backslash-escaped
    /// (odd number of preceding backslashes). nil if none.
    private static func _indexOfUnescaped(_ s: [Unicode.Scalar], _ close: [Unicode.Scalar], from: Int) -> Int? {
        var i = from
        while let at = _indexOf(s, close, from: i) {
            var backslashes = 0
            var j = at - 1
            while j >= 0, s[j] == "\\" {
                backslashes += 1
                j -= 1
            }
            if backslashes % 2 == 0 { return at }
            i = at + 1
        }
        return nil
    }

    /// Linear, escape-aware removal of `open`…`close` regions (each replaced by
    /// a single space). Unterminated opens keep the rest untouched. Manual
    /// index scan on purpose: a backtracking regex like `"[^"]*"` is O(n²) on
    /// unbalanced openers, and regex sanitizers are escape-blind (`\"`/`\)`
    /// mis-pair the boundaries, exposing planted bracket spans).
    private static func _stripDelimited(
        _ s: [Unicode.Scalar], open: [Unicode.Scalar], close: [Unicode.Scalar], escapeAware: Bool
    ) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            guard let a = _indexOf(s, open, from: i) else {
                out.append(contentsOf: s[i...])
                break
            }
            let searchFrom = a + open.count
            let b = escapeAware
                ? _indexOfUnescaped(s, close, from: searchFrom)
                : _indexOf(s, close, from: searchFrom)
            guard let b else {
                out.append(contentsOf: s[i...])
                break
            }
            out.append(contentsOf: s[i..<a])
            out.append(" ")
            i = b + close.count
        }
        return out
    }

    /// Linear scan for the contents of each `<...>` span (leftmost,
    /// non-nested — same shape a `<[^>]*>` regex matches, without its O(n²)
    /// blowup on unbalanced `<` runs).
    private static func _bracketContents(_ s: [Unicode.Scalar]) -> [String] {
        var out: [String] = []
        var i = 0
        while let open = _indexOf(s, ["<"], from: i) {
            guard let close = _indexOf(s, [">"], from: open + 1) else { break }
            out.append(String(String.UnicodeScalarView(s[(open + 1)..<close])))
            i = close + 1
        }
        return out
    }

    /// Claim-grade extraction — CC path only. Best-effort at returning only
    /// ACTUAL mailbox addresses so an address-shaped token planted in a display
    /// name can't fabricate positive Cc evidence:
    ///   1. RFC 2047 encoded words, quoted strings, and comments are
    ///      display-name material by definition — removed before extraction
    ///      (linear, escape-aware scans).
    ///   2. If the field uses angle-bracket form ANYWHERE, only bracketed
    ///      spans count — a bare segment coexisting with brackets is
    ///      display-name debris (e.g. unescaped quotes in a formatted name),
    ///      not a mailbox. Per comma/semicolon segment only the LAST <...> span
    ///      is the real addr-spec. Unclosed brackets yield nothing. Bare fields
    ///      (email-only lists) are split on comma/semicolon.
    ///   3. Every candidate must be EXACTLY an addr-spec (`exactAddr`) — no
    ///      substring scanning on the claim path.
    /// Under-extraction here is safe: a missed Cc address just omits the field.
    /// Every scan is linear (ReDoS-safe; the 64KB field cap is
    /// belt-and-suspenders). Scans run on the unicodeScalar view so ASCII
    /// structural delimiters are found even with trailing combining marks (JS
    /// code-unit parity).
    ///
    /// KNOWN LIMITATION (accepted 2026-07-05, low impact — see PROJECT_MEMORY.md
    /// "Summary recipient_status"): resists display-name injection for escaped
    /// quoted names and unescaped-no-comma names, but NOT the case where an
    /// upstream producer emits the decoded display name in UNESCAPED quotes AND
    /// the name contains a comma/semicolon (SwiftMail's IMAP `formatAddress`
    /// does this). Such a crafted single Cc address is byte-identical to a
    /// legitimate multi-recipient Cc that MUST claim, so no string parser can
    /// distinguish them. Residual = a spurious "you're only cc'd" summary hint;
    /// adversarial-only, no data/security/crash impact. A full fix needs
    /// producer-side escaping or carrying the structured per-address array to
    /// the classifier — deliberately not done for a low-stakes helper.
    private static func extractAddressEmails(_ field: String) -> [String] {
        // Built ONCE per call and reused across candidates (see exactAddr).
        let emailRegex = #/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#
            .matchingSemantics(.unicodeScalar)
        var s = Array(field.unicodeScalars)
        s = _stripDelimited(s, open: ["=", "?"], close: ["?", "="], escapeAware: false)
        s = _stripDelimited(s, open: ["\""], close: ["\""], escapeAware: true)
        s = _stripDelimited(s, open: ["("], close: [")"], escapeAware: true)
        var out: [String] = []
        let bracketMode = s.contains("<")
        var seg: [Unicode.Scalar] = []
        func flushSegment() {
            defer { seg.removeAll(keepingCapacity: true) }
            if bracketMode {
                // Only the LAST <...> span in a segment is the real addr-spec;
                // earlier spans are display-name material (a MIME-decoded name
                // re-wrapped in unescaped quotes can smuggle a <victim> span
                // ahead of the address — SwiftMail's IMAP formatter does this).
                // A bracketless segment is display debris → dropped.
                let spans = _bracketContents(seg)
                if let last = spans.last, let e = exactAddr(last, emailRegex) {
                    out.append(e)
                }
            } else {
                // RFC 5322 group syntax prefixes the first member with `name :`.
                var cand = seg
                if let colon = cand.firstIndex(of: ":") {
                    cand = Array(cand[(colon + 1)...])
                }
                if let e = exactAddr(String(String.UnicodeScalarView(cand)), emailRegex) {
                    out.append(e)
                }
            }
        }
        for sc in s {
            if sc == "," || sc == ";" {
                flushSegment()
            } else {
                seg.append(sc)
            }
        }
        flushSegment()
        return out
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
        account: AccountContext
    ) -> [String: Any] {
        let subject = metadata.subject.isEmpty ? "Not Available" : metadata.subject
        let fromSender = formatFromSender(metadata.from)
        let bodyText = body.textContent ?? ""
        let isNoReply = EmailFilter.isNoReply(metadata.from.email)
        let hasUnsubscribe = EmailFilter.hasUnsubscribeLink(body.htmlContent)

        return [
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
