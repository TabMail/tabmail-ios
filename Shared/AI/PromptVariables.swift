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
        account: AccountContext
    ) -> [String: Any] {
        let subject = metadata.subject.isEmpty ? "Not Available" : metadata.subject
        let fromSender = formatFromSender(metadata.from)
        let emailDate = PromptFormatters.formatTimestampForAgent(metadata.date)
        let emailDayOfWeek = PromptFormatters.dayOfWeek(metadata.date)
        let bodyText = body.textContent ?? ""
        let isNoReply = EmailFilter.isNoReply(metadata.from.email)
        let hasUnsubscribe = EmailFilter.hasUnsubscribeLink(body.htmlContent)

        return [
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
