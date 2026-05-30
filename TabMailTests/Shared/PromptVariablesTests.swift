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
