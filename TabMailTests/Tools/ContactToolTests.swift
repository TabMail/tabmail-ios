/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - ContactAddTool

@Suite("ContactAddTool Argument Validation")
struct ContactAddToolTests {

    private func makeContext() -> ToolContext {
        let mock = MockChatIdTranslator()
        // ContactAddTool doesn't use DB, but ToolContext requires one
        let db = try! DatabaseQueue()
        return ToolContext(db: db, translator: mock)
    }

    @Test("Missing all identity fields returns error")
    func missingAllFields() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("Empty strings for all identity fields returns error")
    func emptyStrings() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "name": .string(""),
            "email": .string(""),
            "first_name": .string(""),
            "last_name": .string(""),
        ])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("Whitespace-only identity fields returns error")
    func whitespaceOnly() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "name": .string("   "),
            "email": .string("  "),
            "first_name": .string(" "),
            "last_name": .string("  "),
        ])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("Non-string identity fields are treated as empty and returns error")
    func nonStringFields() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "name": .int(42),
            "email": .bool(true),
            "first_name": .array([]),
            "last_name": .dictionary([:]),
        ])
        #expect(result.contains("Provide at least a name or an email"))
    }

    @Test("Only nickname provided (no name/email/first/last) returns error")
    func onlyNickname() async throws {
        let tool = ContactAddTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "nickname": .string("Johnny"),
        ])
        #expect(result.contains("Provide at least a name or an email"))
    }
}

// MARK: - ContactEditTool

@Suite("ContactEditTool Argument Validation")
struct ContactEditToolTests {

    private func makeContext() -> ToolContext {
        let mock = MockChatIdTranslator()
        let db = try! DatabaseQueue()
        return ToolContext(db: db, translator: mock)
    }

    @Test("Missing contact_id returns error")
    func missingContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Empty string contact_id returns error")
    func emptyContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .string(""),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Whitespace-only contact_id returns error")
    func whitespaceContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .string("   "),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (int) returns error")
    func intContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .int(42),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (bool) returns error")
    func boolContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .bool(true),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (array) returns error")
    func arrayContactId() async throws {
        let tool = ContactEditTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .array([.string("abc")]),
        ])
        #expect(result.contains("missing contact_id"))
    }
}

// MARK: - ContactDeleteTool

@Suite("ContactDeleteTool Argument Validation")
struct ContactDeleteToolTests {

    private func makeContext() -> ToolContext {
        let mock = MockChatIdTranslator()
        let db = try! DatabaseQueue()
        return ToolContext(db: db, translator: mock)
    }

    @Test("Missing contact_id returns error")
    func missingContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Empty string contact_id returns error")
    func emptyContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .string(""),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Whitespace-only contact_id returns error")
    func whitespaceContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .string("   "),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (int) returns error")
    func intContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .int(42),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (bool) returns error")
    func boolContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .bool(true),
        ])
        #expect(result.contains("missing contact_id"))
    }

    @Test("Non-string contact_id (array) returns error")
    func arrayContactId() async throws {
        let tool = ContactDeleteTool(context: makeContext())
        let result = try await tool.execute(arguments: [
            "contact_id": .array([.string("abc")]),
        ])
        #expect(result.contains("missing contact_id"))
    }
}
