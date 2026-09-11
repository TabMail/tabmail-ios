/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension AIService {

    // MARK: - Reply Generation

    /// Generate a precomputed reply for an email, matching TB's `cacheReply()` in replyGenerator.js.
    /// Uses `system_prompt_compose` with mode `precache_reply`. V2: tools enabled (contacts, calendar, etc.).
    func generateReply(
        subject: String,
        from: String,
        fromAddress: String,
        to: String,
        cc: String,
        bodyText: String,
        userName: String,
        compositionPrompt: String,
        kbText: String,
        currentTime: String,
        relatedDate: String,
        relatedSubject: String,
        relatedFrom: String,
        relatedTo: String,
        relatedCc: String
    ) async throws -> String? {
        guard !disableLLMCalls else {
            BackgroundSyncLogger.logDebug("[AIService] generateReply: SKIP — LLM calls disabled")
            return nil
        }

        // Format recipients for the reply (who we're sending to), matching TB's recipientsFormatted
        var recipientLines: [String] = []
        if !to.isEmpty { recipientLines.append("To: \(to)") }
        if !cc.isEmpty { recipientLines.append("Cc: \(cc)") }
        let recipientsFormatted = recipientLines.joined(separator: "\n")

        // "Re:" prefix on subject, matching TB's sendReplyRequest
        let replySubject = subject.hasPrefix("Re: ") ? subject : "Re: \(subject)"

        // Client-side split: send message + quotes separately (no backend heuristic needed)
        let splitBody = EmailFilter.splitMessageAndQuotes(bodyText)

        #if DEBUG
        // Log all prompt variables for debugging (full text, not truncated)
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === PROMPT VARS ===")
        BackgroundSyncLogger.logDebug("[AIService]   mode=precache_reply")
        BackgroundSyncLogger.logDebug("[AIService]   user_name=\(userName)")
        BackgroundSyncLogger.logDebug("[AIService]   user_composition_prompt=\(compositionPrompt)")
        BackgroundSyncLogger.logDebug("[AIService]   recipients_formatted=\(recipientsFormatted)")
        BackgroundSyncLogger.logDebug("[AIService]   current_subject=\(replySubject)")
        BackgroundSyncLogger.logDebug("[AIService]   current_body=(empty)")
        BackgroundSyncLogger.logDebug("[AIService]   user_request=Write a reply to this email.")
        BackgroundSyncLogger.logDebug("[AIService]   user_kb_content=\(kbText)")
        BackgroundSyncLogger.logDebug("[AIService]   current_time=\(currentTime)")
        BackgroundSyncLogger.logDebug("[AIService]   message=\(splitBody.message.prefix(200))")
        BackgroundSyncLogger.logDebug("[AIService]   quotes_section=\(splitBody.quotes.prefix(200))")
        BackgroundSyncLogger.logDebug("[AIService]   related_date=\(relatedDate)")
        BackgroundSyncLogger.logDebug("[AIService]   related_subject=\(relatedSubject)")
        BackgroundSyncLogger.logDebug("[AIService]   related_from=\(relatedFrom)")
        BackgroundSyncLogger.logDebug("[AIService]   related_to=\(relatedTo)")
        BackgroundSyncLogger.logDebug("[AIService]   related_cc=\(relatedCc.isEmpty ? "(empty)" : relatedCc)")
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === END PROMPT VARS ===")
        #endif

        let vars: [String: JSONValue] = [
            "mode": .string("precache_reply"),
            "user_name": .string(userName),
            "user_composition_prompt": .string(compositionPrompt),
            "recipients_formatted": .string(recipientsFormatted),
            "current_subject": .string(replySubject),
            "current_body": .string(""), // Empty — generating from scratch
            "user_request": .string("Write a reply to this email."),
            "user_kb_content": .string(kbText),
            "current_time": .string(currentTime),
            "message": .string(splitBody.message),
            "quotes_section": .string(splitBody.quotes),
            "related_date": .string(relatedDate),
            "related_subject": .string(relatedSubject),
            "related_from": .string(relatedFrom),
            "related_to": .string(relatedTo),
            "related_cc": .string(relatedCc),
        ]

        let message = CompletionsMessage(
            role: "system",
            content: "system_prompt_compose",
            vars: vars
        )

        let request = CompletionsRequest(
            messages: [message],
            client_timezone: TimeZone.current.identifier,
            disable_tools: false // V2: tools enabled (contacts, calendar, etc.)
        )

        BackgroundSyncLogger.logDebug("[AIService] generateReply: sending to backend (disable_tools=false, timezone=\(TimeZone.current.identifier))")
        let llmT0 = CFAbsoluteTimeGetCurrent()
        BackgroundSyncLogger.logAIProcessing("Reply LLM START (body.len=\(bodyText.count))")
        let response = try await backend.sendCompletionsWithTools(request)
        let llmElapsed = Int((CFAbsoluteTimeGetCurrent() - llmT0) * 1000)
        BackgroundSyncLogger.logAIProcessing("Reply LLM END in \(llmElapsed)ms")

        guard let text = response.assistant, !text.isEmpty else {
            BackgroundSyncLogger.logDebug("[AIService] Reply: no assistant text in response (error=\(response.error ?? "nil"))")
            return nil
        }

        #if DEBUG
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === RAW RESPONSE ===")
        BackgroundSyncLogger.logDebug("[AIService]   \(text)")
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === END RAW RESPONSE ===")
        #endif

        // Parse compose response (Subject: / Body: format), matching TB's processEditResponse
        let parsed = Self.parseComposeResponse(text)
        #if DEBUG
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === PARSED BODY ===")
        BackgroundSyncLogger.logDebug("[AIService]   \(parsed)")
        BackgroundSyncLogger.logDebug("[AIService] generateReply: === END PARSED BODY ===")
        #endif
        return parsed
    }

    // MARK: - Reply Processing (standalone step, called after summary+action)

    /// Generate or retrieve a cached reply for a message.
    /// Returns nil if quality filters exclude it (no-reply, self-sent).
    /// Per-message dedup is handled by queue dedup (QueueStorage) and GRDB field checks.
    /// Runs in parallel with SA — does NOT depend on summary/action output.
    func processReply(
        messageId: String,
        rfc822MessageId: String?,
        accountEmail: String,
        subject: String,
        from: String,
        fromAddress: String,
        to: String,
        date: Date,
        bodyText: String,
        htmlContent: String?,
        userName: String,
        kbText: String,
        compositionPrompt: String
    ) async throws -> String? {
        BackgroundSyncLogger.logDebug("[AIService] processReply START for \(messageId)")
        BackgroundSyncLogger.logDebug("[AIService]   subject=\(subject.prefix(60))")
        BackgroundSyncLogger.logDebug("[AIService]   from=\(from) fromAddress=\(fromAddress)")
        BackgroundSyncLogger.logDebug("[AIService]   to=\(to.prefix(80))")
        BackgroundSyncLogger.logDebug("[AIService]   userName=\(userName)")
        BackgroundSyncLogger.logDebug("[AIService]   bodyText length=\(bodyText.count)")
        BackgroundSyncLogger.logDebug("[AIService]   compositionPrompt length=\(compositionPrompt.count)")
        BackgroundSyncLogger.logDebug("[AIService]   kbText length=\(kbText.count)")

        // Quality filters (matching TB's analyzeEmailForReplyFilter + isInternalSender)
        let isNoReply = EmailFilter.isNoReply(fromAddress)
        // Check ALL user accounts, not just the current one — matches TB's getUserEmailSetCached()
        let isSelfSent = EmailFilter.isSelfSent(fromAddress)
        if isNoReply || isSelfSent {
            BackgroundSyncLogger.logDebug("[AIService] Reply: skipping \(messageId) — noReply=\(isNoReply) self=\(isSelfSent)")
            return "" // empty sentinel: filtered, no reply needed (distinct from nil = error/retry)
        }

        // Format date for prompt — match TB's formatTimestampForAgent
        let relatedDate = Self.formatTimestampForAgent(date)

        // Current time for prompt — match TB's formatTimestampForAgent
        let currentTime = Self.formatTimestampForAgent(Date())

        // Build reply details matching TB's sendReplyRequest:
        // TB's lastMessage.author = "Name <email>" format — iOS stores these separately.
        // details.to = lastMessage.author (original sender) — who we're replying TO
        // details.cc = lastMessage.recipients (original To: recipients) — CC on our reply
        // details.related_from = lastMessage.author (original sender for context)
        // details.related_to = lastMessage.recipients (original To: header for context)
        // details.related_cc = lastMessage.ccList (original CC header for context)
        let fromFormatted = fromAddress.isEmpty ? from : "\(from) <\(fromAddress)>"  // "Name <email>" like TB's author
        let replyTo = fromFormatted   // Original sender — matches TB's details.to = lastMessage.author
        let replyCc = to             // Original To: recipients — matches TB's details.cc = recipients

        // Device Sync probe: ask peer for cached reply before running LLM
        if let probeKey = rfc822MessageId {
            if let probeResults = await DeviceSyncService.shared.probeAICache(keys: [probeKey]),
               let cached = probeResults[probeKey],
               let peerReply = cached.reply, !peerReply.isEmpty {
                BackgroundSyncLogger.logDebug("[AIService] Reply Device Sync HIT for \(messageId)")
                return peerReply
            }
        }

        let reply = try await generateReply(
            subject: subject,
            from: from,
            fromAddress: fromAddress,
            to: replyTo,
            cc: replyCc,
            bodyText: bodyText,
            userName: userName,
            compositionPrompt: compositionPrompt,
            kbText: kbText,
            currentTime: currentTime,
            relatedDate: relatedDate,
            relatedSubject: subject,
            relatedFrom: fromFormatted,  // "Name <email>" like TB's related_from
            relatedTo: to,
            relatedCc: ""  // iOS MessageHeader doesn't store CC; empty for now (matches TB when ccList is empty)
        )

        if let reply, !reply.isEmpty {
            BackgroundSyncLogger.logDebug("[AIService] Reply generated for \(messageId): \(reply.prefix(80))...")
        } else {
            BackgroundSyncLogger.logDebug("[AIService] Reply: no content generated for \(messageId)")
        }

        return reply
    }

    /// Parse compose/edit response from LLM, matching TB's `processEditResponse()` in llm.js.
    /// Looks for "Body:" section marker; returns everything after it, or raw text as fallback.
    static func parseComposeResponse(_ rawText: String) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match "Body:" at the start of a line (case-insensitive), capture everything after it
        if let range = text.range(of: #"(?mi)^Body:\s*([\s\S]*)$"#, options: .regularExpression) {
            let match = String(text[range])
            // Strip the "Body:" prefix
            if let colonRange = match.range(of: "Body:", options: .caseInsensitive) {
                let body = match[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { return body }
            }
        }

        // Fallback: return raw text (same as TB's `parsed.message || assistantResp`)
        return text
    }
}
