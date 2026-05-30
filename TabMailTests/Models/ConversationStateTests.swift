/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CompletionsSSEEvent Types")
struct CompletionsSSEEventTests {

    @Test("ToolStatusEvent decodes from JSON")
    func toolStatusDecodes() throws {
        let json = """
        {"tool_name": "email_search", "call_id": "call_123"}
        """
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: Data(json.utf8))
        #expect(event.tool_name == "email_search")
        #expect(event.call_id == "call_123")
    }

    @Test("CompletionsFinalEvent decodes with all fields")
    func finalEventDecodes() throws {
        let json = """
        {
            "assistant": "Here is the response",
            "tool_calls": [{"id": "c1", "function": {"name": "search", "arguments": "{\\"q\\":\\"test\\"}"}}],
            "token_usage": {"input_tokens": 100, "output_tokens": 50, "total_tokens": 150},
            "thinking": "Let me think..."
        }
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: Data(json.utf8))
        #expect(event.assistant == "Here is the response")
        #expect(event.thinking == "Let me think...")
        #expect(event.tool_calls?.count == 1)
        #expect(event.token_usage?.input_tokens == 100)
    }

    @Test("CompletionsFinalEvent decodes with minimal fields")
    func finalEventMinimal() throws {
        let json = """
        {"assistant": "Hello"}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: Data(json.utf8))
        #expect(event.assistant == "Hello")
        #expect(event.tool_calls == nil)
        #expect(event.token_usage == nil)
        #expect(event.thinking == nil)
    }

    @Test("HarmonyMessage decodes")
    func harmonyMessageDecodes() throws {
        let json = """
        {
            "role": "assistant",
            "content": "Response text",
            "tool_call_id": "call_1",
            "tool_calls": []
        }
        """
        let msg = try JSONDecoder().decode(HarmonyMessage.self, from: Data(json.utf8))
        #expect(msg.role == "assistant")
        #expect(msg.content == "Response text")
        #expect(msg.tool_call_id == "call_1")
    }

    @Test("TokenUsage stores token counts")
    func tokenUsage() throws {
        let json = """
        {"input_tokens": 500, "output_tokens": 200, "total_tokens": 700}
        """
        let usage = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(usage.input_tokens == 500)
        #expect(usage.output_tokens == 200)
    }

    @Test("ToolResult encodes correctly")
    func toolResultEncodes() throws {
        let result = ToolResult(call_id: "call_1", output: "Result data", ok: true)
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["call_id"] as? String == "call_1")
        #expect(json["output"] as? String == "Result data")
        #expect(json["ok"] as? Bool == true)
    }
}

@Suite("ConversationState")
struct ConversationStateTests {

    @Test("ConversationState initializes from JSON")
    func initFromJSON() throws {
        let json = """
        {
            "harmony_messages": [],
            "current_round": 0
        }
        """
        let state = try JSONDecoder().decode(ConversationState.self, from: Data(json.utf8))
        #expect(state.harmony_messages.isEmpty)
        #expect(state.current_round == 0)
    }

    @Test("ConversationState round-trips through Codable")
    func codableRoundTrip() throws {
        let json = """
        {
            "harmony_messages": [{"role": "user", "content": "hello"}],
            "current_round": 2,
            "ts_ms": 1234567890.0
        }
        """
        let state = try JSONDecoder().decode(ConversationState.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: encoded)
        #expect(decoded.current_round == 2)
        #expect(decoded.harmony_messages.count == 1)
    }

    @Test("ConversationState round-trips with thinking on HarmonyMessage")
    func codableRoundTripWithThinking() throws {
        let msg = HarmonyMessage(role: "assistant", content: "Hi", thinking: "thought", tool_calls: nil, tool_call_id: nil)
        let state = ConversationState(harmony_messages: [msg], current_round: 0)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: data)
        #expect(decoded.harmony_messages.count == 1)
        #expect(decoded.harmony_messages[0].thinking == "thought")
        #expect(decoded.harmony_messages[0].content == "Hi")
    }

    @Test("ConversationState decodes with thinking in JSON")
    func decodesThinkingFromJSON() throws {
        let json = """
        {
            "harmony_messages": [{"role": "assistant", "content": "Hi", "thinking": "reasoning here"}],
            "current_round": 1
        }
        """
        let state = try JSONDecoder().decode(ConversationState.self, from: Data(json.utf8))
        #expect(state.harmony_messages[0].thinking == "reasoning here")
    }

    @Test("ConversationState decodes without thinking in JSON (backward compat)")
    func decodesWithoutThinkingFromJSON() throws {
        let json = """
        {
            "harmony_messages": [{"role": "assistant", "content": "Hi"}],
            "current_round": 1
        }
        """
        let state = try JSONDecoder().decode(ConversationState.self, from: Data(json.utf8))
        #expect(state.harmony_messages[0].thinking == nil)
    }
}
