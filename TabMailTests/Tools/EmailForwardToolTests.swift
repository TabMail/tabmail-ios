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

/// A forward the agent asks for with a compose request, on an IMAP email whose folder's numbering
/// is being reset (ADR-IOS-114, the one identity-checked body read).
///
/// THE SYSTEM PROPERTY pinned here: a forward whose email is no longer provably the row at its
/// address (a UIDVALIDITY reset is pending, so a resync can seat another email there) never sends
/// that row's body to the model and never opens a forward card; it reports that the email changed.
/// The same request on an email that still holds opens the forward card for it.
///
/// The model's call is short-circuited by the AI opt-out (no network): the property is whether the
/// request gets past the body read at all, seen as the forward card the request then opens.
@Suite("A forward's body read refuses an email that is no longer itself", .serialized, .processGlobalState)
@MainActor
struct EmailForwardToolBodyReadTests {

    @Test("A pending reset refuses the forward with no card; an unchanged email opens its forward card",
          arguments: [true, false])
    func resetRefusesTheForward(resetPending: Bool) async throws {
        let store = AIService.optOutStore
        let previous = store.object(forKey: AIService.optOutAllAIKey)
        defer {
            if let previous {
                store.set(previous, forKey: AIService.optOutAllAIKey)
            } else {
                store.removeObject(forKey: AIService.optOutAllAIKey)
            }
        }
        AIService.writeOptOutFlag(true)

        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)
        let inserted = try TestDatabase.insertMessageHeader(
            db, messageId: "7", subject: "Offsite", rfc822MessageId: "<offsite@example.com>")
        let id = inserted.id, folderId = inserted.folderId
        try await db.write { db in
            try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = 111 WHERE id = ?", arguments: [folderId])
            try db.execute(sql: "UPDATE messageHeader SET observedUidValidity = 111 WHERE id = ?", arguments: [id])
            try MessageBody(contentKey: ContentKey(rawValue: id), htmlContent: "<p>Are you in for the offsite?</p>").insert(db)
            if resetPending {
                // The reset reaction's first step: the folder is marked, the old row still sits there.
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?",
                               arguments: [Date(), folderId])
            }
        }
        let header = try #require(try await db.read { try MessageHeader.fetchOne($0, key: id) })
        let translator = MockChatIdTranslator()
        await translator.seed(header.id, as: 1)
        let router = AgentToolRouter()
        let tool = EmailForwardTool(context: ToolContext(db: db, translator: translator, router: router))
        let arguments: [String: JSONValue] = [
            "unique_id": .int(1),
            "to": .array([.string("pat@example.com")]),
            "request": .string("Tell Pat about the offsite"),
        ]

        // Bounded: a forward that wrongly opens its card is cancelled, never awaited forever.
        let task = Task { @MainActor in try await tool.execute(arguments: arguments) }
        var card: AgentToolRouter.ComposeRequest?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, card == nil {
            card = router.pendingCompose
            if card == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        card?.onOutcome(.cancelled)
        let output = try await task.value

        if resetPending {
            #expect(card == nil, "no forward card opens for an email that may no longer be itself")
            #expect(router.composeQueueDepth == 0, "nothing is queued either")
            #expect(output.hasPrefix("Failed: ") && output.contains("email changed"), "the agent is told: \(output)")
        } else {
            // Control: the same request on an unchanged email gets past the read and opens its card.
            let opened = try #require(card, "control: the forward card opens")
            #expect(opened.mode == .forward)
            #expect(opened.replyTo?.id == header.id && opened.replyTo?.rfc822MessageId == "<offsite@example.com>")
            #expect(opened.to == ["pat@example.com"])
            #expect(!output.contains("email changed"))
        }
    }
}
