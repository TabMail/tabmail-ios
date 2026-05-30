/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ToolRegistry Codable Types")
struct ToolRegistryTypesTests {

    // MARK: - CompletionsToolCall

    @Test("CompletionsToolCall decodes id and function")
    func decodeToolCall() throws {
        let json = """
        {"id": "call_123", "function": {"name": "email_search", "arguments": "{\\"query\\": \\"test\\"}"}}
        """.data(using: .utf8)!
        let call = try JSONDecoder().decode(CompletionsToolCall.self, from: json)
        #expect(call.id == "call_123")
        #expect(call.function.name == "email_search")
        #expect(call.function.arguments.contains("query"))
    }

    @Test("CompletionsToolCall round-trips through encode/decode")
    func roundTripToolCall() throws {
        let original = CompletionsToolCall(
            id: "call_abc",
            function: CompletionsToolCall.ToolFunction(name: "inbox_read", arguments: "{}")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompletionsToolCall.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.function.name == original.function.name)
        #expect(decoded.function.arguments == original.function.arguments)
    }

    @Test("CompletionsToolCall omits extra_content when absent (non-Gemini byte parity)")
    func toolCallNoExtraContentOmitted() throws {
        let call = CompletionsToolCall(
            id: "call_1",
            function: CompletionsToolCall.ToolFunction(name: "inbox_read", arguments: "{}")
        )
        let json = String(data: try JSONEncoder().encode(call), encoding: .utf8)!
        #expect(json.contains("extra_content") == false)
    }

    @Test("CompletionsToolCall preserves Gemini extra_content (thought_signature) across decode→encode")
    func toolCallPreservesExtraContent() throws {
        // The exact envelope Gemini 3 returns; iOS must round-trip it verbatim or
        // the next turn 400s ("Function call is missing a thought_signature").
        let json = """
        {"id":"call_g","function":{"name":"email_read","arguments":"{\\"unique_id\\":\\"2124\\"}"},"extra_content":{"google":{"thought_signature":"SIG-abc-123"}}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CompletionsToolCall.self, from: json)

        // Decoded into the opaque tree without interpretation.
        guard case .dictionary(let outer)? = decoded.extra_content,
              case .dictionary(let google)? = outer["google"],
              case .string(let sig)? = google["thought_signature"] else {
            Issue.record("extra_content did not decode into the expected google.thought_signature shape")
            return
        }
        #expect(sig == "SIG-abc-123")

        // Re-encode and confirm the signature survives byte-wise into the next request.
        let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        #expect(reencoded.contains("\"thought_signature\":\"SIG-abc-123\""))
    }

    @Test("ConversationState round-trips an assistant tool_call's extra_content (client multi-turn)")
    func conversationStatePreservesExtraContent() throws {
        // Mirrors what the backend puts in conversation_state.harmony_messages on
        // round 1 and what iOS must send back on round 2.
        let json = """
        {
            "harmony_messages": [
                {"role":"assistant","content":"","tool_calls":[
                    {"id":"call_g","function":{"name":"email_read","arguments":"{}"},
                     "extra_content":{"google":{"thought_signature":"SIG-xyz-789"}}}
                ],"tool_call_id":null}
            ],
            "current_round": 1
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(ConversationState.self, from: json)
        let reencoded = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        #expect(reencoded.contains("\"thought_signature\":\"SIG-xyz-789\""))
    }

    // MARK: - ToolFunction

    @Test("ToolFunction decodes name and arguments string")
    func decodeToolFunction() throws {
        let json = """
        {"name": "email_delete", "arguments": "{\\"unique_ids\\": [1, 2]}"}
        """.data(using: .utf8)!
        let f = try JSONDecoder().decode(CompletionsToolCall.ToolFunction.self, from: json)
        #expect(f.name == "email_delete")
        #expect(f.arguments.contains("unique_ids"))
    }

    // MARK: - ConversationState

    @Test("ConversationState decodes with all fields")
    func decodeConversationStateFull() throws {
        let json = """
        {
            "harmony_messages": [
                {"role": "user", "content": "hello", "tool_calls": null, "tool_call_id": null}
            ],
            "tool_traces": [
                {"name": "inbox_read", "call_id": "c1", "execution_id": "e1", "result": "ok", "success": true, "server_side": false}
            ],
            "current_round": 2,
            "ts_ms": 1710513000000,
            "malformed_retry_count": 1,
            "max_rounds_malformed_retry_count": 0
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(ConversationState.self, from: json)
        #expect(state.harmony_messages.count == 1)
        #expect(state.harmony_messages[0].role == "user")
        #expect(state.tool_traces?.count == 1)
        #expect(state.current_round == 2)
        #expect(state.ts_ms == 1710513000000)
        #expect(state.malformed_retry_count == 1)
        #expect(state.max_rounds_malformed_retry_count == 0)
    }

    @Test("ConversationState decodes with minimal fields")
    func decodeConversationStateMinimal() throws {
        let json = """
        {"harmony_messages": [], "current_round": 0}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(ConversationState.self, from: json)
        #expect(state.harmony_messages.isEmpty)
        #expect(state.current_round == 0)
        #expect(state.tool_traces == nil)
        #expect(state.ts_ms == nil)
    }

    @Test("ConversationState round-trips through encode/decode")
    func roundTripConversationState() throws {
        var original = ConversationState(
            harmony_messages: [HarmonyMessage(role: "assistant", content: "Hi", thinking: nil, tool_calls: nil, tool_call_id: nil)],
            current_round: 1
        )
        original.ts_ms = 123456.0
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: data)
        #expect(decoded.current_round == 1)
        #expect(decoded.ts_ms == 123456.0)
        #expect(decoded.harmony_messages[0].content == "Hi")
    }

    // MARK: - HarmonyMessage

    @Test("HarmonyMessage decodes user message")
    func decodeHarmonyMessageUser() throws {
        let json = """
        {"role": "user", "content": "Search my inbox", "tool_calls": null, "tool_call_id": null}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: json)
        #expect(msg.role == "user")
        #expect(msg.content == "Search my inbox")
        #expect(msg.tool_calls == nil)
        #expect(msg.tool_call_id == nil)
    }

    @Test("HarmonyMessage decodes tool message with call_id")
    func decodeHarmonyMessageTool() throws {
        let json = """
        {"role": "tool", "content": "{\\"results\\": []}", "tool_calls": null, "tool_call_id": "call_xyz"}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: json)
        #expect(msg.role == "tool")
        #expect(msg.tool_call_id == "call_xyz")
    }

    @Test("HarmonyMessage decodes assistant with tool_calls")
    func decodeHarmonyMessageAssistantTools() throws {
        let json = """
        {
            "role": "assistant",
            "content": null,
            "tool_calls": [{"id": "c1", "function": {"name": "email_search", "arguments": "{}"}}],
            "tool_call_id": null
        }
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: json)
        #expect(msg.role == "assistant")
        #expect(msg.content == nil)
        #expect(msg.tool_calls?.count == 1)
        #expect(msg.tool_calls?[0].function.name == "email_search")
    }

    // MARK: - HarmonyMessage thinking

    @Test("HarmonyMessage decodes without thinking (backward compat)")
    func decodeHarmonyMessageWithoutThinking() throws {
        let json = """
        {"role":"assistant","content":"Hi"}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: json)
        #expect(msg.role == "assistant")
        #expect(msg.content == "Hi")
        #expect(msg.thinking == nil)
    }

    @Test("HarmonyMessage decodes with thinking")
    func decodeHarmonyMessageWithThinking() throws {
        let json = """
        {"role":"assistant","content":"Hi","thinking":"I thought..."}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: json)
        #expect(msg.thinking == "I thought...")
        #expect(msg.content == "Hi")
    }

    @Test("HarmonyMessage round-trips thinking through encode/decode")
    func roundTripHarmonyMessageThinking() throws {
        let original = HarmonyMessage(role: "assistant", content: "Hi", thinking: "deep thought", tool_calls: nil, tool_call_id: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HarmonyMessage.self, from: data)
        #expect(decoded.thinking == "deep thought")
        #expect(decoded.content == "Hi")
    }

    // MARK: - ToolTrace

    @Test("ToolTrace decodes all fields")
    func decodeToolTrace() throws {
        let json = """
        {"name": "inbox_read", "call_id": "c1", "execution_id": "e1", "result": "5 emails", "success": true, "server_side": true}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(ToolTrace.self, from: json)
        #expect(t.name == "inbox_read")
        #expect(t.call_id == "c1")
        #expect(t.execution_id == "e1")
        #expect(t.result == "5 emails")
        #expect(t.success == true)
        #expect(t.server_side == true)
    }

    @Test("ToolTrace decodes with null optional fields")
    func decodeToolTraceMinimal() throws {
        let json = """
        {"name": "kb_read", "call_id": "c2", "execution_id": null, "result": null, "success": false, "server_side": null}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(ToolTrace.self, from: json)
        #expect(t.execution_id == nil)
        #expect(t.result == nil)
        #expect(t.success == false)
        #expect(t.server_side == nil)
    }

    // MARK: - ToolResult

    @Test("ToolResult encodes and decodes correctly")
    func roundTripToolResult() throws {
        let original = ToolResult(call_id: "c1", output: "{\"count\": 3}", ok: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.call_id == "c1")
        #expect(decoded.output == "{\"count\": 3}")
        #expect(decoded.ok == true)
    }

    @Test("ToolResult with failure")
    func decodeToolResultFailure() throws {
        let json = """
        {"call_id": "c2", "output": "Error: timeout", "ok": false}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ToolResult.self, from: json)
        #expect(r.ok == false)
        #expect(r.output == "Error: timeout")
    }

    // MARK: - CompletionsFinalEvent

    @Test("CompletionsFinalEvent decodes assistant response")
    func decodeFinalEventAssistant() throws {
        let json = """
        {"assistant": "Here are your emails.", "token_usage": {"input_tokens": 100, "output_tokens": 50, "total_tokens": 150}, "error": null, "tool_calls": null, "conversation_state": null, "thinking": null}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json)
        #expect(event.assistant == "Here are your emails.")
        #expect(event.token_usage?.total_tokens == 150)
        #expect(event.error == nil)
        #expect(event.tool_calls == nil)
    }

    @Test("CompletionsFinalEvent decodes tool_calls for client execution")
    func decodeFinalEventToolCalls() throws {
        let json = """
        {
            "assistant": null,
            "token_usage": null,
            "error": null,
            "tool_calls": [{"id": "tc1", "function": {"name": "inbox_read", "arguments": "{}"}}],
            "conversation_state": {"harmony_messages": [], "current_round": 1},
            "thinking": "I should read the inbox"
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json)
        #expect(event.assistant == nil)
        #expect(event.tool_calls?.count == 1)
        #expect(event.conversation_state?.current_round == 1)
        #expect(event.thinking == "I should read the inbox")
    }

    @Test("CompletionsFinalEvent decodes error")
    func decodeFinalEventError() throws {
        let json = """
        {"assistant": null, "token_usage": null, "error": "Rate limited", "tool_calls": null, "conversation_state": null, "thinking": null}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json)
        #expect(event.error == "Rate limited")
    }

    // MARK: - ToolStatusEvent

    @Test("ToolStatusEvent decodes started event")
    func decodeToolStatusStarted() throws {
        let json = """
        {"execution_id": "ex1", "call_id": "c1", "display_label": "Searching emails...", "tool_name": "email_search", "success": null, "elapsed_ms": null, "error": null, "result": null}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: json)
        #expect(event.execution_id == "ex1")
        #expect(event.tool_name == "email_search")
        #expect(event.display_label == "Searching emails...")
        #expect(event.success == nil)
    }

    @Test("ToolStatusEvent decodes completed event")
    func decodeToolStatusCompleted() throws {
        let json = """
        {"execution_id": "ex1", "call_id": "c1", "display_label": null, "tool_name": "email_search", "success": true, "elapsed_ms": 250, "error": null, "result": "5 results"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: json)
        #expect(event.success == true)
        #expect(event.elapsed_ms == 250)
        #expect(event.result == "5 results")
    }

    @Test("ToolStatusEvent decodes failed event")
    func decodeToolStatusFailed() throws {
        let json = """
        {"execution_id": "ex2", "call_id": "c2", "display_label": null, "tool_name": "kb_read", "success": false, "elapsed_ms": 100, "error": "Not found", "result": null}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: json)
        #expect(event.success == false)
        #expect(event.error == "Not found")
    }
}
