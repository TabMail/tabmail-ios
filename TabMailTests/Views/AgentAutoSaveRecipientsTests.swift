/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import SwiftUI
import Testing
@testable import TabMail

/// The agent's autosave writes the draft other clients see (ADR-IOS-092): the
/// row, and through `queueDraftSave` the Drafts header and the server push,
/// must name the To, Cc and Bcc the compose shows when it writes, never the
/// recipients the agent's turn began with.
@Suite("Agent autosave keeps every recipient", .serialized, .processGlobalState)
@MainActor
struct AgentAutoSaveRecipientsTests {
    /// What the compose shows; changed between the chat's creation and its save.
    private final class Fields {
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
    }

    @Test("The first and later agent autosaves store the To, Cc and Bcc the compose shows")
    func autosaveStoresShownRecipients() async throws {
        let accountId = "acct-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            acc.id = accountId
            try acc.insert(db)
            var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: accountId)
            drafts.lastKnownUidValidity = 1
            try drafts.insert(db)
        }
        // The context is what the agent's turn began with: To only.
        let ctx = ComposeEditContext(
            recipients: ["to@example.com"],
            toRecipients: ["to@example.com"], ccRecipients: [], bccRecipients: [],
            toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
            senderName: "Sender", senderEmail: "sender@example.com", mode: "edit_new",
            compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "",
            relatedFrom: "", relatedTo: "", relatedCc: "", bodyText: "")
        let fields = Fields()
        let draftKey = "draft-\(UUID().uuidString)"
        let chat = DynamicIslandChat(
            composeContext: ctx,
            draftId: draftKey,
            composeGenerationCursor: ComposeGenerationCursor(
                newEpoch: UUID().uuidString, initialExpectedPredecessor: nil),
            composeRecipients: { (fields.to, fields.cc, fields.bcc) },
            composeMutationAllowed: true,
            isExpanded: .constant(false))

        @discardableResult
        func expectSaved(to: [String], cc: [String], bcc: [String], body: String) async throws -> MessageHeader {
            let row = try #require(try await pool.read { db in try Draft.fetchOne(db, key: draftKey) })
            #expect(row.body == body)
            #expect(row.toArray == to)
            #expect(row.ccArray == cc)
            #expect(row.bccArray == bcc)
            let epoch = try #require(row.instanceEpoch)
            let headerId = PendingOperation.draftPlaceholderHeaderPK(
                accountId: accountId, draftsFolderPath: "Drafts", draftId: draftKey, instanceEpoch: epoch)
            let header = try #require(try await pool.read { db in try MessageHeader.fetchOne(db, key: headerId) })
            // The header names exactly the entries that are addresses, never an
            // address made by reading two rejected entries together.
            for (text, entries) in [(header.to, to), (header.cc, cc), (header.bcc, bcc)] {
                let read = AddressParser.parseAddressList(text).flatMap(\.mailboxes).map(\.address)
                #expect(read == RecipientEntry(entries).addresses, "header \(text) for \(entries)")
            }
            return header
        }

        // Recipients changed after the turn began, as the user or the agent's edit
        // does, each named one as compose stores it (#1031).
        let firstTo = [#""Sam Lee" <to@example.com>"#, "added@example.com"]
        let firstCc = [#""Lee, Ann" <cc@example.com>"#]
        let firstBcc = [#""Zoë Kim" <bcc@example.com>"#]
        fields.to = firstTo
        fields.cc = firstCc
        fields.bcc = firstBcc
        #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Subject", body: "First body") == nil)
        try await expectSaved(to: firstTo, cc: firstCc, bcc: firstBcc, body: "First body")

        // A later save rewrites them, a renamed recipient and uncommitted input text included.
        let secondTo = [#""Renamed Person" <added@example.com>"#]
        let secondBcc = [#""Zoë Kim" <bcc@example.com>"#, "other@example.com", "still typing"]
        fields.to = secondTo
        fields.cc = []
        fields.bcc = secondBcc
        #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Subject", body: "Second body") == nil)
        try await expectSaved(to: secondTo, cc: [], bcc: secondBcc, body: "Second body")

        // Two rejected entries in To and two in Cc that, read as one text, would
        // name a mailbox: one nobody listed, and the Bcc recipient. Reply All on
        // the saved draft offers neither.
        let toEntries = ["to@example.com", "\"x", "\" <invented@example.com>"]
        let ccEntries = ["\"y", "\" <bcc@example.com>"]
        #expect(RecipientEntry(toEntries).leftovers.count == 2)
        #expect(RecipientEntry(ccEntries).leftovers.count == 2)
        fields.to = toEntries
        fields.cc = ccEntries
        fields.bcc = ["bcc@example.com"]
        #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Subject", body: "Third body") == nil)
        let header = try await expectSaved(to: toEntries, cc: ccEntries, bcc: ["bcc@example.com"], body: "Third body")
        let replyAll = buildReplyAllRecipients(for: header, allAccounts: [])
        #expect(replyAll.to == ["sender@example.com", "to@example.com"])
        #expect(replyAll.cc.isEmpty)
    }

    /// #915: the agent's first autosave creates the row; it must carry the
    /// compose's reply-all kind so a draft reopened after the app ends sends 103.
    @Test("The agent's first autosave stores the compose's reply-all kind")
    func firstAutosaveStoresReplyAll() async throws {
        let accountId = "acct-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            acc.id = accountId
            try acc.insert(db)
            var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: accountId)
            drafts.lastKnownUidValidity = 1
            try drafts.insert(db)
        }
        let ctx = ComposeEditContext(
            recipients: ["to@example.com"],
            toRecipients: ["to@example.com"], ccRecipients: ["cc@example.com"], bccRecipients: [],
            toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
            senderName: "Sender", senderEmail: "sender@example.com", mode: "edit_reply",
            compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "",
            relatedFrom: "", relatedTo: "", relatedCc: "", bodyText: "")
        for replyAll in [true, false] {
            let draftKey = "draft-\(UUID().uuidString)"
            let chat = DynamicIslandChat(
                composeContext: ctx,
                draftId: draftKey,
                draftIsReplyAll: replyAll,
                composeGenerationCursor: ComposeGenerationCursor(
                    newEpoch: UUID().uuidString, initialExpectedPredecessor: nil),
                composeRecipients: { (["to@example.com"], ["cc@example.com"], []) },
                composeMutationAllowed: true,
                isExpanded: .constant(false))
            #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Re: Subject", body: "Body") == nil)
            let row = try #require(try await pool.read { db in try Draft.fetchOne(db, key: draftKey) })
            #expect(row.isReplyAll == replyAll)
        }
    }

    /// #915: a later agent autosave carries the CURRENT compose's kind. One draft
    /// key (in the app, the shared `reply:` key) is first saved from one entry,
    /// then the other entry's agent saves over it; the row must follow the compose now open, both ways.
    @Test("A later agent autosave stores the current compose's reply-all kind")
    func laterAutosaveFollowsTheCompose() async throws {
        let accountId = "acct-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        try await pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            acc.id = accountId
            try acc.insert(db)
            var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: accountId)
            drafts.lastKnownUidValidity = 1
            try drafts.insert(db)
        }
        let ctx = ComposeEditContext(
            recipients: ["to@example.com"],
            toRecipients: ["to@example.com"], ccRecipients: [], bccRecipients: [],
            toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
            senderName: "Sender", senderEmail: "sender@example.com", mode: "edit_reply",
            compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "",
            relatedFrom: "", relatedTo: "", relatedCc: "", bodyText: "")
        // A compose reopened on an existing row admits saves after that row's epoch.
        func chat(_ key: String, replyAll: Bool, after predecessor: String? = nil) -> DynamicIslandChat {
            DynamicIslandChat(
                composeContext: ctx,
                draftId: key,
                draftIsReplyAll: replyAll,
                composeGenerationCursor: ComposeGenerationCursor(
                    newEpoch: UUID().uuidString, initialExpectedPredecessor: predecessor),
                composeRecipients: { (["to@example.com"], [], []) },
                composeMutationAllowed: true,
                isExpanded: .constant(false))
        }
        for (first, then) in [(false, true), (true, false)] {
            let draftKey = "draft-\(UUID().uuidString)"
            #expect(await chat(draftKey, replyAll: first).autoSaveDraft(
                draftKey: draftKey, subject: "Re: Subject", body: "First") == nil)
            let firstEpoch = try await pool.read { db in try Draft.fetchOne(db, key: draftKey)?.instanceEpoch }
            #expect(await chat(draftKey, replyAll: then, after: firstEpoch).autoSaveDraft(
                draftKey: draftKey, subject: "Re: Subject", body: "Second") == nil)
            let row = try #require(try await pool.read { db in try Draft.fetchOne(db, key: draftKey) })
            #expect(row.body == "Second", "precondition: the later save updated the row")
            #expect(row.isReplyAll == then, "first=\(first): the row follows the compose now open")
        }
    }
}
