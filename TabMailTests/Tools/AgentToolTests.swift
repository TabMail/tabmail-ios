/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Mock Tools for Testing

private struct EchoTool: AgentTool, Sendable {
    let name = "echo"
    func execute(arguments: [String: JSONValue]) async throws -> String {
        if case .string(let msg) = arguments["message"] {
            return "Echo: \(msg)"
        }
        return "Echo: (no message)"
    }
}

private struct FailingTool: AgentTool, Sendable {
    let name = "failing"
    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tool failed"])
    }
}

private struct DecliningTool: AgentTool, Sendable {
    let name = "declining"
    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw ToolDeclinedError(output: "User declined the action")
    }
}

@Suite("ToolRegistry Core Operations")
struct ToolRegistryCoreTests {

    @Test("Register and execute tool")
    func registerAndExecute() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let result = await registry.execute(name: "echo", arguments: ["message": .string("hello")])
        #expect(result.ok == true)
        #expect(result.output == "Echo: hello")
    }

    @Test("Unknown tool returns error")
    func unknownTool() async {
        let registry = ToolRegistry()
        let result = await registry.execute(name: "nonexistent", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output.contains("unknown tool"))
    }

    @Test("Failing tool returns error with ok=false")
    func failingTool() async {
        let registry = ToolRegistry()
        await registry.register(FailingTool())
        let result = await registry.execute(name: "failing", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output.contains("Error executing"))
    }

    @Test("Declined tool returns structured output")
    func declinedTool() async {
        let registry = ToolRegistry()
        await registry.register(DecliningTool())
        let result = await registry.execute(name: "declining", arguments: [:])
        #expect(result.ok == false)
        #expect(result.output == "User declined the action")
    }

    @Test("registerAll registers multiple tools")
    func registerAll() async {
        let registry = ToolRegistry()
        await registry.registerAll([EchoTool(), FailingTool(), DecliningTool()])
        let names = await registry.registeredNames()
        #expect(names.count == 3)
        #expect(names.contains("echo"))
        #expect(names.contains("failing"))
        #expect(names.contains("declining"))
    }

    @Test("tool(named:) returns registered tool")
    func toolNamed() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let tool = await registry.tool(named: "echo")
        #expect(tool != nil)
        #expect(tool?.name == "echo")
    }

    @Test("tool(named:) returns nil for unregistered")
    func toolNamedNil() async {
        let registry = ToolRegistry()
        let tool = await registry.tool(named: "missing")
        #expect(tool == nil)
    }

    @Test("Overwrite existing tool")
    func overwriteTool() async {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        await registry.register(EchoTool()) // overwrite
        let names = await registry.registeredNames()
        #expect(names.count == 1)
    }
}

@Suite("ToolJSON Encoding")
struct ToolJSONEncodingTests {

    @Test("ToolJSON.string encodes dictionary")
    func encodesDictionary() {
        let dict: [String: Any] = [
            "name": "Alice",
            "age": 30,
            "active": true,
        ]
        let json = ToolJSON.string(from: dict)
        #expect(json.contains("Alice"))
        #expect(json.contains("30"))
    }

    @Test("ToolJSON.string returns {} for empty dict")
    func emptyDict() {
        let json = ToolJSON.string(from: [:])
        #expect(json == "{}")
    }

    @Test("ToolJSON.string handles arrays")
    func handlesArrays() {
        let dict: [String: Any] = [
            "tags": ["a", "b", "c"]
        ]
        let json = ToolJSON.string(from: dict)
        #expect(json.contains("a"))
        #expect(json.contains("b"))
    }
}

@Suite("ToolExecutionResult & ToolDeclinedError")
struct ToolResultTypeTests {

    @Test("ToolExecutionResult stores output and ok")
    func resultFields() {
        let result = ToolExecutionResult(output: "success data", ok: true)
        #expect(result.output == "success data")
        #expect(result.ok == true)
    }

    @Test("ToolDeclinedError is an Error")
    func declinedIsError() {
        let err = ToolDeclinedError(output: "User said no")
        #expect(err.output == "User said no")
        // Verify it's an Error type
        let _: any Error = err
    }
}
