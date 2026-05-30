/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Context needed to build a compose edit request, gathered from ComposeView.
struct ComposeEditContext: Sendable {
    let recipients: [String]
    /// Current draft To/Cc/Bcc at the moment of the edit request. Passed to the LLM as
    /// `original_to`/`original_cc`/`original_bcc` so it can copy them back verbatim (the
    /// default) or modify on explicit user request. `recipients` above is kept for
    /// backwards compatibility with older prompts; new prompts use these three fields.
    let toRecipients: [String]
    let ccRecipients: [String]
    let bccRecipients: [String]
    /// Display-name lookups keyed by lowercase email. Used when formatting
    /// `Name <email>` lines so the LLM preserves the name on copy-through.
    let toDisplayNames: [String: String]
    let ccDisplayNames: [String: String]
    let bccDisplayNames: [String: String]
    let senderName: String
    let senderEmail: String
    let mode: String  // "edit_new", "edit_reply", "edit_forward"
    let compositionPrompt: String
    let kbText: String
    // For reply/forward mode (original email metadata):
    let relatedDate: String
    let relatedSubject: String
    let relatedFrom: String
    let relatedTo: String
    let relatedCc: String
    let bodyText: String  // original email body for reply/forward context
}

/// A single turn in the inline edit conversation history.
/// Stores the draft state at the time of the request so the LLM can see the full evolution.
struct InlineEditTurn: Sendable {
    let userRequest: String
    let bodyAtRequest: String
    let subjectAtRequest: String
    let assistantResponse: String
}

/// A single parsed recipient from a `+X:` response line, e.g. `Name <email>` or `<email>`.
struct ParsedRecipient: Sendable {
    let name: String
    let email: String
}

/// Delta for one recipient field (To / Cc / Bcc) extracted from the LLM response.
/// Applied on top of the current draft's tokens: removals first, then adds.
struct RecipientDelta: Sendable {
    /// Recipients to add. Names preserved when the LLM supplied them.
    let adds: [ParsedRecipient]
    /// Lowercased emails to remove. Contains `"*"` (literal) when the LLM asked to clear
    /// the entire field (via e.g. `-Cc: *`).
    let removes: [String]

    var clearsField: Bool { removes.contains("*") }
    var isEmpty: Bool { adds.isEmpty && removes.isEmpty }
}

/// Result of an inline edit operation.
struct InlineEditResult: Sendable {
    let response: String?  // Conversational description of edits (from "Response:" field)
    let subject: String?   // Updated subject (from "Subject:" field)
    let body: String?      // Updated body (from "Body:" field)
    /// Delta for the To field. `nil` when neither `+To:` nor `-To:` appeared in the
    /// response — meaning the field should be left untouched. Non-nil = the LLM
    /// intentionally expressed a change.
    let toDelta: RecipientDelta?
    let ccDelta: RecipientDelta?
    let bccDelta: RecipientDelta?
    let raw: String        // Raw LLM response for storing in chat history
}

extension AIService {

    /// Perform an inline edit of the compose draft, matching TB's `runComposeEdit()` in edit.js.
    /// Sends the current draft state + user instruction (+ optional chat history for continuous editing)
    /// to the backend via `system_prompt_compose_interactive` with the appropriate edit mode.
    ///
    /// Returns an `InlineEditResult` with the conversational response, updated subject/body, and raw text.
    func performInlineEdit(
        currentSubject: String,
        currentBody: String,
        context: ComposeEditContext,
        instruction: String,
        chatHistory: [InlineEditTurn],
        onSSEEvent: BackendClient.SSEEventHandler? = nil
    ) async throws -> InlineEditResult {
        guard !disableLLMCalls else {
            print("[AIService] performInlineEdit: SKIP — LLM calls disabled")
            return InlineEditResult(response: "AI calls are disabled.", subject: nil, body: nil, toDelta: nil, ccDelta: nil, bccDelta: nil, raw: "")
        }

        // Demo Mode budget. One performInlineEdit = one count.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        if inDemo {
            let exhausted = await MainActor.run { DemoModeStore.shared.isCallBudgetExhausted }
            guard !exhausted else { throw DemoError.callBudgetExhausted }
            await MainActor.run { DemoModeStore.shared.consumeCall() }
        }

        // Format recipients as JSON array, matching TB's buildComposeEditChat
        struct Recipient: Encodable {
            let name: String
            let email: String
        }
        let recipientsArray = context.recipients.map { Recipient(name: "", email: $0) }
        let recipientsJSON: String
        if let data = try? JSONEncoder().encode(recipientsArray),
           let str = String(data: data, encoding: .utf8) {
            recipientsJSON = str
        } else {
            recipientsJSON = "[]"
        }

        // Current time for new email mode
        let currentTime = Self.formatTimestampForAgent(Date())

        // Format current To/Cc/Bcc as one-recipient-per-line blocks for the prompt.
        // These feed the v1.5.16+ edit prompt which instructs the LLM to copy the
        // recipient fields through unchanged by default.
        func formatRecipientBlock(_ emails: [String], names: [String: String]) -> String {
            return emails.map { email in
                let key = email.lowercased()
                let name = (names[key] ?? names[email] ?? "").trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? "<\(email)>" : "\(name) <\(email)>"
            }.joined(separator: "\n")
        }
        let originalTo = formatRecipientBlock(context.toRecipients, names: context.toDisplayNames)
        let originalCc = formatRecipientBlock(context.ccRecipients, names: context.ccDisplayNames)
        let originalBcc = formatRecipientBlock(context.bccRecipients, names: context.bccDisplayNames)

        // Build vars matching TB's buildComposeEditChat structure
        var vars: [String: JSONValue] = [
            "mode": .string(context.mode),
            "user_name": .string(context.senderName),
            "user_composition_prompt": .string(context.compositionPrompt),
            "recipients_json": .string(recipientsJSON),
            "current_subject": .string(currentSubject),
            "current_body": .string(currentBody),
            "user_request": .string(instruction),
            "user_kb_content": .string(context.kbText),
            "current_time": .string(currentTime),
            "original_to": .string(originalTo),
            "original_cc": .string(originalCc),
            "original_bcc": .string(originalBcc),
        ]

        // Add related email info for reply/forward modes — client-side split
        if context.mode == "edit_reply" || context.mode == "edit_forward" {
            let splitBody = EmailFilter.splitMessageAndQuotes(context.bodyText)
            vars["message"] = .string(splitBody.message)
            vars["quotes_section"] = .string(splitBody.quotes)
            vars["related_date"] = .string(context.relatedDate)
            vars["related_subject"] = .string(context.relatedSubject)
            vars["related_from"] = .string(context.relatedFrom)
            vars["related_to"] = .string(context.relatedTo)
            vars["related_cc"] = .string(context.relatedCc)
        }

        print("[AIService] performInlineEdit: mode=\(context.mode) instruction=\(instruction.prefix(80))")
        print("[AIService]   subject=\(currentSubject.prefix(60)) bodyLen=\(currentBody.count)")
        print("[AIService]   chatHistory turns=\(chatHistory.count)")
        print("[AIService]   vars keys=\(vars.keys.sorted().joined(separator: ","))")

        // Each call is atomic — no real chat turns. Past edits are embedded as
        // formatted text context in the system message. Each history entry stores
        // the body/subject state at the time of the request so the LLM can see
        // the full evolution (including any manual user edits between turns).
        if !chatHistory.isEmpty {
            var lines: [String] = []
            for (idx, turn) in chatHistory.enumerated() {
                lines.append("--- Edit Turn \(idx + 1) ---")
                lines.append("Draft at time of request:")
                lines.append("Subject: \(turn.subjectAtRequest)")
                lines.append("Body:\n\(turn.bodyAtRequest)")
                lines.append("")
                lines.append("User request: \(turn.userRequest)")
                lines.append("")
                lines.append("Assistant response:\n\(turn.assistantResponse)")
                lines.append("")
            }
            vars["edit_conversation_history"] = .string(lines.joined(separator: "\n"))
        } else {
            vars["edit_conversation_history"] = .string("")
        }

        let systemMsg = CompletionsMessage(
            role: "system",
            content: "system_prompt_compose_interactive",
            vars: vars
        )

        let messages: [CompletionsMessage] = [systemMsg]
        print("[AIService]   messages[0] = system (system_prompt_compose_interactive) varsCount=\(vars.count)")
        print("[AIService]   total messages count=\(messages.count)")

        let request = CompletionsRequest(
            messages: messages,
            client_timezone: TimeZone.current.identifier,
            disable_tools: false  // Allow tools for compose (contacts, calendar, etc.)
        )

        // Log raw JSON for debugging
        if let jsonData = try? JSONEncoder().encode(request),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            print("[AIService] performInlineEdit REQUEST JSON (\(jsonData.count) bytes):")
            // Truncate to avoid flooding logs — print first and last 500 chars
            if jsonStr.count > 1200 {
                print("[AIService]   \(jsonStr.prefix(500))...TRUNCATED...\(jsonStr.suffix(500))")
            } else {
                print("[AIService]   \(jsonStr)")
            }
        }

        print("[AIService] performInlineEdit: calling sendCompletionsWithToolsDirect...")
        let response: CompletionsResponse
        do {
            response = try await backend.sendCompletionsWithToolsDirect(request, onSSEEvent: onSSEEvent)
        } catch {
            if inDemo, DemoModeStore.shouldRefund(for: error) {
                await MainActor.run { DemoModeStore.shared.refundCall() }
            }
            throw error
        }
        print("[AIService] performInlineEdit: sendCompletionsWithToolsDirect returned — assistant=\(response.assistant != nil) error=\(response.error ?? "nil")")

        guard let text = response.assistant, !text.isEmpty else {
            print("[AIService] performInlineEdit: no assistant text (error=\(response.error ?? "nil"))")
            return InlineEditResult(
                response: response.error ?? "No response from AI.",
                subject: nil,
                body: nil,
                toDelta: nil,
                ccDelta: nil,
                bccDelta: nil,
                raw: ""
            )
        }

        print("[AIService] performInlineEdit: raw response length=\(text.count)")
        print("[AIService]   response preview: \(text.prefix(200))")

        let result = Self.parseInlineEditResponse(text)
        let toDesc = result.toDelta.map { "+\($0.adds.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
        let ccDesc = result.ccDelta.map { "+\($0.adds.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
        let bccDesc = result.bccDelta.map { "+\($0.adds.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
        print("[AIService] performInlineEdit PARSED: response=\(result.response?.prefix(60) ?? "nil") subject=\(result.subject?.prefix(40) ?? "nil") bodyLen=\(result.body?.count ?? 0) to=\(toDesc) cc=\(ccDesc) bcc=\(bccDesc)")
        return result
    }

    /// Parse the inline edit response format: Response / +To / -To / +Cc / -Cc / +Bcc / -Bcc / Subject / Body.
    /// Absent `+X:`/`-X:` line pair → corresponding delta is `nil` (keep field untouched).
    /// A `-X: *` line marks a clear-all. See email_edit_response_format-v1.5.16.md.
    /// Falls back to treating the entire text as body when neither Subject: nor Body: appears.
    static func parseInlineEditResponse(_ rawText: String) -> InlineEditResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract "Response:" line (first occurrence, single line)
        var response: String?
        if let range = text.range(of: #"(?mi)^Response:\s*(.*)$"#, options: .regularExpression) {
            let match = String(text[range])
            if let colonRange = match.range(of: "Response:", options: .caseInsensitive) {
                response = match[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Extract "Subject:" line (single line after "Subject:")
        var subject: String?
        if let range = text.range(of: #"(?mi)^Subject:\s*(.*)$"#, options: .regularExpression) {
            let match = String(text[range])
            if let colonRange = match.range(of: "Subject:", options: .caseInsensitive) {
                let s = match[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { subject = s }
            }
        }

        // Extract "Body:" — everything after it (multiline)
        var body: String?
        if let range = text.range(of: #"(?mi)^Body:\s*([\s\S]*)$"#, options: .regularExpression) {
            let match = String(text[range])
            if let colonRange = match.range(of: "Body:", options: .caseInsensitive) {
                let b = match[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty { body = b }
            }
        }

        // Parse recipient deltas. A field gets a non-nil delta iff the LLM emitted
        // either `+X:` or `-X:` (or both).
        let toDelta = parseDeltaForField(text, field: "To")
        let ccDelta = parseDeltaForField(text, field: "Cc")
        let bccDelta = parseDeltaForField(text, field: "Bcc")

        // Fallback: if no Body: found, treat entire text as body (matching TB's processEditResponse)
        if body == nil && subject == nil {
            body = text
        }

        return InlineEditResult(
            response: response,
            subject: subject,
            body: body,
            toDelta: toDelta,
            ccDelta: ccDelta,
            bccDelta: bccDelta,
            raw: rawText
        )
    }

    /// Build a `RecipientDelta` from the `+<field>:` and `-<field>:` lines in the
    /// response. Returns `nil` when neither line is present for that field.
    static func parseDeltaForField(_ text: String, field: String) -> RecipientDelta? {
        let addLine = extractLabelLine(text, prefix: "+", label: field)
        let removeLine = extractLabelLine(text, prefix: "-", label: field)
        if addLine == nil && removeLine == nil { return nil }

        let adds: [ParsedRecipient] = addLine.map { raw in
            splitCommaRespectingQuotes(raw).compactMap { entry in
                let (name, email) = splitNameAndEmail(entry)
                return email.isEmpty ? nil : ParsedRecipient(name: name, email: email)
            }
        } ?? []

        var removes: [String] = []
        if let raw = removeLine {
            // Preserve the "*" sentinel literally; otherwise emit lowercased emails.
            for entry in splitCommaRespectingQuotes(raw) {
                let trimmed = entry.trimmingCharacters(in: .whitespaces)
                if trimmed == "*" {
                    removes.append("*")
                } else {
                    let (_, email) = splitNameAndEmail(trimmed)
                    if !email.isEmpty { removes.append(email.lowercased()) }
                }
            }
        }

        return RecipientDelta(adds: adds, removes: removes)
    }

    /// Extract the raw text after `{prefix}{label}:` on its line. Returns `nil` if the line
    /// is absent. `prefix` is escaped for regex use.
    static func extractLabelLine(_ text: String, prefix: String, label: String) -> String? {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        let pattern = "(?mi)^\(escapedPrefix)\(escapedLabel):[ \\t]*(.*)$"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        guard let colonIdx = match.firstIndex(of: ":") else { return "" }
        return String(match[match.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Split a comma-separated recipient list into entries, ignoring commas that appear
    /// inside quoted display names (`"Doe, John" <j@x>`) or inside angle brackets.
    static func splitCommaRespectingQuotes(_ raw: String) -> [String] {
        if raw.isEmpty { return [] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == "<" { inAngles = true; current.append(ch); continue }
            if ch == ">" { inAngles = false; current.append(ch); continue }
            if ch == "," && !inQuotes && !inAngles {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(trimmed) }
                current = ""
                continue
            }
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { items.append(tail) }
        return items
    }

    /// Split an RFC-822-ish "Name <email>" or "<email>" or "email" entry into (name, email).
    static func splitNameAndEmail(_ entry: String) -> (name: String, email: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        if let lt = trimmed.firstIndex(of: "<"),
           let gt = trimmed.firstIndex(of: ">"),
           gt > lt {
            let email = String(trimmed[trimmed.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            return (name, email)
        }
        return ("", trimmed)
    }
}
