/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailDeleteTool Argument Validation")
struct EmailDeleteToolTests {

    private func makeTool(
        db: DatabaseQueue? = nil,
        translator: MockChatIdTranslator? = nil
    ) throws -> EmailDeleteTool {
        let database = try db ?? TestDatabase.make()
        let mock = translator ?? MockChatIdTranslator()
        let ctx = ToolContext(db: database, translator: mock)
        return EmailDeleteTool(context: ctx)
    }

    // MARK: - Argument Parsing Errors

    @Test("Missing unique_ids returns error")
    func missingUniqueIds() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    @Test("Non-array unique_ids returns error")
    func nonArrayUniqueIds() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["unique_ids": .string("not an array")])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    @Test("Empty unique_ids array returns error")
    func emptyUniqueIds() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["unique_ids": .array([])])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    @Test("Integer unique_ids (not array) returns error")
    func integerUniqueIds() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["unique_ids": .int(42)])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    // MARK: - ID Resolution Errors

    @Test("Unresolvable numeric IDs returns not-found error")
    func unresolvableIds() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(10, realId: "acc1:INBOX:missing")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(10)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Unknown numeric ID (not in translator) returns not-found error")
    func unknownNumericId() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(999)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Multiple unknown IDs all fail — returns not-found error")
    func multipleUnknownIds() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(1, realId: "acc1:INBOX:gone1")
        await translator.seed(2, realId: "acc1:INBOX:gone2")
        await translator.seed(3, realId: "acc1:INBOX:gone3")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(1), .int(2), .int(3)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    // MARK: - Single unique_id convenience

    @Test("Single unique_id (int) with no DB match returns not-found error")
    func singleUniqueIdInt() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(5, realId: "acc1:INBOX:msg5")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_id": .int(5)
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Single unique_id (string) with no DB match returns not-found error")
    func singleUniqueIdString() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(8, realId: "acc1:INBOX:msg8")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_id": .string("8")
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    // MARK: - Double values in array

    @Test("Double values in unique_ids are truncated to int")
    func doubleValues() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(3, realId: "acc1:INBOX:msg3")
        let tool = try makeTool(db: db, translator: translator)

        // 3.7 should be truncated to 3
        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.double(3.7)])
        ])
        // Should resolve the ID but not find a message in the empty DB
        #expect(result.contains("none of the specified emails could be found"))
    }
}
