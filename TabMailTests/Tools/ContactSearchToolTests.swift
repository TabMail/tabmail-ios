/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ContactSearchTool Argument Validation")
struct ContactSearchToolTests {

    @Test("Tool name is contacts_search")
    func toolName() {
        let tool = ContactSearchTool()
        #expect(tool.name == "contacts_search")
    }

    @Test("Missing query returns error")
    func missingQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing query"))
    }

    @Test("Non-string query (int) returns error")
    func intQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .int(42)])
        #expect(result.contains("missing query"))
    }

    @Test("Non-string query (bool) returns error")
    func boolQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .bool(true)])
        #expect(result.contains("missing query"))
    }

    @Test("Non-string query (array) returns error")
    func arrayQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .array([.string("test")])])
        #expect(result.contains("missing query"))
    }

    @Test("Non-string query (dictionary) returns error")
    func dictQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .dictionary(["k": .string("v")])])
        #expect(result.contains("missing query"))
    }

    @Test("Empty string query returns error")
    func emptyQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .string("")])
        #expect(result.contains("missing query"))
    }

    @Test("Whitespace-only query returns error")
    func whitespaceQuery() async throws {
        let tool = ContactSearchTool()
        let result = try await tool.execute(arguments: ["query": .string("   ")])
        #expect(result.contains("missing query"))
    }
}
