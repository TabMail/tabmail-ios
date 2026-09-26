/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
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
}

struct DictationCleanupTests {
    private let transcript = "ask jordan about the road map"
    private let context = DictationContext(windowTitle: "Chat", screenText: "» ‸")

    @Test func sendsTheDictationWithWhereItGoesAndWhatIsOnScreen() throws {
        let message = DictationCleanup.message(dictation: "quarterly road map", context: DictationContext(windowTitle: "Weekly sync", screenText: "Me: hi\n» ‸"))

        #expect(message.role == "system")
        // The backend's prompt name, spelled out: comparing with the config would pass a typo.
        #expect(message.content == "system_prompt_dictate_cleanup")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: String]
        #expect(json == [
            "role": "system",
            "content": "system_prompt_dictate_cleanup",
            "dictation": "quarterly road map",
            "app_name": "TabMail",
            "web_host": "",
            "terminal_program": "",
            "window_title": "Weekly sync",
            "screen_text": "Me: hi\n» ‸",
        ])
    }

    @Test func usesTheCleanedUpTextAndAsksWithoutToolsOrWebSearch() async throws {
        let sent = Mutex<CompletionsRequest?>(nil)
        let text = await DictationCleanup.cleanUp(transcript, context: context) { request in
            sent.withLock { $0 = request }
            return CompletionsResponse(assistant: " Ask Jordan about the roadmap.\n", token_usage: nil, error: nil)
        }

        #expect(text == "Ask Jordan about the roadmap.")
        let request = try #require(sent.withLock { $0 })
        #expect(request.disable_tools == true)
        #expect(request.web_search_enabled == false)
        #expect(request.messages.count == 1)
        #expect(request.messages.first?.content == "system_prompt_dictate_cleanup")
    }

    @Test(arguments: [
        CompletionsResponse(assistant: nil, token_usage: nil, error: "Requested prompt is not available"),
        CompletionsResponse(assistant: "Ask Jordan", token_usage: nil, error: "internal_error"),
        CompletionsResponse(assistant: " \n", token_usage: nil, error: nil),
        CompletionsResponse(assistant: nil, token_usage: nil, error: nil),
    ])
    func aReplyWithoutTextUsesTheTranscriptAsHeard(response: CompletionsResponse) async {
        let text = await DictationCleanup.cleanUp(transcript, context: context) { _ in response }
        #expect(text == transcript)
    }

    @Test func aFailedCleanupUsesTheTranscriptAsHeard() async {
        let text = await DictationCleanup.cleanUp(transcript, context: context) { _ in
            throw BackendError.requestFailed(statusCode: 500)
        }
        #expect(text == transcript)
    }

    /// A cleanup still running at its timeout is abandoned without waiting for the reply.
    @Test func aCleanupPastItsTimeoutUsesTheTranscriptAsHeard() async {
        let clock = ContinuousClock()
        let started = clock.now
        let text = await DictationCleanup.cleanUp(transcript, context: context, complete: { _ in
            try await Task.sleep(for: .seconds(5))
            return CompletionsResponse(assistant: "Ask Jordan about the roadmap.", token_usage: nil, error: nil)
        }, timeout: 0.2)

        #expect(text == transcript)
        #expect(clock.now - started < .seconds(2))
    }
}
