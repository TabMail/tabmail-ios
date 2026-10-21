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

        // Recipients changed after the turn began, as the user or the agent's edit does.
        fields.to = ["to@example.com", "added@example.com"]
        fields.cc = ["cc@example.com"]
        fields.bcc = ["bcc@example.com"]
        #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Subject", body: "First body") == nil)
        try await expectSaved(
            to: ["to@example.com", "added@example.com"], cc: ["cc@example.com"], bcc: ["bcc@example.com"],
            body: "First body")

        // A later save rewrites them, uncommitted input text included.
        fields.to = ["added@example.com"]
        fields.cc = []
        fields.bcc = ["bcc@example.com", "other@example.com", "still typing"]
        #expect(await chat.autoSaveDraft(draftKey: draftKey, subject: "Subject", body: "Second body") == nil)
        try await expectSaved(
            to: ["added@example.com"], cc: [], bcc: ["bcc@example.com", "other@example.com", "still typing"],
            body: "Second body")

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
}
