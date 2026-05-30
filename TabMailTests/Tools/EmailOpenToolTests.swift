/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailOpenTool")
struct EmailOpenToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db, translator)
    }

    @Test("Tool name is email_open")
    func toolName() throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailOpenTool(context: ctx)
        #expect(tool.name == "email_open")
    }

    @Test("Missing unique_id returns error")
    func missingUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("error"))
        #expect(result.contains("invalid or missing unique_id"))
    }

    @Test("Non-numeric string unique_id returns error")
    func nonNumericStringUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("abc")])
        #expect(result.contains("error"))
        #expect(result.contains("invalid or missing unique_id"))
    }

    @Test("Boolean unique_id returns error")
    func booleanUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .bool(true)])
        #expect(result.contains("error"))
        #expect(result.contains("invalid or missing unique_id"))
    }

    @Test("Unknown numeric ID not in translator returns error")
    func unknownNumericId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(999)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }

    @Test("ID in translator but message not in DB returns error")
    func idInTranslatorButNotInDb() async throws {
        let (ctx, _, translator) = try makeContext()
        await translator.seed("nonexistent_msg", as: 50)

        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(50)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }

    @Test("unique_id as string '42' is parsed correctly")
    func uniqueIdAsString() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg_str", subject: "String ID Open")
        await translator.seed(header.id, as: 42)

        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("42")])
        #expect(result.contains("success"))
        #expect(result.contains("String ID Open"))
    }

    @Test("unique_id as double 42.0 is parsed correctly")
    func uniqueIdAsDouble() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg_dbl", subject: "Double ID Open")
        await translator.seed(header.id, as: 42)

        let tool = EmailOpenTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .double(42.0)])
        #expect(result.contains("success"))
        #expect(result.contains("Double ID Open"))
    }
}
