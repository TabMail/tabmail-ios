/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared AI response parsing between main app and NSE.
/// Single source of truth — both targets reference this file.
///
/// From protocol 2.0.0 the backend answers the summary and the precache reply as one JSON object
/// (backend ADR-032), each with a short text message; it rebuilds the old labelled text only for
/// clients below 2.0.0, so this app never receives it.
enum AIResponseParser {

    struct SummaryResult {
        let blurb: String?
        let todos: String?
        let reminderDate: String?
        let reminderTime: String?
        let reminderContent: String?
        let textMessage: String?
    }

    /// Parse the summary JSON: `{"todos": [..], "summary": "..", "reminder": {"due_date", "due_time",
    /// "content"}, "text_message": ".."}`, the reminder fields null for none. The stored shapes are
    /// unchanged: todos as one bullet-joined line ("• a • b"), the blurb on one line, a reminder only
    /// with content, its time only as HH:MM. A reply that is not that object gives an all-nil result,
    /// which the callers treat as no summary (retried later).
    static func parseSummaryResponse(_ text: String) -> SummaryResult {
        guard let object = jsonObject(text) else {
            return SummaryResult(blurb: nil, todos: nil, reminderDate: nil, reminderTime: nil, reminderContent: nil, textMessage: nil)
        }
        let todos = (object["todos"] as? [Any] ?? [])
            .compactMap { ($0 as? String).flatMap(oneLine) }
            .map { "• \($0)" }
            .joined(separator: " ")
        let reminder = object["reminder"] as? [String: Any] ?? [:]
        let reminderContent = (reminder["content"] as? String).flatMap(oneLine)
        let reminderDate = reminderContent == nil ? nil : (reminder["due_date"] as? String).flatMap(oneLine)
        let reminderTime = reminderContent == nil ? nil : (reminder["due_time"] as? String).flatMap(oneLine)
            .flatMap { $0.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
        return SummaryResult(
            blurb: (object["summary"] as? String).flatMap { nonEmpty($0.replacingOccurrences(of: "\n", with: " ")) },
            todos: todos.isEmpty ? nil : todos,
            reminderDate: reminderDate,
            reminderTime: reminderTime,
            reminderContent: reminderContent,
            textMessage: (object["text_message"] as? String).flatMap(nonEmpty)
        )
    }

    struct ReplyResult {
        let body: String
        let textMessage: String?
    }

    /// Parse the precache reply JSON: `{"subject": "..", "body": "..", "text_message": ".."}`. Nil when
    /// it is not that object or has no body; the caller treats that as no reply (retried later).
    static func parseReplyResponse(_ text: String) -> ReplyResult? {
        guard let object = jsonObject(text), let body = (object["body"] as? String).flatMap(nonEmpty) else { return nil }
        return ReplyResult(body: body, textMessage: (object["text_message"] as? String).flatMap(nonEmpty))
    }

    /// The JSON object `text` holds, else nil.
    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Trimmed, nil when empty or "None" (the model's word for no value).
    private static func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        return text.isEmpty || lower == "none" || lower == "\"none\"" ? nil : text
    }

    /// Trimmed, nil only when empty. For the summary, the reply body and the text messages: the
    /// backend sends them as plain strings with no "None" word for a missing value (it accepts any
    /// nonblank summary), so a summary or reply that is the word "None" is kept as written. A chat
    /// summary is done once its text message is stored (`ActiveAIQueue.summaryDone`), so dropping a
    /// literal "None" there would re-request that summary forever.
    private static func nonEmpty(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `trimmed`, with its newlines turned into spaces (the one-line todo and reminder fields).
    private static func oneLine(_ value: String) -> String? {
        trimmed(value.replacingOccurrences(of: "\n", with: " "))
    }

    /// Parse action tag from backend response JSON.
    /// Resilient to truncated responses — regex-based extraction.
    static func parseActionTag(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #""action"\s*:\s*"(\w+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return nil }
        let value = String(trimmed[range]).lowercased()
        guard ["delete", "archive", "reply", "none"].contains(value) else { return nil }
        return value
    }
}
