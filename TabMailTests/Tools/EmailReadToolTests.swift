/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("EmailReadTool")
struct EmailReadToolTests {

    private func makeContext() throws -> (ToolContext, DatabaseQueue, MockChatIdTranslator) {
        let db = try TestDatabase.make()
        let translator = MockChatIdTranslator()
        let ctx = ToolContext(db: db, translator: translator)
        return (ctx, db, translator)
    }

    @Test("Missing unique_id returns error")
    func missingUniqueId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("error"))
        #expect(result.contains("invalid or missing unique_id"))
    }

    @Test("Unknown numeric ID returns not found")
    func unknownNumericId() async throws {
        let (ctx, _, _) = try makeContext()
        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(999)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }

    @Test("Valid message returns full content")
    func validMessage() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", subject: "Test Subject",
            from: "Alice", fromAddress: "alice@test.com",
            to: "bob@test.com"
        )
        try TestDatabase.insertMessageBody(db, headerId: header.id, htmlContent: "<p>Hello world</p>")
        await translator.seed(header.id, as: 42)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(42)])
        #expect(result.contains("unique_id: 42"))
        #expect(result.contains("subject: Test Subject"))
        #expect(result.contains("Alice <alice@test.com>"))
        #expect(result.contains("to: bob@test.com"))
        #expect(result.contains("Hello world")) // HTML stripped to text
    }

    @Test("Falls back to snippet when no body")
    func fallbackToSnippet() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg2", subject: "No Body",
            snippet: "This is the snippet"
        )
        await translator.seed(header.id, as: 10)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(10)])
        #expect(result.contains("This is the snippet"))
    }

    @Test("unique_id as string")
    func uniqueIdAsString() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg3", subject: "String ID")
        await translator.seed(header.id, as: 5)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .string("5")])
        #expect(result.contains("subject: String ID"))
    }

    @Test("unique_id as double")
    func uniqueIdAsDouble() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg4", subject: "Double ID")
        await translator.seed(header.id, as: 7)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .double(7.0)])
        #expect(result.contains("subject: Double ID"))
    }

    @Test("Message with no subject shows (No subject)")
    func noSubject() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg5", subject: "")
        await translator.seed(header.id, as: 1)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(1)])
        #expect(result.contains("subject: (No subject)"))
    }

    @Test("Output includes date, from, to, cc fields")
    func outputFields() async throws {
        let (ctx, db, translator) = try makeContext()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg6", subject: "Fields",
            from: "Sender", fromAddress: "s@t.com",
            to: "r@t.com"
        )
        await translator.seed(header.id, as: 3)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(3)])
        #expect(result.contains("date:"))
        #expect(result.contains("from:"))
        #expect(result.contains("to:"))
        #expect(result.contains("cc:"))
        #expect(result.contains("body:"))
        #expect(result.contains("has_attachments:"))
        #expect(result.contains("replied:"))
    }

    @Test("Deleted message returns not found")
    func deletedMessage() async throws {
        let (ctx, _, translator) = try makeContext()
        // Seed translator with ID but don't insert into DB
        await translator.seed("deleted_msg", as: 99)

        let tool = EmailReadTool(context: ctx)
        let result = try await tool.execute(arguments: ["unique_id": .int(99)])
        #expect(result.contains("error"))
        #expect(result.contains("message not found"))
    }
}
