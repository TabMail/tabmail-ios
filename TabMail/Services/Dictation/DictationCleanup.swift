/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What the user sees when a dictation starts, for the cleanup: the chat pill's equivalent of
/// TabMail Voice's screen read. Captured once, when the dictation starts.
struct DictationContext: Sendable, Equatable {
    var windowTitle: String
    /// In the markers the cleanup prompt reads: plain lines for what is on screen, `» ` lines
    /// for the field being dictated into, `‸` at the caret (the end of the field: dictation
    /// is appended there).
    var screenText: String
    /// All of it, uncut and without the markers, where the terms sent with the dictation are picked
    /// (`DictationContextTerms`).
    var termsText = ""
    /// The email the pill is about (its `messageHeader.id`): its body is read for terms too.
    var emailId: String?

    /// The chat pill: what it is about (`header`, e.g. the email on screen, and `emailId`, that
    /// email), the latest chat turns, and the input field with the caret at its end.
    static func chatPill(title: String, header: [String], messages: [ChatMessage], input: String, emailId: String? = nil) -> DictationContext {
        let turns = messages.suffix(DictationConfig.contextMaxChatMessages).compactMap { message -> String? in
            switch message.role {
            case .user: "Me: \(message.content)"
            case .agent: "TabMail: \(message.content)"
            case .warning: nil
            }
        }
        let field = (input + "‸").components(separatedBy: "\n").map { "» " + $0 }
        let text = (header + turns + field).joined(separator: "\n")
        // Bounds the cleanup model's input only (its context window); the most recent text,
        // ending at the caret, is kept. Nothing is stored.
        return DictationContext(
            windowTitle: title, screenText: String(text.suffix(DictationConfig.contextMaxScreenChars)),
            termsText: ([title] + header + turns + [input]).joined(separator: "\n"), emailId: emailId
        )
    }
}

/// The backend pass over a transcript: with what was on screen when the dictation started, it
/// fixes speech-recognition errors (names and terms shown on screen, capitalisation that doesn't
/// fit where the text lands) and changes nothing else. The instructions live in the backend
/// prompt `DictationConfig.cleanupPrompt`, shared with TabMail Voice.
enum DictationCleanup {
    typealias Complete = @Sendable (CompletionsRequest) async throws -> CompletionsResponse

    /// The transcript with its recognition errors fixed. When the cleanup fails for any reason,
    /// including no reply within `timeout` seconds, the transcript as heard: a failed cleanup
    /// never costs the user their dictation.
    static func cleanUp(
        _ transcript: String, context: DictationContext, dictionary: [String], complete: @escaping Complete,
        timeout: TimeInterval = DictationConfig.cleanupTimeout
    ) async -> String {
        let request = CompletionsRequest(
            messages: [message(dictation: transcript, context: context, dictionary: dictionary)],
            client_timezone: TimeZone.current.identifier,
            disable_tools: true,
            web_search_enabled: false
        )
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let response = try await withTimeout(seconds: timeout) { try await complete(request) }
            let text = (response.assistant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The prompt never removes dictated words, so an empty reply is a malfunction.
            guard response.error == nil, !text.isEmpty else {
                BackgroundSyncLogger.logDebug("[Dictation] cleanup returned no text (error=\(response.error != nil)); using the transcript as heard")
                return transcript
            }
            BackgroundSyncLogger.logDebug("[Dictation] cleaned up in \(clock.now - started) (\(transcript.count) → \(text.count) chars, screen text \(context.screenText.count) chars)")
            return text
        } catch {
            BackgroundSyncLogger.logDebug("[Dictation] cleanup failed after \(clock.now - started): \(type(of: error)); using the transcript as heard")
            return transcript
        }
    }

    /// The prompt and its variables. Fields that don't apply on iOS are sent empty; the prompt
    /// reads an empty field as unknown. `dictionary`: the user's words, one per line (ADR-IOS-086).
    static func message(dictation: String, context: DictationContext, dictionary: [String]) -> CompletionsMessage {
        CompletionsMessage(role: "system", content: DictationConfig.cleanupPrompt, vars: [
            "dictation": .string(dictation),
            "app_name": .string(DictationConfig.contextAppName),
            "web_host": .string(""),
            "terminal_program": .string(""),
            "window_title": .string(context.windowTitle),
            "screen_text": .string(context.screenText),
            "dictionary": .string(dictionary.joined(separator: "\n")),
        ])
    }
}
