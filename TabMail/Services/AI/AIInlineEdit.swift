/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail

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

extension ComposeEditContext {
    /// THE context of a compose edit, built the same for the compose card and for the chat field's
    /// edit of the AI Suggestion, so the backend reads the same draft from either: the draft's
    /// To, Cc and Bcc by role with their names, the sending account, and the email replied to or
    /// forwarded (`related`) with its body text (`relatedBodyText`; nil: its snippet).
    static func make(
        recipients: ComposeDraftGuards.Recipients, account: Account?, mode: String, related: MessageHeader?,
        relatedBodyText: String?, compositionPrompt: String, kbText: String
    ) -> ComposeEditContext {
        ComposeEditContext(
            recipients: recipients.to.tokens,
            toRecipients: recipients.to.tokens,
            ccRecipients: recipients.cc.tokens,
            bccRecipients: recipients.bcc.tokens,
            toDisplayNames: recipients.to.displayNames,
            ccDisplayNames: recipients.cc.displayNames,
            bccDisplayNames: recipients.bcc.displayNames,
            senderName: account?.displayName ?? "",
            senderEmail: account?.emailAddress ?? "",
            mode: mode,
            compositionPrompt: compositionPrompt,
            kbText: kbText,
            relatedDate: related.map { AIService.formatTimestampForAgent($0.date) } ?? "",
            relatedSubject: related?.subject ?? "",
            relatedFrom: related.map { $0.fromAddress.isEmpty ? $0.from : "\($0.from) <\($0.fromAddress)>" } ?? "",
            relatedTo: related?.to ?? "",
            relatedCc: related?.cc ?? "",
            bodyText: related.map { relatedBodyText ?? $0.snippet } ?? "")
    }

    /// THE body read of every compose edit's context: the text of `header`'s body, the primary
    /// message only (embedded .eml sections stripped, they are other people's emails), read in the
    /// same snapshot as the check that the row at its address is still that email
    /// (`AIWriteTarget.stillHolds`). The outer nil refuses: another email is seated at the address
    /// (a UIDVALIDITY reset), so its body is never sent with this email's context. The inner nil:
    /// no body is stored (the context then carries the snippet).
    static func relatedBodyText(of header: MessageHeader, db: Database) throws -> String?? {
        guard try AIWriteTarget.stillHolds(header, db: db) else { return nil }
        guard let html = try MessageBody.fetchOne(db, key: header.id)?.htmlContent, !html.isEmpty else { return .some(nil) }
        return .some(EmailFilter.htmlToPlainText(EmailFilter.stripEmbeddedEmlSections(html)))
    }
}

/// A compose edit that came back with no edit: no answer, or one that is not the compose edit
/// JSON. Thrown, so every caller takes its failure path (the chat's error, the suggestion left as
/// it was) and never its success path: no draft update, no edit turn, no save.
struct InlineEditFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A single turn in the inline edit conversation history.
/// Stores the draft state at the time of the request so the LLM can see the full evolution.
struct InlineEditTurn: Sendable {
    let userRequest: String
    let bodyAtRequest: String
    let subjectAtRequest: String
    let assistantResponse: String
    /// The text version stored with `bodyAtRequest` when it was the AI Suggestion shown,
    /// so a resend or rewind that puts that body back keeps its chat-view ghost. Nil when
    /// the body was not the stored suggestion, or for history saved before this was kept.
    var textMessageAtRequest: String? = nil
    /// The change command stored with `bodyAtRequest`, kept like `textMessageAtRequest`.
    var changeCommandAtRequest: String? = nil
}

/// Delta for one recipient field (To / Cc / Bcc) extracted from the LLM response.
/// Applied on top of the current draft's tokens: removals first, then adds.
struct RecipientDelta: Sendable {
    /// The field's add items, one mailbox each, read as recipient text like typed text
    /// (ADR-IOS-092): their mailboxes, with any names the LLM gave.
    let adds: RecipientEntry
    /// Lowercased emails to remove. Contains `"*"` (literal) when the LLM asked to clear
    /// the entire field (`"remove_cc": ["*"]`).
    let removes: [String]

    var clearsField: Bool { removes.contains("*") }
    var isEmpty: Bool { adds.recipients.isEmpty && adds.leftovers.isEmpty && removes.isEmpty }
}

/// Result of an inline edit operation.
struct InlineEditResult: Sendable {
    let response: String?  // Conversational description of edits (`response`)
    let subject: String?   // Updated subject (`subject`)
    let body: String?      // Updated body (`body`)
    /// Delta for the To field. `nil` when `add_to` and `remove_to` are both empty, meaning the
    /// field is left untouched. Non-nil = the LLM intentionally expressed a change.
    let toDelta: RecipientDelta?
    let ccDelta: RecipientDelta?
    let bccDelta: RecipientDelta?
    /// The email as a short text message (`text_message`): what the chat's AI Suggestion shows.
    let textMessage: String?
    /// One suggested change for this draft (`change_command`), shown as the field's "e.g." line.
    let changeCommand: String?
    let raw: String        // Raw LLM response for storing in chat history
}

extension AIService {

    /// What an inline edit returns with AI turned off, at its start or while it runs.
    static let inlineEditWithAIOff = InlineEditResult(
        response: "AI calls are disabled.", subject: nil, body: nil, toDelta: nil, ccDelta: nil, bccDelta: nil,
        textMessage: nil, changeCommand: nil, raw: ""
    )

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
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> InlineEditResult {
        guard !disableLLMCalls else {
            BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: SKIP — LLM calls disabled")
            return Self.inlineEditWithAIOff
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

        BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: mode=\(context.mode) instruction=\(instruction.prefix(80))")
        BackgroundSyncLogger.logDebug("[AIService]   subject=\(currentSubject.prefix(60)) bodyLen=\(currentBody.count)")
        BackgroundSyncLogger.logDebug("[AIService]   chatHistory turns=\(chatHistory.count)")
        BackgroundSyncLogger.logDebug("[AIService]   vars keys=\(vars.keys.sorted().joined(separator: ","))")

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
        BackgroundSyncLogger.logDebug("[AIService]   messages[0] = system (system_prompt_compose_interactive) varsCount=\(vars.count)")
        BackgroundSyncLogger.logDebug("[AIService]   total messages count=\(messages.count)")

        let request = CompletionsRequest(
            messages: messages,
            client_timezone: TimeZone.current.identifier,
            disable_tools: false  // Allow tools for compose (contacts, calendar, etc.)
        )

        // Log raw JSON for debugging
        if DebugModeManager.isLoggingEnabled() {
            if let jsonData = try? JSONEncoder().encode(request),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                BackgroundSyncLogger.logDebug("[AIService] performInlineEdit REQUEST JSON (\(jsonData.count) bytes):")
                // Truncate to avoid flooding logs — print first and last 500 chars
                if jsonStr.count > 1200 {
                    BackgroundSyncLogger.logDebug("[AIService]   \(jsonStr.prefix(500))...TRUNCATED...\(jsonStr.suffix(500))")
                } else {
                    BackgroundSyncLogger.logDebug("[AIService]   \(jsonStr)")
                }
            }
        }

        BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: calling sendCompletionsWithToolsDirect...")
        let response: CompletionsResponse
        do {
            response = try await backend.sendCompletionsWithToolsDirect(request, onSSEEvent: onSSEEvent, invocation: invocation)
        } catch is AIOffError {
            // AI was turned off during the edit: end as the check above does, with no
            // Demo Mode call used.
            if inDemo {
                await MainActor.run { DemoModeStore.shared.refundCall() }
            }
            BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: stopped — AI turned off")
            return Self.inlineEditWithAIOff
        } catch {
            if inDemo, DemoModeStore.shouldRefund(for: error) {
                await MainActor.run { DemoModeStore.shared.refundCall() }
            }
            throw error
        }
        BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: sendCompletionsWithToolsDirect returned — assistant=\(response.assistant != nil) error=\(response.error ?? "nil")")

        guard let text = response.assistant, !text.isEmpty else {
            BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: no assistant text (error=\(response.error ?? "nil"))")
            throw InlineEditFailure(message: response.error ?? "No response from AI.")
        }

        BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: raw response length=\(text.count)")
        BackgroundSyncLogger.logDebug("[AIService]   response preview: \(text.prefix(200))")

        guard let result = Self.parseInlineEditResponse(text) else {
            // Not the compose edit JSON: the edit failed, and the draft stays as it was.
            BackgroundSyncLogger.logDebug("[AIService] performInlineEdit: response is not the compose edit JSON (\(text.count) chars)")
            throw InlineEditFailure(message: "The edit could not be read. Please try again.")
        }
        if DebugModeManager.isLoggingEnabled() {
            let toDesc = result.toDelta.map { "+\($0.adds.recipients.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
            let ccDesc = result.ccDelta.map { "+\($0.adds.recipients.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
            let bccDesc = result.bccDelta.map { "+\($0.adds.recipients.count)/-\($0.removes.count)\($0.clearsField ? "*" : "")" } ?? "nil"
            BackgroundSyncLogger.logDebug("[AIService] performInlineEdit PARSED: response=\(result.response?.prefix(60) ?? "nil") subject=\(result.subject?.prefix(40) ?? "nil") bodyLen=\(result.body?.count ?? 0) to=\(toDesc) cc=\(ccDesc) bcc=\(bccDesc)")
        }
        return result
    }

    /// Read a compose edit as the backend sends it to a client at the JSON protocol
    /// (`TabMailProtocolVersion` 2.0.0, ADR-IOS-114): one JSON object with `response`, the six
    /// recipient changes, `subject`, `body`, `text_message` and `change_command`. This app sends
    /// that marker, so this is the only reader of a compose edit; labelled text is not one.
    ///
    /// Keys this reader does not know are ignored, so a later protocol can add fields. A missing
    /// or malformed known field is an error (nil): a body or text message that is missing or
    /// blank, a wrong type,
    /// an add item without a non-blank email, a blank removal, or `"*"` beside other removals.
    /// An add item's name may be "" (the field then shows the email).
    ///
    /// Each recipient field is a delta: `[]` in both its add and its remove list leaves it
    /// unchanged (nil delta); `["*"]` in a remove list clears it. Each add item is one
    /// recipient and goes through `RecipientEntry` as its own entry, as typed text does
    /// (ADR-IOS-092).
    static func parseInlineEditResponse(_ rawText: String) -> InlineEditResult? {
        struct Added: Decodable {
            let name: String
            let email: String
        }
        struct Edit: Decodable {
            let response: String
            let add_to: [Added]
            let remove_to: [String]
            let add_cc: [Added]
            let remove_cc: [String]
            let add_bcc: [Added]
            let remove_bcc: [String]
            let subject: String
            let body: String
            let text_message: String
            let change_command: String
        }
        guard let data = rawText.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let edit = try? JSONDecoder().decode(Edit.self, from: data),
              !edit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let textMessage = nonBlank(edit.text_message),
              case .some(let toDelta) = recipientDelta(adds: edit.add_to.map { ($0.name, $0.email) }, removes: edit.remove_to),
              case .some(let ccDelta) = recipientDelta(adds: edit.add_cc.map { ($0.name, $0.email) }, removes: edit.remove_cc),
              case .some(let bccDelta) = recipientDelta(adds: edit.add_bcc.map { ($0.name, $0.email) }, removes: edit.remove_bcc)
        else { return nil }

        return InlineEditResult(
            response: nonBlank(edit.response),
            // A blank subject is no subject from the model (the backend sends '' for one): the draft
            // keeps the subject the edit started from. Only a written subject replaces it.
            subject: edit.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : edit.subject,
            // The body as the backend sends it: the draft outside the edit stays verbatim.
            body: edit.body,
            toDelta: toDelta,
            ccDelta: ccDelta,
            bccDelta: bccDelta,
            textMessage: textMessage,
            changeCommand: nonBlank(edit.change_command),
            raw: rawText
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// One recipient field's change from its add items (name, email) and removals. Each item
    /// names exactly one mailbox, read with the address parser every send uses (`RecipientEntry`,
    /// ADR-IOS-092), and an add is written back with that parser's formatter
    /// (`RecipientEntry.text`). The outer nil is a malformed field: an item that names no mailbox or
    /// several, or `"*"` beside other removals, so the edit fails visibly and changes nothing; an
    /// inner nil is an unchanged field (both lists empty).
    static func recipientDelta(adds: [(name: String, email: String)], removes: [String]) -> RecipientDelta?? {
        var addTexts: [String] = []
        for item in adds {
            guard let address = singleMailbox(item.email) else { return .none }
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            addTexts.append(RecipientEntry.text(name: name.isEmpty ? nil : name, address: address))
        }
        var removals: [String] = []
        for item in removes {
            if item.trimmingCharacters(in: .whitespacesAndNewlines) == "*" {
                removals.append("*")
                continue
            }
            guard let address = singleMailbox(item) else { return .none }
            removals.append(address.lowercased())
        }
        if removals.contains("*") && removals.count != 1 { return .none }
        if addTexts.isEmpty && removals.isEmpty { return .some(nil) }
        // Each item is an entry of its own, so nothing joins two items.
        return .some(RecipientDelta(adds: RecipientEntry(addTexts), removes: removals))
    }

    /// The one sendable mailbox `text` names; nil when it names none or several. Read with
    /// SwiftMail's one-element parser (`AddressListEntry`), so an item holding two elements, a group
    /// or the same mailbox twice is malformed, never deduplicated into one.
    private static func singleMailbox(_ text: String) -> String? {
        guard case .mailbox(let mailbox)? = AddressListEntry(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              isValidEmailAddress(mailbox.address) else { return nil }
        return mailbox.address
    }
}
