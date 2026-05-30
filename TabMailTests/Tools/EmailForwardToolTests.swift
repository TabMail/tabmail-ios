/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailForwardTool")
struct EmailForwardToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db, translator)
    }

    @Test("Tool name is email_forward")
    func toolName() throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        #expect(tool.name == "email_forward")
    }

    @Test("Missing unique_id returns error")
    func missingUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Non-numeric string unique_id returns error")
    func nonNumericStringUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("abc")])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Boolean unique_id returns error")
    func boolUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .bool(true)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("missing or invalid unique_id"))
    }

    @Test("Unknown numeric ID returns not found for given unique_id")
    func unknownNumericId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(999)])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("Email not found for unique_id 999"))
    }

    @Test("ID in translator but message not in DB returns email not found")
    func idInTranslatorButNotInDb() async throws {
        let (ctx, _, translator) = try makeContext()
        await translator.seed("nonexistent_msg", as: 50)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(50),
            "request": .string("Forward this please")
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("no longer exists"))
    }

    @Test("Missing both request and body returns error")
    func missingRequestAndBody() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg1", subject: "Fwd Test")
        await translator.seed(header.id, as: 10)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(10),
            "to": .array([.string("bob@test.com")])
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("request parameter is required"))
    }

    @Test("unique_id as string '42' parsed correctly")
    func uniqueIdAsString() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        // String "42" should parse to numeric 42, then fail at translator lookup (not at parse)
        let result = try await tool.execute(arguments: ["unique_id": .string("42")])
        #expect(!result.contains("missing or invalid unique_id"))
        #expect(result.contains("Email not found for unique_id 42"))
    }

    @Test("unique_id as double 42.0 parsed correctly")
    func uniqueIdAsDouble() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailForwardTool(context: ctx)
        // Double 42.0 should parse to numeric 42, then fail at translator lookup (not at parse)
        let result = try await tool.execute(arguments: ["unique_id": .double(42.0)])
        #expect(!result.contains("missing or invalid unique_id"))
        #expect(result.contains("Email not found for unique_id 42"))
    }

    @Test("Empty string request with no body returns error")
    func emptyRequestNoBody() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg2", subject: "Empty Req")
        await translator.seed(header.id, as: 20)

        let tool = EmailForwardTool(context: ctx)
        let result = try await tool.execute(arguments: [
            "unique_id": .int(20),
            "request": .string("")
        ])
        #expect(result.hasPrefix("Failed: "))
        #expect(result.contains("request parameter is required"))
    }
}
