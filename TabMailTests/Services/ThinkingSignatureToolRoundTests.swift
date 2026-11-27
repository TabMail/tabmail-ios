/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Counts the requests a fake backend handler answered, so it can answer the first differently.
private final class SignatureRoundAnswered: Sendable {
    private let count = Mutex(0)

    /// Counts this request and returns its number, from 1.
    func next() -> Int { count.withLock { $0 += 1; return $0 } }
}

/// A harmless client tool, registered in the shared registry under its own name, that counts its runs.
private final class SignatureRoundTool: AgentTool, Sendable {
    let name = "test_signature_round_tool_\(UUID().uuidString.prefix(8))"
    private let count = Mutex(0)

    var runs: Int { count.withLock { $0 } }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        count.withLock { $0 += 1 }
        return "done"
    }

    /// Registers this tool after the default set, so the tool loop finds it.
    func register() async {
        await ToolRegistry.shared.ensureDefaultToolsRegistered()
        await ToolRegistry.shared.register(self)
    }
}

/// When an Anthropic model thinks before it calls a tool, the backend keeps the thinking block's
/// signature on the assistant message in `conversation_state.harmony_messages`
/// (`thinkingSignature`). The app sends that state back with the tool's result, and the backend
/// can send the thinking block to Anthropic again only if the signature came back: Anthropic
/// refuses a tool continuation whose assistant turn lost its thinking block. So the next round
/// must carry the signature exactly as the backend sent it, as the Thunderbird add-on does.
///
/// `.processGlobalState`: the tool loop's entry check reads the real AI setting, which other
/// suites write.
@Suite("A tool round keeps the assistant turn's thinking signature", .serialized, .processGlobalState)
struct ThinkingSignatureToolRoundTests {

    private static let primer = ":" + String(repeating: " ", count: 600) + "\n\n"

    /// The backend's stream with its `final` event.
    private static func stream(_ final: String) -> FakeHTTP.CannedResponse {
        .bytes(Data((primer + "event: final\ndata: " + final + "\n\n").utf8), contentType: "text/event-stream")
    }

    private static let answerText = "Here is the answer."
    private static let answer = stream(#"{"assistant":"Here is the answer."}"#)

    private static let signature = "SIG-thinking-abc-123"
    private static let thinking = "Checking the inbox first."

    /// A round asking for the client tool `name`, with the assistant turn the backend keeps in the
    /// conversation state: its thinking, the thinking's signature and the tool call.
    private static func toolRound(_ name: String) -> FakeHTTP.CannedResponse {
        let call = #"{"id":"call-1","function":{"name":""# + name + #"","arguments":"{}"}}"#
        let assistant = #"{"role":"assistant","content":"","thinking":""# + thinking
            + #"","thinkingSignature":""# + signature + #"","tool_calls":["# + call + "]}"
        return stream(
            #"{"tool_calls":["# + call + #"],"conversation_state":{"harmony_messages":["# + assistant
                + #"],"current_round":1}}"#
        )
    }

    private static let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

    enum Entry: String, CaseIterable, Sendable {
        case queued, direct
    }

    @Test("the round after a tool call sends the assistant turn back with its thinking and the thinking's signature",
          arguments: Entry.allCases)
    func nextRoundCarriesTheThinkingSignature(entry: Entry) async throws {
        let tool = SignatureRoundTool()
        await tool.register()
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let answered = SignatureRoundAnswered()
        http.register(path: "/completions/chat", method: "POST") { _ in
            answered.next() == 1 ? Self.toolRound(tool.name) : Self.answer
        }
        let client = BackendClient(llmSession: http.session, isAIOff: { false })

        let response: CompletionsResponse
        switch entry {
        case .queued: response = try await client.sendCompletionsWithTools(Self.request)
        case .direct: response = try await client.sendCompletionsWithToolsDirect(Self.request)
        }

        #expect(response.assistant == Self.answerText)
        #expect(tool.runs == 1)
        let calls = http.recordedCalls()
        #expect(calls.count == 2, "one tool round, then the answer")
        guard calls.count == 2 else { return }

        let body = try #require(calls[1].body)
        let parsed = try JSONSerialization.jsonObject(with: body)
        let json = try #require(parsed as? [String: Any])
        let state = try #require(json["conversation_state"] as? [String: Any])
        let messages = try #require(state["harmony_messages"] as? [[String: Any]])
        let assistantTurns = messages.filter { $0["role"] as? String == "assistant" }
        #expect(assistantTurns.count == 1)
        guard assistantTurns.count == 1 else { return }
        let assistantTurn = assistantTurns[0]
        #expect(assistantTurn["thinkingSignature"] as? String == Self.signature,
                "the assistant turn goes back with the signature the backend sent")
        #expect(assistantTurn["thinking"] as? String == Self.thinking)
        let toolResults = messages.filter { $0["role"] as? String == "tool" }
        #expect(toolResults.count == 1)
        guard toolResults.count == 1 else { return }
        #expect(toolResults[0]["tool_call_id"] as? String == "call-1", "the round still carries the tool's result")
    }

    @Test("a message with no thinking signature is sent with no thinkingSignature key, as before")
    func noSignatureEncodesNoKey() throws {
        let message = HarmonyMessage(role: "assistant", content: "Hi", thinking: "thought", tool_calls: nil, tool_call_id: nil)
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(json.contains("thinkingSignature") == false)
    }
}
