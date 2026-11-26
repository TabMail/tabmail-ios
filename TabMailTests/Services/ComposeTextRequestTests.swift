/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The chat view's closed field's request (ADR-IOS-114 decision 10, amended 2026-11-26), read at
/// `POST /completions/chat` as the backend receives it.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The words the user sent reach the backend exactly as sent, as `user_text`, never wrapped in
///     an instruction and never as a request about a reply: the backend writes the email that says
///     them (before, "Reply to email with subject ... with request: <words>" let the model answer a
///     question the user was asking).
///  2. One system message, `system_prompt_compose_text`, with no tools; the variables are the
///     compose-text set for its mode and nothing of the compose edit's (no draft body, edit
///     request, edit history or recipient list).
///  3. The answer is the compose edit JSON, read by the one reader; one that writes no email fails.
///
/// `.processGlobalState`: `AIService` reads the App Group opt-out flag; the test pins it off.
@Suite(.serialized, .processGlobalState)
struct ComposeTextRequestTests {

    /// The words of the followup fixture: a question the user asks the other person.
    static let words = "Hey, this is an additional message asking if the first test went through"

    /// The backend's answer to the followup fixture.
    static let fixtureAnswer = ComposeEditJSON.make(
        response: "Wrote a follow-up asking whether the first test arrived.", subject: "Re: Test",
        body: "Hi Sam,\n\nA quick follow-up: did my first test email come through?\n\nBest,\nAlex Kim",
        textMessage: "Did my first test email come through?", changeCommand: "No rush, reply whenever you can")

    /// The variables every mode sends.
    static let commonKeys: Set<String> = [
        "mode", "user_text", "user_name", "user_composition_prompt", "user_kb_content", "current_time",
        "current_subject", "original_to", "original_cc", "original_bcc",
    ]
    /// The variables only a thread's modes send: the email shown.
    static let emailKeys: Set<String> = [
        "message", "quotes_section", "related_date", "related_subject", "related_from", "related_to", "related_cc",
    ]
    /// The compose edit's variables, none of which the compose text sends.
    static let editKeys = [
        "current_body", "user_request", "edit_conversation_history", "recipients_json", "recipients_formatted",
    ]

    /// Answers `/completions/chat` with `assistant` (nil: an HTTP error) and reads back every request.
    final class Backend: Sendable {
        let http = FakeHTTP.Scenario()

        init(assistant: String?) {
            http.register(path: "/completions/chat", method: "POST") { _ in
                guard let assistant else { return .status(500) }
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                let stream = "event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n"
                return .bytes(Data(stream.utf8), contentType: "text/event-stream")
            }
        }

        /// Every request body received, in order.
        var requests: [[String: Any]] {
            http.recordedCalls().map { call in
                call.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            }
        }
    }

    /// The draft of the followup fixture: the user's own email to Sam, its subject "Re: Test".
    static func followupContext(bodyText: String = "Hi Sam,\n\nSending a first test.\n\nBest,\nAlex") -> ComposeEditContext {
        ComposeEditContext(
            recipients: ["sam@example.com"], toRecipients: ["sam@example.com"], ccRecipients: [], bccRecipients: [],
            toDisplayNames: ["sam@example.com": "Sam Lee"], ccDisplayNames: [:], bccDisplayNames: [:],
            senderName: "Alex Kim", senderEmail: "alex@example.com", mode: ComposeTextMode.followup.rawValue,
            compositionPrompt: "Keep it short.", kbText: "I work on the test team.",
            relatedDate: "2026-11-26 01:10 (Thursday)", relatedSubject: "Test", relatedFrom: "Alex Kim <alex@example.com>",
            relatedTo: "Sam Lee <sam@example.com>", relatedCc: "", bodyText: bodyText)
    }

    static func service(_ backend: Backend) -> AIService {
        AIService(backendClient: BackendClient(llmSession: backend.http.session))
    }

    @Test("The followup request is the contract's: the words verbatim as user_text, the email shown, no tools, nothing of the edit")
    func followupRequestMatchesTheContract() async throws {
        try await AITestSetting.with(aiOff: false) {
            let backend = Backend(assistant: Self.fixtureAnswer)
            let result = try await Self.service(backend).performComposeText(
                .followup, userText: Self.words, subject: "Re: Test", context: Self.followupContext())

            let requests = backend.requests
            #expect(requests.count == 1, "one request")
            guard requests.count == 1 else { return }
            let request = requests[0]
            #expect(request["disable_tools"] as? Bool == true, "no tools: the email says only what the words say")
            #expect(request["client_timezone"] as? String == TimeZone.current.identifier)
            let messages = try #require(request["messages"] as? [[String: Any]])
            #expect(messages.count == 1, "one system message")
            guard messages.count == 1 else { return }
            let message = messages[0]
            #expect(message["role"] as? String == "system")
            #expect(message["content"] as? String == "system_prompt_compose_text")
            let keys = Set(message.keys).subtracting(["role", "content"])
            #expect(keys == Self.commonKeys.union(Self.emailKeys), "exactly the contract's variables: \(keys.sorted())")
            for key in Self.editKeys {
                #expect(message[key] == nil, "\(key) is the compose edit's, never sent")
            }
            #expect(message["mode"] as? String == "text_followup")
            #expect(message["user_text"] as? String == Self.words, "the words as sent, nothing around them")
            #expect(message["user_name"] as? String == "Alex Kim")
            #expect(message["user_composition_prompt"] as? String == "Keep it short.")
            #expect(message["user_kb_content"] as? String == "I work on the test team.")
            #expect((message["current_time"] as? String)?.isEmpty == false)
            #expect(message["current_subject"] as? String == "Re: Test")
            #expect(message["original_to"] as? String == "Sam Lee <sam@example.com>")
            #expect(message["original_cc"] as? String == "" && message["original_bcc"] as? String == "")
            #expect(message["message"] as? String == "Hi Sam,\n\nSending a first test.\n\nBest,\nAlex")
            #expect(message["quotes_section"] as? String == "")
            #expect(message["related_date"] as? String == "2026-11-26 01:10 (Thursday)")
            #expect(message["related_subject"] as? String == "Test")
            #expect(message["related_from"] as? String == "Alex Kim <alex@example.com>")
            #expect(message["related_to"] as? String == "Sam Lee <sam@example.com>")
            #expect(message["related_cc"] as? String == "")
            // Nothing anywhere in the request wraps the words in an instruction.
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            #expect(!wire.contains("with request:") && !wire.contains("Reply to email with subject"), "no instruction around the words")

            // The answer, read by the one compose edit reader.
            #expect(result.body == "Hi Sam,\n\nA quick follow-up: did my first test email come through?\n\nBest,\nAlex Kim")
            #expect(result.textMessage == "Did my first test email come through?")
            #expect(result.changeCommand == "No rush, reply whenever you can", "the alternative the field offers next")
            #expect(result.subject == "Re: Test")
            #expect(result.toDelta == nil && result.ccDelta == nil && result.bccDelta == nil, "no recipient change")
        }
    }

    @Test("A reply carries someone else's email the same way, its quotes split out; a new email carries no email",
          arguments: ComposeTextMode.allCases)
    func everyModeSendsItsVariables(_ mode: ComposeTextMode) {
        let body = "Sounds good to me.\n\nOn Mon, Sam Lee <sam@example.com> wrote:\n> Are you in for Friday?"
        let split = EmailFilter.splitMessageAndQuotes(body)
        #expect(!split.quotes.isEmpty, "control: the body holds a quote")
        let message = AIService.composeTextMessage(
            mode, userText: "yes friday works", subject: "Re: Friday", context: Self.followupContext(bodyText: body))
        #expect(message.role == "system" && message.content == "system_prompt_compose_text")
        let keys = Set(message.vars.keys)
        #expect(keys == (mode.hasEmail ? Self.commonKeys.union(Self.emailKeys) : Self.commonKeys), "\(mode): \(keys.sorted())")
        #expect(message.vars["mode"] == .string(mode.rawValue))
        #expect(message.vars["user_text"] == .string("yes friday works"))
        #expect(message.vars["current_subject"] == .string("Re: Friday"))
        if mode.hasEmail {
            #expect(message.vars["message"] == .string(split.message))
            #expect(message.vars["quotes_section"] == .string(split.quotes))
        }
    }

    @Test("The mode follows whose email the field shows")
    func modeFollowsWhoseEmail() {
        #expect(ComposeTextMode.thread(sentByUser: false) == .reply)
        #expect(ComposeTextMode.thread(sentByUser: true) == .followup)
        #expect(ComposeTextMode.reply.rawValue == "text_reply" && ComposeTextMode.followup.rawValue == "text_followup"
                && ComposeTextMode.new.rawValue == "text_new")
        #expect(ComposeTextMode.reply.hasEmail && ComposeTextMode.followup.hasEmail && !ComposeTextMode.new.hasEmail)
    }

    /// The contract's failures: no JSON, a missing field, a blank body or text message, an HTTP
    /// error. Each throws, so the field writes nothing and keeps the words.
    static let failures: [(String, String?)] = [
        ("no JSON", "Did my first test email come through?"),
        ("no body", ComposeEditJSON.make(response: "Done.", subject: "Re: Test", body: "", textMessage: "Hi", changeCommand: "")),
        ("blank text message", ComposeEditJSON.make(response: "Done.", subject: "Re: Test", body: "Hi Sam", textMessage: "  ", changeCommand: "")),
        ("HTTP error", nil),
    ]

    @Test("An answer that writes no email, or an HTTP error, fails the request", arguments: failures)
    func failedAnswerThrows(_ name: String, _ assistant: String?) async {
        await AITestSetting.with(aiOff: false) {
            let backend = Backend(assistant: assistant)
            await #expect(throws: (any Error).self, "\(name)") {
                _ = try await Self.service(backend).performComposeText(
                    .reply, userText: "sounds good", subject: "Re: Test", context: Self.followupContext())
            }
            #expect(backend.requests.count == 1, "control: \(name) was asked once")
        }
    }
}
