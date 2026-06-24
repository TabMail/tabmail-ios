/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Tool that inspects arguments

private struct ArgumentCapturingTool: AgentTool {
    let name: String
    let capturedArgs: @Sendable ([String: JSONValue]) -> String

    func execute(arguments: [String: JSONValue]) async throws -> String {
        capturedArgs(arguments)
    }
}

@Suite("ToolRegistry Argument Passing")
struct ToolRegistryArgumentTests {

    @Test("Arguments are passed through to tool execution")
    func argumentsPassedThrough() async {
        let registry = ToolRegistry()
        let tool = ArgumentCapturingTool(name: "arg_tool") { args in
            if case .string(let q) = args["query"] {
                return "searched: \(q)"
            }
            return "no query"
        }
        await registry.register(tool)
        let result = await registry.execute(
            name: "arg_tool",
            arguments: ["query": .string("inbox emails")]
        )
        #expect(result.ok == true)
        #expect(result.output == "searched: inbox emails")
    }

    @Test("Empty arguments passed to tool")
    func emptyArguments() async {
        let registry = ToolRegistry()
        let tool = ArgumentCapturingTool(name: "no_args") { args in
            return "count: \(args.count)"
        }
        await registry.register(tool)
        let result = await registry.execute(name: "no_args", arguments: [:])
        #expect(result.ok == true)
        #expect(result.output == "count: 0")
    }

    @Test("Multiple argument types passed correctly")
    func multipleArgTypes() async {
        let registry = ToolRegistry()
        let tool = ArgumentCapturingTool(name: "multi") { args in
            var parts: [String] = []
            if case .string(let s) = args["name"] { parts.append("name=\(s)") }
            if case .int(let i) = args["count"] { parts.append("count=\(i)") }
            if case .bool(let b) = args["active"] { parts.append("active=\(b)") }
            return parts.joined(separator: ",")
        }
        await registry.register(tool)
        let result = await registry.execute(
            name: "multi",
            arguments: ["name": .string("test"), "count": .int(3), "active": .bool(true)]
        )
        #expect(result.ok == true)
        #expect(result.output.contains("name=test"))
        #expect(result.output.contains("count=3"))
        #expect(result.output.contains("active=true"))
    }

    @Test("registeredNames returns empty for fresh registry")
    func registeredNamesEmpty() async {
        let registry = ToolRegistry()
        let names = await registry.registeredNames()
        #expect(names.isEmpty)
    }

    @Test("registeredNames returns sorted names")
    func registeredNamesSorted() async {
        let registry = ToolRegistry()
        await registry.registerAll([
            ArgumentCapturingTool(name: "zebra") { _ in "" },
            ArgumentCapturingTool(name: "alpha") { _ in "" },
            ArgumentCapturingTool(name: "middle") { _ in "" },
        ])
        let names = await registry.registeredNames()
        #expect(names == ["alpha", "middle", "zebra"])
    }
}

@Suite("ToolRegistry Lazy Default Registration")
struct ToolRegistryLazyRegistrationTests {

    @Test("ensureDefaultToolsRegistered registers the full default tool set")
    func ensureRegistersDefaults() async {
        let registry = ToolRegistry()
        await registry.ensureDefaultToolsRegistered()
        let names = await registry.registeredNames()
        let expected = ToolRegistry.makeDefaultTools().map(\.name).sorted()
        #expect(!names.isEmpty)
        #expect(names == expected)
        // Spot-check tools the agent-chat / reply / compose paths rely on.
        #expect(names.contains("inbox_read"))
        #expect(names.contains("email_search"))
        #expect(names.contains("memory_search"))
    }

    @Test("ensureDefaultToolsRegistered is idempotent — second call is a no-op")
    func ensureIdempotent() async {
        let registry = ToolRegistry()
        await registry.ensureDefaultToolsRegistered()
        let first = await registry.registeredNames()
        await registry.ensureDefaultToolsRegistered()
        let second = await registry.registeredNames()
        #expect(first == second)
    }

    @Test("makeDefaultTools produces unique tool names")
    func defaultToolsUniqueNames() {
        let names = ToolRegistry.makeDefaultTools().map(\.name)
        #expect(names.count == Set(names).count)
    }
}

@Suite("ToolJSON Extended")
struct ToolJSONExtendedTests {

    @Test("Handles Int values")
    func handlesInts() {
        let result = ToolJSON.string(from: ["count": 42])
        #expect(result.contains("42"))
    }

    @Test("Handles Double values")
    func handlesDoubles() {
        let result = ToolJSON.string(from: ["price": 9.99])
        #expect(result.contains("9.99"))
    }

    @Test("Handles Int arrays")
    func handlesIntArrays() {
        let result = ToolJSON.string(from: ["ids": [1, 2, 3]])
        #expect(result.contains("1"))
        #expect(result.contains("3"))
    }

    @Test("Falls back to string description for unknown types")
    func fallbackToString() {
        let result = ToolJSON.string(from: ["date": Date(timeIntervalSince1970: 0)])
        // Should produce valid JSON with some string representation
        #expect(!result.isEmpty)
        #expect(result != "{}")
    }

    @Test("Produces valid JSON for mixed types")
    func mixedTypes() {
        let dict: [String: Any] = [
            "name": "test",
            "count": 5,
            "active": true,
            "tags": ["a", "b"],
        ]
        let result = ToolJSON.string(from: dict)
        // Verify it's valid JSON by parsing it back
        let data = result.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil)
        #expect(parsed?["name"] as? String == "test")
    }
}

@Suite("ToolExecutionResult")
struct ToolExecutionResultTests {

    @Test("Success result")
    func successResult() {
        let result = ToolExecutionResult(output: "done", ok: true)
        #expect(result.output == "done")
        #expect(result.ok == true)
    }

    @Test("Failure result")
    func failureResult() {
        let result = ToolExecutionResult(output: "Error: not found", ok: false)
        #expect(result.output == "Error: not found")
        #expect(result.ok == false)
    }
}

@Suite("ToolDeclinedError")
struct ToolDeclinedErrorTests {

    @Test("Carries output message")
    func carriesOutput() {
        let error = ToolDeclinedError(output: "User said no")
        #expect(error.output == "User said no")
    }

    @Test("Conforms to Error protocol")
    func conformsToError() {
        let error: Error = ToolDeclinedError(output: "declined")
        #expect(error is ToolDeclinedError)
    }
}
