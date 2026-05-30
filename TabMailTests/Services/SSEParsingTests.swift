/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SSE Parsing")
struct SSEParsingTests {

    // Test BackendClient's extractSSEFinalData via CompletionsFinalEvent decoding

    @Test("CompletionsFinalEvent decodes thinking field")
    func decodesThinking() throws {
        let json = """
        {"assistant":"Result","thinking":"Let me think about this...","token_usage":null}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.thinking == "Let me think about this...")
        #expect(event.assistant == "Result")
    }

    @Test("CompletionsFinalEvent with all nil optional fields")
    func allNilOptionalFields() throws {
        let json = """
        {}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.assistant == nil)
        #expect(event.token_usage == nil)
        #expect(event.error == nil)
        #expect(event.tool_calls == nil)
        #expect(event.conversation_state == nil)
        #expect(event.thinking == nil)
    }

    @Test("CompletionsFinalEvent with error string")
    func withError() throws {
        let json = """
        {"error":"Internal server error","assistant":null}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.error == "Internal server error")
        #expect(event.assistant == nil)
    }

    @Test("ToolStatusEvent with minimal fields")
    func toolStatusMinimal() throws {
        let json = """
        {"tool_name":"email_search"}
        """
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: json.data(using: .utf8)!)
        #expect(event.tool_name == "email_search")
        #expect(event.success == nil)
        #expect(event.elapsed_ms == nil)
    }

    @Test("HarmonyMessage with tool_call_id")
    func harmonyMessageWithToolCallId() throws {
        let msg = HarmonyMessage(role: "tool", content: "{\"results\": []}", thinking: nil, tool_calls: nil, tool_call_id: "tc_123")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(HarmonyMessage.self, from: data)
        #expect(decoded.role == "tool")
        #expect(decoded.tool_call_id == "tc_123")
    }

    @Test("HarmonyMessage with tool_calls")
    func harmonyMessageWithToolCalls() throws {
        let toolCall = CompletionsToolCall(
            id: "tc_1",
            function: CompletionsToolCall.ToolFunction(name: "search", arguments: "{}")
        )
        let msg = HarmonyMessage(role: "assistant", content: nil, thinking: nil, tool_calls: [toolCall], tool_call_id: nil)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(HarmonyMessage.self, from: data)
        #expect(decoded.tool_calls?.count == 1)
        #expect(decoded.content == nil)
    }
}
