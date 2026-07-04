/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Validates the canonical AI prompt-variable assembly used by both main app
/// (`AISummary`/`AIAction`) and NSE (`NotificationService`). Any divergence
/// here re-opens the parity gap the shared-layer refactor closed.
@Suite("Shared/AI PromptVariables")
struct PromptVariablesTests {

    // Fixture message metadata — shared across summary + action tests.
    private func fixtureMetadata(
        from: EmailAddress = EmailAddress(name: "Alice", email: "alice@example.com"),
        subject: String = "Quarterly update",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)  // Tue, 14 Nov 2023 22:13:20 UTC
    ) -> MessageMetadata {
        MessageMetadata(
            providerMessageId: "mid-123",
            threadId: "thread-1",
            rfc822MessageId: "rfc-123@example.com",
            inReplyTo: nil, references: [],
            from: from,
            to: [], cc: [], bcc: [], replyTo: nil,
            subject: subject, date: date, snippet: "preview",
            isRead: false, isFlagged: false, hasAttachments: false,
            providerLabels: [],
            folderPath: nil
        )
    }

    private func fixtureBody(html: String? = "<p>Body text</p>", text: String? = "Body text") -> RenderedBody {
        RenderedBody(
            htmlContent: html, textContent: text,
            attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
        )
    }

    private let account = AccountContext(
        userName: "Kai",
        kbText: "Works at ACME. Prefers terse replies.",
        actionPrompt: "# Action rules\n- delete promos"
    )

    // MARK: - Summary variable shape

    @Test("Summary has every expected key")
    func summaryKeys() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(), body: fixtureBody(), account: account
        )
        let expected: Set<String> = [
            "user_name", "user_kb_content", "subject", "from_sender",
            "email_date", "email_day_of_week", "body",
            "is_noreply_address", "has_unsubscribe_link",
        ]
        #expect(Set(vars.keys) == expected)
    }

    @Test("Summary echoes account fields")
    func summaryAccountFields() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(), body: fixtureBody(), account: account
        )
        #expect(vars["user_name"] as? String == "Kai")
        #expect(vars["user_kb_content"] as? String == "Works at ACME. Prefers terse replies.")
    }

    @Test("Summary formats from_sender as 'Name <email>'")
    func summaryFromSenderFormat() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(), body: fixtureBody(), account: account
        )
        #expect(vars["from_sender"] as? String == "Alice <alice@example.com>")
    }

    @Test("Summary from_sender keeps legacy shape: ' <email>' when name is empty")
    func summaryFromSenderEmptyName() {
        // Pins pre-refactor behavior: `fromAddress.isEmpty ? from : "\(from) <\(fromAddress)>"`.
        // With name="" and email="x@y", old code produced " <x@y>" (leading space).
        // Keep byte-for-byte parity — backend prompt templates tuned for this shape.
        let metadata = fixtureMetadata(from: EmailAddress(name: "", email: "noname@example.com"))
        let vars = PromptVariables.summaryVariables(metadata: metadata, body: fixtureBody(), account: account)
        #expect(vars["from_sender"] as? String == " <noname@example.com>")
    }

    @Test("Summary from_sender 'Unknown' when both name and email are empty")
    func summaryFromSenderBothEmpty() {
        let metadata = fixtureMetadata(from: EmailAddress(name: "", email: ""))
        let vars = PromptVariables.summaryVariables(metadata: metadata, body: fixtureBody(), account: account)
        #expect(vars["from_sender"] as? String == "Unknown")
    }

    @Test("Summary from_sender uses bare name when email is empty")
    func summaryFromSenderEmailOnly() {
        let metadata = fixtureMetadata(from: EmailAddress(name: "Alice", email: ""))
        let vars = PromptVariables.summaryVariables(metadata: metadata, body: fixtureBody(), account: account)
        // Legacy: `fromAddress.isEmpty ? from : "\(from) <\(fromAddress)>"` → returns bare name.
        #expect(vars["from_sender"] as? String == "Alice")
    }

    @Test("Summary email_date matches PromptFormatters.formatTimestampForAgent exactly")
    func summaryEmailDateMatchesFormatter() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = fixtureMetadata(date: date)
        let vars = PromptVariables.summaryVariables(metadata: metadata, body: fixtureBody(), account: account)
        #expect(vars["email_date"] as? String == PromptFormatters.formatTimestampForAgent(date))
    }

    @Test("Summary email_day_of_week is English weekday name")
    func summaryDayOfWeek() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // Tuesday UTC; may cross day in local TZ.
        let metadata = fixtureMetadata(date: date)
        let vars = PromptVariables.summaryVariables(metadata: metadata, body: fixtureBody(), account: account)
        let weekday = vars["email_day_of_week"] as? String ?? ""
        let validWeekdays: Set<String> = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(validWeekdays.contains(weekday))
    }

    @Test("Summary body uses textContent")
    func summaryBodyText() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(html: "<p>HTML</p>", text: "plain text"),
            account: account
        )
        #expect(vars["body"] as? String == "plain text")
    }

    @Test("Summary body falls back to empty string when textContent is nil")
    func summaryBodyEmpty() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(html: nil, text: nil),
            account: account
        )
        #expect(vars["body"] as? String == "")
    }

    @Test("Summary subject defaults to 'Not Available' for empty subject")
    func summarySubjectDefault() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(subject: ""), body: fixtureBody(), account: account
        )
        #expect(vars["subject"] as? String == "Not Available")
    }

    @Test("Summary is_noreply flags noreply addresses")
    func summaryIsNoReply() {
        let m = fixtureMetadata(from: EmailAddress(name: "Mail", email: "noreply@example.com"))
        let vars = PromptVariables.summaryVariables(metadata: m, body: fixtureBody(), account: account)
        #expect(vars["is_noreply_address"] as? Bool == true)
    }

    @Test("Summary has_unsubscribe_link flags HTML with unsubscribe + http")
    func summaryHasUnsubscribeLink() {
        let body = RenderedBody(
            htmlContent: "<a href=\"http://example.com/unsubscribe\">unsubscribe</a>",
            textContent: "unsubscribe", attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
        )
        let vars = PromptVariables.summaryVariables(metadata: fixtureMetadata(), body: body, account: account)
        #expect(vars["has_unsubscribe_link"] as? Bool == true)
    }

    @Test("Summary has_unsubscribe_link false when html has no unsubscribe text")
    func summaryHasUnsubscribeLinkFalse() {
        let body = RenderedBody(
            htmlContent: "<p>hello</p>", textContent: "hello",
            attachments: [], icsText: nil, hasUnresolvedCIDs: false, hasUnresolvedICS: false
        )
        let vars = PromptVariables.summaryVariables(metadata: fixtureMetadata(), body: body, account: account)
        #expect(vars["has_unsubscribe_link"] as? Bool == false)
    }

    // MARK: - Recipient status

    @Test("Summary includes recipient_status when cc")
    func summaryRecipientStatusCc() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(), body: fixtureBody(), account: account,
            recipientStatus: "cc"
        )
        #expect(vars["recipient_status"] as? String == "cc")
    }

    @Test("Summary omits recipient_status when empty (direct recipient / unknown)")
    func summaryRecipientStatusOmitted() {
        let vars = PromptVariables.summaryVariables(
            metadata: fixtureMetadata(), body: fixtureBody(), account: account,
            recipientStatus: ""
        )
        #expect(vars["recipient_status"] == nil)
    }

    // "cc" needs POSITIVE evidence (user's exact address in Cc). Absence of the
    // user from To is NOT evidence — aliases/Bcc/list mail must yield "".
    private let extFrom = "Boss <boss@example.com>"  // external author unless a test says otherwise

    @Test("classifyRecipientStatus: 'cc' when a provided address is in Cc and not in To")
    func classifyCcRecipient() {
        let me = ["me@example.com"]
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "Other <other@example.com>", ccField: "Me <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // Case-insensitive on both sides.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "ME@Example.COM",
            fromField: extFrom, claimEmails: ["Me@example.com "]
        ) == "cc")
        // Display-name commas inside quotes don't break address extraction.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "\"Doe, John\" <john@example.com>", ccField: "\"Me, Myself\" <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("classifyRecipientStatus: '' when a provided address is in To (direct)")
    func classifyDirectRecipient() {
        let me = ["me@example.com"]
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "Someone <other@example.com>, Me <me@example.com>", ccField: "",
            fromField: extFrom, claimEmails: me
        ) == "")
        // In To wins even if ALSO in Cc.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "Me <ME@Example.COM>", ccField: "me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Plus-alias in To is still direct (loose suppress — no cc claim).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "me+orders@example.com", ccField: "me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("classifyRecipientStatus: '' when user in neither To nor Cc (alias/Bcc/list — unsure)")
    func classifyUnsure() {
        let me = ["me@example.com"]
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "Boss <boss@example.com>", ccField: "peer@company.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "", ccField: "", fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("classifyRecipientStatus: '' when the user authored the message, even if cc'd")
    func classifySelfAuthored() {
        let me = ["me@example.com"]
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "list@company.com", ccField: "me@example.com",
            fromField: "Me <me@example.com>", claimEmails: me
        ) == "")
        // Self-sent via a plus-alias also counts as authored (loose suppress).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "list@company.com", ccField: "me@example.com",
            fromField: "me+news@example.com", claimEmails: me
        ) == "")
    }

    @Test("classifyRecipientStatus requires EXACT match in Cc (strict claim)")
    func classifyStrictCcClaim() {
        let me = ["me@example.com"]
        // Plus-alias in Cc is not exact → unsure → "".
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me+x@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Lookalike/superstring addresses in Cc must not claim.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "notme@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com.evil.org",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Exact address among lookalikes still claims.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "notme@example.com, me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("classifyRecipientStatus handles the real per-provider Cc formats")
    func classifyProviderShapes() {
        // account.emailAddress may be mixed case — normalization is part of the contract.
        let me = ["Me@Example.com"]
        // Gmail: raw RFC 2822 header value (quoted display names, angle brackets).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "\"Doe, John\" <john@company.com>", ccField: "Me <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // Outlook/Graph: email-only comma list (GraphAPI parsed addresses).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "john@company.com", ccField: "jane@company.com, me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // IMAP (SwiftMail): "Name <addr>" entries joined with ", ".
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "John Doe <john@company.com>", ccField: "Me Myself <ME@EXAMPLE.COM>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // Same shapes with the user in To instead → direct → "".
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "\"Doe, John\" <john@company.com>, Me <me@example.com>", ccField: "",
            fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("classifyRecipientStatus: '' when user emails unknown (never claim cc unsure)")
    func classifyUnknownUserEmails() {
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com",
            fromField: extFrom, claimEmails: []
        ) == "")
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com",
            fromField: extFrom, claimEmails: ["", "  "]
        ) == "")
    }

    @Test("Claim path ignores address-shaped tokens in display names / comments / encoded words")
    func classifyInjectionResistance() {
        let me = ["me@example.com"]
        // Decoded quoted display name carrying the user's address → NOT evidence.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"me@example.com\" <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // RFC 2047 encoded word (raw Gmail header shape) → NOT evidence.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "=?utf-8?Q?me@example.com?= <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Comment carrying the address → NOT evidence.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "(me@example.com) <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Unquoted display-name address before a bracketed mailbox → NOT evidence.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Unclosed bracket → yields nothing rather than falling back to display text.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "<bob@corp.com me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        // The user actually bracketed in Cc still claims.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"Anything at all\" <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("Full atext extraction: no truncated-tail collisions with neighboring addresses")
    func classifyAtextExtraction() {
        // o'brien@example.com must extract WHOLE — a narrow class would yield
        // brien@example.com and falsely claim for user brien@example.com.
        let brien = ["brien@example.com"]
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "o'brien@example.com",
            fromField: extFrom, claimEmails: brien
        ) == "")
        // And o'brien in To must not suppress user brien (different mailbox)…
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "o'brien@example.com", ccField: "brien@example.com",
            fromField: extFrom, claimEmails: brien
        ) == "cc")
        // …while the real o'brien user still matches exactly.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "O'Brien <o'brien@example.com>",
            fromField: extFrom, claimEmails: ["o'brien@example.com"]
        ) == "cc")
    }

    @Test("Claim path is whole-token anchored — truncated heads/tails never claim")
    func classifyAnchoredClaim() {
        let me = ["me@example.com"]
        // Combining mark after the address (grapheme vs code-unit semantics —
        // the anchored exact match rejects regardless).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "<me@example.com\u{0301}>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Non-ASCII prefix restarts a substring match mid-token; exact match rejects.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "<öme@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Trailing junk after a matching domain must not claim the prefix.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "<me@example.com_x>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Bracket span with extra tokens is not a single addr-spec.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "<junk me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("A field with brackets counts ONLY bracketed spans (quote-imbalance defense)")
    func classifyBracketExclusivity() {
        let me = ["me@example.com"]
        // Unescaped quotes in a formatted display name can strand a planted
        // address in a bare comma segment — the bracket rule ignores it.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "\"a\", me@example.com, b\" <other2@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Deliberate trade-off: a bare address mixed into a bracketed field is
        // also ignored (missed claim = safe omit).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "me@example.com, Name <c@company.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("Group syntax: leading 'name:' prefix is stripped for the first member")
    func classifyGroupSyntax() {
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "team: me@example.com, boss@example.com;",
            fromField: extFrom, claimEmails: ["me@example.com"]
        ) == "cc")
    }

    @Test("Bounded matcher input: degenerate runs and oversized fields safely omit")
    func classifyBoundedInput() {
        let me = ["me@example.com"]
        // 100KB unbroken atext run — must complete fast (token bound) and omit.
        let run = String(repeating: "a", count: 100_000)
        let t0 = Date()
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: run,
            fromField: extFrom, claimEmails: me
        ) == "")
        // Same run glued to the user's address: one giant token, dropped → omit.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: run + "me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Oversized To field (> 64KB) → classification skipped entirely.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: run, ccField: "me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "")
        #expect(Date().timeIntervalSince(t0) < 2.0)
        // Normal-size comma-packed list still extracts on the claim path.
        let packed = (0..<200).map { "u\($0)@example.com" }.joined(separator: ",") + ",me@example.com"
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: packed,
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("Claim path is linear on unbalanced-opener floods (round-2 ReDoS shapes)")
    func classifyClaimPathLinear() {
        let me = ["me@example.com"]
        // '<' and '(' floods at the 64KB field cap previously hit quadratic
        // regex scans (~minutes in Swift). Linear scans must stay fast.
        let t0 = Date()
        for flood in [
            String(repeating: "<", count: 65536),
            String(repeating: "(", count: 65536),
            String(repeating: "\"", count: 65536),
            String(repeating: "=?", count: 32768),
            String(repeating: "<a", count: 32768),
        ] {
            #expect(PromptVariables.classifyRecipientStatus(
                toField: "other@example.com", ccField: flood,
                fromField: extFrom, claimEmails: me
            ) == "")
        }
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    @Test("Many REAL addresses stay fast (per-candidate validator cost is bounded)")
    func classifyRealAddressVolume() {
        let me = ["me@example.com"]
        // Flood shapes produce zero exactAddr calls; this shape produces 2000
        // (sized under the 64KB field cap) — pins the per-candidate regex cost
        // (round-3 finding: per-call literal construction made 5000 candidates
        // ~860ms even at -O).
        let bracketed = (0..<2000).map { "U\($0) <u\($0)@example.com>" }.joined(separator: ", ")
        let bare = (0..<2000).map { "u\($0)@example.com" }.joined(separator: ",")
        let t0 = Date()
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: bracketed + ", Me <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: bare + ",me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // Large To (user absent) exercises the suppress path at volume; user in Cc still claims.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: bare, ccField: "me@example.com",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        #expect(Date().timeIntervalSince(t0) < 1.5)
    }

    @Test("Bracket-exposed display-name injection cannot fabricate a claim (last-span rule)")
    func classifyBracketInjection() {
        let me = ["me@example.com"]
        // SwiftMail MIME-decodes a display name and re-wraps it in UNESCAPED
        // quotes, so a Cc entry `bob@corp.com` with decoded name
        // `x" <me@example.com> "y` reaches the classifier as:
        // "x" <me@example.com> "y" <bob@corp.com>. Only the LAST bracket span
        // per segment is the real address, so the planted span is rejected.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"x\" <me@example.com> \"y\" <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Bare-address form in a display position (before the real bracket).
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // The real user address as the LAST span still claims.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"decoy <bob@corp.com>\" <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // Multi-address list where an injected span precedes each real address.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "\"<me@example.com>\" <a@corp.com>, \"<me@example.com>\" <b@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
    }

    @Test("Documents the accepted residual: unescaped-quote + comma injection (KNOWN LIMITATION)")
    func classifyAcceptedResidual() {
        let me = ["me@example.com"]
        // ACCEPTED LOW-IMPACT LIMITATION (2026-07-05) — see extractAddressEmails
        // doc + PROJECT_MEMORY.md. A producer (SwiftMail IMAP formatAddress) that
        // emits the decoded display name in UNESCAPED quotes with an embedded
        // comma lets the injected <me@example.com> become the last span of its
        // own segment. The string is BYTE-IDENTICAL to a legitimate two-recipient
        // Cc that MUST claim, so no string parser can distinguish them. This PINS
        // the current (spuriously "cc") behavior so the tradeoff is visible; it
        // is NOT an endorsement.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"x\" <me@example.com> , \"y\" <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
        // The legitimate twin it is byte-ambiguous with — MUST claim.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "\"Me\" <me@example.com>, \"Bob\" <bob@corp.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("Sanitizers are escape-aware — escaped delimiters cannot expose planted spans")
    func classifyEscapeAwareSanitizers() {
        let me = ["me@example.com"]
        // Backslash-escaped quotes inside a quoted display name mis-paired the
        // old regex sanitizer, exposing <planted> as a countable span.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "\"a\\\" <me@example.com> \\\"b\" <real@company.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Same for escaped parens inside a comment.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "(a\\) <me@example.com> \\(b) <real@company.com>",
            fromField: extFrom, claimEmails: me
        ) == "")
        // Escaped-escape (\\) before a quote is NOT an escaped quote — still pairs.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com",
            ccField: "\"a\\\\\" <me@example.com>",
            fromField: extFrom, claimEmails: me
        ) == "cc")
    }

    @Test("suppressEmails only suppress — they never create a claim")
    func classifySuppressSet() {
        let claim = ["me@example.com"]
        let suppress = ["otheracct@example.com"]
        // Another own account in To → suppressed even though claim address is in Cc.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "otheracct@example.com", ccField: "me@example.com",
            fromField: extFrom, claimEmails: claim, suppressEmails: suppress
        ) == "")
        // Another own account as the AUTHOR → suppressed.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "list@company.com", ccField: "me@example.com",
            fromField: "otheracct@example.com", claimEmails: claim, suppressEmails: suppress
        ) == "")
        // A suppress-only address in Cc does NOT claim.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "otheracct@example.com",
            fromField: extFrom, claimEmails: claim, suppressEmails: suppress
        ) == "")
        // Suppress list absent → claim set alone still works.
        #expect(PromptVariables.classifyRecipientStatus(
            toField: "other@example.com", ccField: "me@example.com",
            fromField: extFrom, claimEmails: claim
        ) == "cc")
    }

    // MARK: - Action variable shape

    @Test("Action has every expected key")
    func actionKeys() {
        let vars = PromptVariables.actionVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(),
            summary: SummaryContext(blurb: "summary text", todos: "- do X"),
            account: account
        )
        let expected: Set<String> = [
            "user_name", "user_action_prompt", "body", "subject", "from_sender",
            "todo", "summary",
            "is_noreply_address", "has_unsubscribe_link",
        ]
        #expect(Set(vars.keys) == expected)
    }

    @Test("Action passes summary + todos through")
    func actionSummaryTodos() {
        let vars = PromptVariables.actionVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(),
            summary: SummaryContext(blurb: "S", todos: "T"),
            account: account
        )
        #expect(vars["summary"] as? String == "S")
        #expect(vars["todo"] as? String == "T")
    }

    @Test("Action nil summary + todos default to 'Not Available'")
    func actionSummaryTodosNil() {
        let vars = PromptVariables.actionVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(),
            summary: SummaryContext(blurb: nil, todos: nil),
            account: account
        )
        #expect(vars["summary"] as? String == "Not Available")
        #expect(vars["todo"] as? String == "Not Available")
    }

    @Test("Action uses user_action_prompt, not user_kb_content")
    func actionUsesActionPrompt() {
        let vars = PromptVariables.actionVariables(
            metadata: fixtureMetadata(),
            body: fixtureBody(),
            summary: SummaryContext(blurb: nil, todos: nil),
            account: account
        )
        #expect(vars["user_action_prompt"] as? String == "# Action rules\n- delete promos")
        #expect(vars["user_kb_content"] == nil)  // Action prompt does NOT include KB.
    }

    // MARK: - Parity between summary and action for overlapping keys

    @Test("Action and summary produce identical values for overlapping keys")
    func overlappingKeyParity() {
        let metadata = fixtureMetadata()
        let body = fixtureBody()
        let summary = SummaryContext(blurb: nil, todos: nil)
        let s = PromptVariables.summaryVariables(metadata: metadata, body: body, account: account)
        let a = PromptVariables.actionVariables(metadata: metadata, body: body, summary: summary, account: account)

        for key in ["user_name", "subject", "from_sender", "body", "is_noreply_address", "has_unsubscribe_link"] {
            #expect("\(s[key] ?? "nil-s")" == "\(a[key] ?? "nil-a")",
                    "Key '\(key)' differs: summary=\(s[key] ?? "nil") vs action=\(a[key] ?? "nil")")
        }
    }
}
