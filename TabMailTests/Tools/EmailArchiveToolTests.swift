/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailArchiveTool Argument Validation")
struct EmailArchiveToolTests {

    private func makeTool(
        db: DatabaseQueue? = nil,
        translator: MockChatIdTranslator? = nil
    ) throws -> EmailArchiveTool {
        let database = try db ?? TestDatabase.make()
        let mock = translator ?? MockChatIdTranslator()
        let ctx = ToolContext(db: database, translator: mock)
        return EmailArchiveTool(context: ctx)
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

    @Test("Boolean unique_ids returns error")
    func booleanUniqueIds() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: ["unique_ids": .bool(true)])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    // MARK: - ID Resolution Errors

    @Test("Unresolvable numeric IDs returns not-found error")
    func unresolvableIds() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        // Seed a numeric ID that maps to a realId NOT in the database
        await translator.seed(42, realId: "acc1:INBOX:nonexistent")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(42)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Unknown numeric ID (not in translator) returns not-found error")
    func unknownNumericId() async throws {
        let tool = try makeTool()
        // ID 999 has no mapping in the mock translator
        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(999)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Mixed valid and invalid IDs — all invalid returns not-found error")
    func allInvalidIds() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(1, realId: "acc1:INBOX:gone1")
        await translator.seed(2, realId: "acc1:INBOX:gone2")
        let tool = try makeTool(db: db, translator: translator)

        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.int(1), .int(2)])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }

    @Test("Array with non-numeric values are skipped, resulting in empty")
    func nonNumericArrayValues() async throws {
        let tool = try makeTool()
        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.bool(true), .dictionary([:])]),
        ])
        #expect(result.contains("missing or empty unique_ids array"))
    }

    @Test("String numeric IDs are parsed correctly")
    func stringNumericIds() async throws {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        await translator.seed(7, realId: "acc1:INBOX:msg7")
        let tool = try makeTool(db: db, translator: translator)

        // String "7" should parse to int 7, but no message in DB
        let result = try await tool.execute(arguments: [
            "unique_ids": .array([.string("7")])
        ])
        #expect(result.contains("none of the specified emails could be found"))
    }
}
