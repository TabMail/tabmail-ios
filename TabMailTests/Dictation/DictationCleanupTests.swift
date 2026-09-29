/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

struct DictationContextTests {
    private func message(_ role: ChatMessage.Role, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: Date())
    }

    /// The prompt's markers: plain lines for what is on screen, `» ` lines for the field being
    /// dictated into, `‸` where the dictation lands (the end: it is appended).
    @Test func laysOutThePillAsTheCleanupPromptReadsAScreen() {
        let context = DictationContext.chatPill(
            title: "Quarterly planning",
            header: ["From: Jordan Example <jordan@example.com>", "Subject: Quarterly planning"],
            messages: [
                message(.user, "Summarise this"),
                message(.warning, "Indexing is still running"),
                message(.agent, "Jordan asks about the roadmap."),
            ],
            input: "Reply that I'll send\nthe draft to"
        )

        #expect(context.windowTitle == "Quarterly planning")
        #expect(context.screenText == """
        From: Jordan Example <jordan@example.com>
        Subject: Quarterly planning
        Me: Summarise this
        TabMail: Jordan asks about the roadmap.
        » Reply that I'll send
        » the draft to‸
        """)
    }

    /// The terms are picked from all of the pill, uncut: its title, the email's header, the chat and
    /// the input, past the cleanup's window.
    @Test func theTermsAreFromAllOfThePillUncut() {
        let long = String(repeating: "and so on ", count: DictationConfig.contextMaxScreenChars / 5)
        let context = DictationContext.chatPill(
            title: "Planning with Xyvora",
            header: ["From: Kaelthorne Drake"],
            messages: [message(.user, "ask Brevalle " + long)],
            input: "cc Quill"
        )

        #expect(DictationContextTerms.terms(in: context.termsText, excluding: [], max: DictationConfig.contextTermsMax)
            .sorted() == ["Brevalle", "Kaelthorne Drake", "Quill", "Xyvora"])
        #expect(!context.screenText.contains("Brevalle"))
    }

    @Test func anEmptyInputIsStillTheFieldWithItsCaret() {
        let context = DictationContext.chatPill(title: "Chat", header: [], messages: [], input: "")
        #expect(context.screenText == "» ‸")
    }

    @Test func keepsOnlyTheLatestChatTurns() {
        let messages = (0..<(DictationConfig.contextMaxChatMessages + 5)).map { message(.user, "turn \($0)") }
        let context = DictationContext.chatPill(title: "Chat", header: [], messages: messages, input: "")
        let lines = context.screenText.components(separatedBy: "\n")

        #expect(lines.count == DictationConfig.contextMaxChatMessages + 1)
        #expect(lines.first == "Me: turn 5")
    }

    /// A long chat is cut from the start: the text nearest the caret is what the cleanup needs.
    @Test func aLongScreenKeepsTheTextNearestTheCaret() {
        let long = String(repeating: "a", count: DictationConfig.contextMaxScreenChars)
        let context = DictationContext.chatPill(title: "Chat", header: [long], messages: [], input: "hello")

        #expect(context.screenText.count == DictationConfig.contextMaxScreenChars)
        #expect(context.screenText.hasSuffix("\n» hello‸"))
    }

    /// Owner, 2026-09-28, as in TabMail Voice: the cleanup is a light pass, so it gets only about
    /// a paragraph before the caret (and at most 1.5 s, which the backend enforces, ADR-027).
    @Test func theCleanupStaysLight() {
        let draft = String(repeating: "Quarterly numbers are in. ", count: 200)
        let context = DictationContext.chatPill(title: "Edit draft", header: ["Subject: Update", draft], messages: [], input: "hello")

        #expect(context.screenText.count <= 500)
        #expect(context.screenText.hasSuffix("\n» hello‸"))
    }
}

struct DictationCleanupTests {
    private let transcript = "ask jordan about the road map"

    /// The prompt's variables other than the transcript, which the backend adds (ADR-027): exactly
    /// the keys it accepts, all strings.
    @Test func sendsWhereTheDictationGoesAndWhatIsOnScreen() {
        let variables = DictationCleanup.variables(
            context: DictationContext(windowTitle: "Weekly sync", screenText: "Me: hi\n» ‸"),
            dictionary: ["Xyvora", "Kaelthorne Drake"]
        )

        #expect(variables == [
            "app_name": "TabMail",
            "web_host": "",
            "terminal_program": "",
            "window_title": "Weekly sync",
            "screen_text": "Me: hi\n» ‸",
            // The user's dictionary, one word per line (ADR-IOS-086).
            "dictionary": "Xyvora\nKaelthorne Drake",
        ])
    }

    /// The backend refuses the whole dictation when a cleanup field is over its limit (ADR-027),
    /// counted in UTF-16 code units. The window title is the email's subject, which its sender
    /// chooses, so every field is cut to the limit, between characters: a title keeps its start,
    /// the screen text its end, where the caret is.
    @Test func everyFieldStaysWithinTheBackendsLimit() {
        let limit = DictationConfig.cleanupFieldMaxUTF16
        // An emoji is two code units: one straddling the limit is left out whole.
        let title = String(repeating: "t", count: limit - 1) + "😀" + "tail"
        let screen = "head" + "😀" + String(repeating: "s", count: limit - 1) + "‸"
        let variables = DictationCleanup.variables(context: DictationContext(windowTitle: title, screenText: screen), dictionary: [])

        #expect(variables["window_title"] == String(repeating: "t", count: limit - 1))
        #expect(variables["screen_text"] == String(repeating: "s", count: limit - 1) + "‸")
        for (key, value) in variables {
            #expect(value.utf16.count <= limit, "\(key)")
        }
    }

    @Test func aFieldAtTheLimitIsSentWhole() {
        let limit = DictationConfig.cleanupFieldMaxUTF16
        let title = String(repeating: "t", count: limit)
        let screen = String(repeating: "s", count: limit - 1) + "‸"
        let variables = DictationCleanup.variables(context: DictationContext(windowTitle: title, screenText: screen), dictionary: [])

        #expect(variables["window_title"] == title)
        #expect(variables["screen_text"] == screen)
    }

    /// The pill's screen text is cut to `contextMaxScreenChars` characters, but a character can be
    /// many code units: 500 letters with 40 combining marks each are 20,500.
    @Test func aScreenOfLongCharactersStaysWithinTheLimit() {
        let heavy = "a" + String(repeating: "\u{0301}", count: 40)
        let context = DictationContext.chatPill(title: heavy, header: [String(repeating: heavy, count: DictationConfig.contextMaxScreenChars)], messages: [], input: "")
        #expect(context.screenText.utf16.count > DictationConfig.cleanupFieldMaxUTF16)

        let variables = DictationCleanup.variables(context: context, dictionary: [])
        #expect(variables.values.allSatisfy { $0.utf16.count <= DictationConfig.cleanupFieldMaxUTF16 })
        #expect(variables["screen_text"]?.hasSuffix("» ‸") == true)
    }

    @Test func appendsTheCleanedUpTextTrimmed() {
        #expect(DictationCleanup.pasted(transcript: transcript, cleanedText: " Ask Jordan about the roadmap.\n") == "Ask Jordan about the roadmap.")
    }

    /// The backend answers `""` when its cleanup failed or ran past its deadline, and nothing from
    /// a backend without the cleanup: the transcript is appended as heard.
    @Test(arguments: ["", " \n", nil] as [String?])
    func withoutCleanedTextTheTranscriptIsAppendedAsHeard(cleanedText: String?) {
        #expect(DictationCleanup.pasted(transcript: transcript, cleanedText: cleanedText) == transcript)
    }
}
