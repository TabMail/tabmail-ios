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
/// fit where the text lands) and changes nothing else. It runs in the transcription request
/// (backend ADR-027), under the backend's deadline, with the prompt `system_prompt_dictate_cleanup`
/// shared with TabMail Voice.
enum DictationCleanup {
    /// The prompt's variables other than the transcript, sent as the transcription's `cleanup`.
    /// Fields that don't apply on iOS are sent empty; the prompt reads an empty field as unknown.
    /// `dictionary`: the user's words, one per line (ADR-IOS-086).
    static func variables(context: DictationContext, dictionary: [String]) -> [String: String] {
        [
            "app_name": DictationConfig.contextAppName,
            "web_host": "",
            "terminal_program": "",
            "window_title": context.windowTitle,
            "screen_text": context.screenText,
            "dictionary": dictionary.joined(separator: "\n"),
        ]
    }

    /// The text appended: the cleaned-up transcript, or the transcript as heard when the cleanup
    /// came back empty (it failed, or ran past the backend's deadline) or didn't run (a backend
    /// without ADR-027 answers no `cleaned_text`). A failed cleanup never costs the user their
    /// dictation.
    static func pasted(transcript: String, cleanedText: String?) -> String {
        let cleaned = (cleanedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            BackgroundSyncLogger.logDebug("[Dictation] no cleaned text (\(cleanedText == nil ? "none returned" : "empty")); using the transcript as heard")
            return transcript
        }
        BackgroundSyncLogger.logDebug("[Dictation] cleaned up (\(transcript.count) → \(cleaned.count) chars)")
        return cleaned
    }
}

/// `POST /dictation/transcribe`'s answer: the transcript, and with a `cleanup` sent, the cleaned-up
/// text (`""` when the cleanup failed; nil from a backend that doesn't run it).
struct DictationTranscription: Sendable, Equatable {
    let text: String
    let cleanedText: String?
}
