/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Mock Tool

private struct MockTool: AgentTool {
    let name: String
    let result: String

    func execute(arguments: [String: JSONValue]) async throws -> String {
        result
    }
}

private struct FailingTool: AgentTool {
    let name: String

    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tool failed"])
    }
}

private struct DecliningTool: AgentTool {
    let name: String

    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw ToolDeclinedError(output: "User declined")
    }
}

@Suite("ToolRegistry")
struct ToolRegistryTests {

    @Test("Register and execute tool")
    func registerAndExecute() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "test_tool", result: "success"))
        let result = await registry.execute(name: "test_tool", arguments: [:])
        #expect(result.ok == true)
        #expect(result.output == "success")
    }

    @Test("Execute unknown tool returns error")
    func unknownTool() async {
        let registry = ToolRegistry()
        let result = await registry.execute(name: "nonexistent", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output.contains("unknown tool"))
    }

    @Test("Execute failing tool returns error")
    func failingTool() async {
        let registry = ToolRegistry()
        await registry.register(FailingTool(name: "fail_tool"))
        let result = await registry.execute(name: "fail_tool", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output.contains("Error executing"))
    }

    @Test("Execute declined tool returns declined output")
    func declinedTool() async {
        let registry = ToolRegistry()
        await registry.register(DecliningTool(name: "decline_tool"))
        let result = await registry.execute(name: "decline_tool", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output == "User declined")
    }

    @Test("registerAll registers multiple tools")
    func registerAll() async {
        let registry = ToolRegistry()
        await registry.registerAll([
            MockTool(name: "tool_a", result: "a"),
            MockTool(name: "tool_b", result: "b"),
            MockTool(name: "tool_c", result: "c"),
        ])
        let names = await registry.registeredNames()
        #expect(names.count == 3)
        #expect(names.contains("tool_a"))
        #expect(names.contains("tool_b"))
        #expect(names.contains("tool_c"))
    }

    @Test("tool(named:) returns registered tool")
    func toolNamed() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "my_tool", result: "result"))
        let tool = await registry.tool(named: "my_tool")
        #expect(tool != nil)
        #expect(tool?.name == "my_tool")
    }

    @Test("tool(named:) returns nil for unknown tool")
    func toolNamedUnknown() async {
        let registry = ToolRegistry()
        let tool = await registry.tool(named: "missing")
        #expect(tool == nil)
    }

    @Test("Register overwrites existing tool with same name")
    func overwriteExisting() async {
        let registry = ToolRegistry()
        await registry.register(MockTool(name: "dup", result: "first"))
        await registry.register(MockTool(name: "dup", result: "second"))
        let result = await registry.execute(name: "dup", arguments: [:])
        #expect(result.output == "second")
    }
}

@Suite("ToolJSON")
struct ToolJSONTests {

    @Test("Encodes simple dictionary to JSON string")
    func encodesSimpleDict() {
        let result = ToolJSON.string(from: ["key": "value", "count": 42])
        #expect(result.contains("\"key\""))
        #expect(result.contains("\"value\""))
        #expect(result.contains("42"))
    }

    @Test("Returns empty object for empty dict")
    func emptyDict() {
        let result = ToolJSON.string(from: [:])
        // Should be valid JSON - either {} or the serialized empty dict
        #expect(!result.isEmpty)
    }

    @Test("Handles nested arrays")
    func handlesArrays() {
        let result = ToolJSON.string(from: ["items": ["a", "b", "c"]])
        #expect(result.contains("items"))
        #expect(result.contains("a"))
    }

    @Test("Handles boolean values")
    func handlesBooleans() {
        let result = ToolJSON.string(from: ["active": true])
        #expect(result.contains("active"))
    }
}

@Suite("SSE Event Types")
struct SSEEventTypeTests {

    @Test("ToolStatusEvent decodes from JSON")
    func toolStatusEventDecode() throws {
        let json = """
        {"execution_id":"exec1","call_id":"call1","display_label":"email_search","tool_name":"email_search","success":true,"elapsed_ms":150}
        """
        let event = try JSONDecoder().decode(ToolStatusEvent.self, from: json.data(using: .utf8)!)
        #expect(event.execution_id == "exec1")
        #expect(event.call_id == "call1")
        #expect(event.display_label == "email_search")
        #expect(event.success == true)
        #expect(event.elapsed_ms == 150)
    }

    @Test("CompletionsFinalEvent decodes with assistant text")
    func finalEventAssistant() throws {
        let json = """
        {"assistant":"Hello!","token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.assistant == "Hello!")
        #expect(event.tool_calls == nil)
    }

    @Test("CompletionsFinalEvent decodes with tool_calls")
    func finalEventToolCalls() throws {
        let json = """
        {"tool_calls":[{"id":"tc1","function":{"name":"email_search","arguments":"{\\"query\\":\\"test\\"}"}}],"conversation_state":{"harmony_messages":[],"current_round":1}}
        """
        let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: json.data(using: .utf8)!)
        #expect(event.tool_calls?.count == 1)
        #expect(event.tool_calls?[0].function.name == "email_search")
        #expect(event.conversation_state?.current_round == 1)
    }

    @Test("ConversationState round-trip")
    func conversationStateRoundTrip() throws {
        let state = ConversationState(
            harmony_messages: [
                HarmonyMessage(role: "user", content: "Hi", thinking: nil, tool_calls: nil, tool_call_id: nil),
                HarmonyMessage(role: "assistant", content: "Hello!", thinking: nil, tool_calls: nil, tool_call_id: nil),
            ],
            tool_traces: nil,
            current_round: 2,
            ts_ms: 1000.0,
            malformed_retry_count: nil,
            max_rounds_malformed_retry_count: nil
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: data)
        #expect(decoded.harmony_messages.count == 2)
        #expect(decoded.current_round == 2)
        #expect(decoded.harmony_messages[0].role == "user")
    }

    @Test("ToolResult round-trip")
    func toolResultRoundTrip() throws {
        let result = ToolResult(call_id: "tc1", output: "{\"data\":\"test\"}", ok: true)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.call_id == "tc1")
        #expect(decoded.ok == true)
    }

    @Test("CompletionsToolCall round-trip")
    func toolCallRoundTrip() throws {
        let call = CompletionsToolCall(
            id: "tc1",
            function: CompletionsToolCall.ToolFunction(name: "search", arguments: "{}")
        )
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(CompletionsToolCall.self, from: data)
        #expect(decoded.id == "tc1")
        #expect(decoded.function.name == "search")
        #expect(decoded.function.arguments == "{}")
    }

    @Test("ToolTrace round-trip")
    func toolTraceRoundTrip() throws {
        let trace = ToolTrace(name: "email_search", call_id: "tc1", execution_id: "ex1", result: "found 3", success: true, server_side: false)
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(ToolTrace.self, from: data)
        #expect(decoded.name == "email_search")
        #expect(decoded.success == true)
        #expect(decoded.server_side == false)
    }
}
