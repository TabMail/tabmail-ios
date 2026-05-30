/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - KBAddTool

@Suite("KBAddTool Argument Validation")
struct KBAddToolTests {

    @Test("Tool name is kb_add")
    func toolName() {
        let tool = KBAddTool()
        #expect(tool.name == "kb_add")
    }

    @Test("Missing statement returns error")
    func missingStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (int) returns error")
    func intStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .int(42)])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (bool) returns error")
    func boolStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .bool(true)])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (array) returns error")
    func arrayStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .array([.string("a")])])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (dictionary) returns error")
    func dictStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .dictionary(["k": .string("v")])])
        #expect(result.contains("missing statement"))
    }

    @Test("Whitespace-only statement returns error after normalization")
    func whitespaceStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .string("   ")])
        #expect(result.contains("missing statement"))
    }

    @Test("Empty string statement returns error")
    func emptyStatement() async throws {
        let tool = KBAddTool()
        let result = try await tool.execute(arguments: ["statement": .string("")])
        #expect(result.contains("missing statement"))
    }
}

// MARK: - KBDelTool

@Suite("KBDelTool Argument Validation")
struct KBDelToolTests {

    @Test("Tool name is kb_del")
    func toolName() {
        let tool = KBDelTool()
        #expect(tool.name == "kb_del")
    }

    @Test("Missing statement returns error")
    func missingStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (int) returns error")
    func intStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .int(42)])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (bool) returns error")
    func boolStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .bool(false)])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (array) returns error")
    func arrayStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .array([])])
        #expect(result.contains("missing statement"))
    }

    @Test("Non-string statement (dictionary) returns error")
    func dictStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .dictionary([:])])
        #expect(result.contains("missing statement"))
    }

    @Test("Whitespace-only statement returns error after normalization")
    func whitespaceStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .string("   ")])
        #expect(result.contains("missing statement"))
    }

    @Test("Empty string statement returns error")
    func emptyStatement() async throws {
        let tool = KBDelTool()
        let result = try await tool.execute(arguments: ["statement": .string("")])
        #expect(result.contains("missing statement"))
    }
}
