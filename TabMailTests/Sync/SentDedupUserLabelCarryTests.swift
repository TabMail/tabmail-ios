/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// **The invariant: a user-applied label on an optimistic Sent header survives
/// the delta-sync dedup replacement — including when the incoming label set is
/// empty.**
///
/// Mechanism these tests exist to hold closed: `messageUserLabel.messageId`
/// declares `.references("messageHeader", onDelete: .cascade)`, so when the
/// optimistic-Sent dedup in `SyncEngineDeltaSync` deletes the locally-minted
/// header and inserts the real server one, SQLite erases that message's
/// junction rows. The rebuild immediately after the insert is driven by
/// `info.userLabelIds` — the INCOMING set — which
///
///   * on Gmail is legitimately EMPTY whenever the label catalog has not
///     loaded (`GmailUserLabelCatalogState.isAuthoritative == false` makes
///     `extractUserLabelIds` filter everything out), and
///   * on either provider can never contain a label the user applied locally
///     whose `.addUserLabel` `PendingOperation` has not drained yet.
///
/// So the rebuild restores nothing and the user's label is silently gone.
///
/// 🚨 **These tests drive PRODUCTION `SyncEngine.performDeltaSync`, not a
/// re-implementation of it.** `TabMailTests/Services/OptimisticSentHeaderTests`
/// covers the same dedup through `simulateSyncForSentFolder` /
/// `simulateDeltaSyncInsert`, which are *copies* of the production blocks — and
/// `KNOWN_ISSUES.md` `IOS-OUTBOX-002` records exactly what that costs: a test
/// asserting against a REPLICA of production rather than production makes a
/// blessing test undetectable by red-proof. The replica has no FK cascade
/// against it and no `MessageUserLabel` rebuild in it, so it would have stayed
/// green on the defect no matter how the assertion was written. The whole point
/// of these two tests is that the cascade, the delete, the insert and the
/// rebuild are the real ones.
///
/// **Red evidence (pre-fix):** with the `carriedUserLabelIds` fetch and
/// re-insert removed from `SyncEngineDeltaSync` — i.e. at `b4de53ec6` — both
/// tests fail on the post-sync label assertion, reading `[]` where the Gmail
/// case expects the carried label and `["<acct>:Work"]` where the Exchange case
/// expects the carried label alongside it. Every other assertion in both tests
/// (fixture cardinality, dedup actually ran, old header gone) passes in both
/// directions, so the failure isolates to the carry.
///
/// `.serialized, .processGlobalState` — these tests replace `AppDatabase.shared`
/// so `SyncEngine.dbPool` resolves to the fixture pool, and they read the
/// process-global `AccountManager.shared` recently-completed map.
@Suite("Optimistic-Sent dedup carries user-label membership", .serialized, .processGlobalState)
struct SentDedupUserLabelCarryTests {

    // MARK: - Shared fixture helpers

    /// The label ids attached to a header, sorted so an assertion never depends
    /// on insert order.
    private static func labelIds(forHeader headerId: String, pool: DatabasePool) throws -> [String] {
        try pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == headerId)
                .fetchAll(db)
                .map(\.userLabelId)
                .sorted()
        }
    }

    private static func headerExists(_ headerId: String, pool: DatabasePool) throws -> Bool {
        try pool.read { db in try MessageHeader.fetchOne(db, key: headerId) != nil }
    }

    /// Seeds two same-RFC optimistic Sent headers. The higher-id decoy is inserted
    /// first, so insertion order disagrees with the production `id ASC` selection.
    /// Each row owns a distinct body and label, making both the selected row and
    /// every carried consumer-visible value observable after replacement.
    private static func seed(
        accountId: String,
        provider: AccountProvider,
        historyCursor: String,
        sentPath: String,
        optimisticMessageId: String,
        rfc822Raw: String,
        providerLabelId: String,
        pool: DatabasePool
    ) throws -> (
        account: Account,
        selectedHeaderId: String,
        selectedLabelId: String,
        decoyHeaderId: String,
        decoyLabelId: String
    ) {
        var account = Account(
            emailAddress: "\(accountId)@example.com",
            displayName: "R18 sent-dedup fixture",
            provider: provider
        )
        account.id = accountId
        account.lastHistoryId = historyCursor
        let toInsert = account

        let folderId = "\(accountId):\(sentPath)"
        let selectedHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: sentPath, messageId: optimisticMessageId)
        let decoyMessageId = "\(optimisticMessageId)-z"
        let decoyHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: sentPath, messageId: decoyMessageId)
        let selectedLabel = UserLabel(
            accountId: accountId, providerLabelId: providerLabelId,
            name: providerLabelId, isSystem: false)
        let decoyProviderLabelId = "\(providerLabelId)_Decoy"
        let decoyLabel = UserLabel(
            accountId: accountId, providerLabelId: decoyProviderLabelId,
            name: decoyProviderLabelId, isSystem: false)

        try pool.write { db in
            try toInsert.insert(db)

            var folder = Folder(name: sentPath, path: sentPath, role: .sent, accountId: accountId)
            folder.totalCount = 2
            try folder.insert(db)

            var decoy = MessageHeader(
                messageId: decoyMessageId,
                subject: "R18 decoy fixture",
                from: "R18 Fixture",
                fromAddress: "\(accountId)@example.com",
                to: "recipient@example.com",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                snippet: "r18 decoy fixture",
                folderId: folderId,
                accountId: accountId,
                folderPath: sentPath,
                isInInbox: false
            )
            decoy.rfc822MessageId = EmailFilter.normalizeMessageId(rfc822Raw)
            decoy.headerComplete = true
            try decoy.insert(db)
            try MessageBody(
                contentKey: ContentKey(rawValue: decoyHeaderId),
                htmlContent: "<p>decoy sent body</p>").insert(db)

            var selected = MessageHeader(
                messageId: optimisticMessageId,
                subject: "R18 selected fixture",
                from: "R18 Fixture",
                fromAddress: "\(accountId)@example.com",
                to: "recipient@example.com",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                snippet: "r18 selected fixture",
                folderId: folderId,
                accountId: accountId,
                folderPath: sentPath,
                isInInbox: false
            )
            selected.rfc822MessageId = EmailFilter.normalizeMessageId(rfc822Raw)
            selected.headerComplete = true
            try selected.insert(db)
            try MessageBody(
                contentKey: ContentKey(rawValue: selectedHeaderId),
                htmlContent: "<p>selected sent body</p>").insert(db)

            try decoyLabel.insert(db)
            try selectedLabel.insert(db)
            try MessageUserLabel(messageId: decoyHeaderId, userLabelId: decoyLabel.id).insert(db)
            try MessageUserLabel(messageId: selectedHeaderId, userLabelId: selectedLabel.id).insert(db)
        }

        return (account, selectedHeaderId, selectedLabel.id, decoyHeaderId, decoyLabel.id)
    }

    // MARK: - Gmail

    /// Gmail's incoming set is empty here for the reason it is empty in the
    /// field: the server's record carries no user label yet (the user's label
    /// op has not drained), and the change read's `labels.list` makes that
    /// empty set authoritative. That is the harshest form of the invariant —
    /// the rebuild after the insert has literally nothing to restore, so the
    /// ONLY thing that can preserve the user's label is the carry.
    @Test("Gmail delta dedup keeps a user-applied label when the incoming set is empty")
    func gmailSentDedupCarriesUserLabelAcrossReplacement() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "r18gmailcarry"
        let sentPath = "SENT"
        let serverMessageId = "gm-r18-carry-1"
        let rfc822Raw = "<r18-gmail-carry@example.com>"

        let seeded = try Self.seed(
            accountId: accountId,
            provider: .gmail,
            historyCursor: "1000",
            sentPath: sentPath,
            optimisticMessageId: "optimistic-outbox-1",
            rfc822Raw: rfc822Raw,
            providerLabelId: "Label_R18",
            pool: pool
        )

        // MIS-030 — anchor the fixture cardinality BEFORE the act, so a later
        // "1 label" reading cannot be satisfied by a fixture that never had one.
        #expect(try Self.labelIds(forHeader: seeded.selectedHeaderId, pool: pool) == [seeded.selectedLabelId],
                "precondition: the selected label must be on the lower-id optimistic header")
        #expect(try Self.labelIds(forHeader: seeded.decoyHeaderId, pool: pool) == [seeded.decoyLabelId],
                "precondition: the decoy label must be on the higher-id optimistic header")

        let scenario = FakeHTTP.Scenario()
        FolderEpochTestFixture.registerGmailLabels(on: scenario, listingFoldersOf: accountId, pool: pool)
        defer { scenario.close() }

        scenario.register(path: "/history", method: "GET", response: .json(raw: """
        {
          "historyId": "1001",
          "history": [
            { "messagesAdded": [ { "message": { "id": "\(serverMessageId)", "labelIds": ["SENT"] } } ] }
          ]
        }
        """))
        scenario.register(path: "/messages/\(serverMessageId)", method: "GET", response: .json(raw: """
        {
          "id": "\(serverMessageId)",
          "threadId": "thr-r18-carry",
          "labelIds": ["SENT"],
          "snippet": "",
          "internalDate": "1700000000000",
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              { "name": "Subject", "value": "R18 carry fixture" },
              { "name": "From", "value": "R18 Fixture <\(accountId)@example.com>" },
              { "name": "To", "value": "recipient@example.com" },
              { "name": "Message-Id", "value": "\(rfc822Raw)" }
            ]
          }
        }
        """))

        let provider = GmailProvider(
            userEmail: "\(accountId)@example.com",
            accessToken: { _ in "fake-access-token" },
            session: scenario.session
        )

        let outcome = try await SyncEngine().performDeltaSync(account: seeded.account, provider: provider)
        #expect(outcome.succeeded, "precondition: the delta pass must have run")

        // Non-vacuity: the dedup branch is the branch under test, so prove the
        // replacement actually happened rather than asserting on a header the
        // sync never touched.
        let newHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: sentPath, messageId: serverMessageId)
        #expect(try Self.headerExists(newHeaderId, pool: pool),
                "the real server header must have been inserted")
        #expect(try Self.headerExists(seeded.selectedHeaderId, pool: pool) == false,
                "the lowest-id optimistic header must be the one replaced")
        #expect(try Self.headerExists(seeded.decoyHeaderId, pool: pool),
                "the higher-id decoy must survive untouched")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: ContentKey(rawValue: newHeaderId)) }?.htmlContent
                == "<p>selected sent body</p>",
                "the selected optimistic body's bytes must move to the server address")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: ContentKey(rawValue: seeded.decoyHeaderId)) }?.htmlContent
                == "<p>decoy sent body</p>",
                "the surviving decoy must keep its own body")

        // Gmail's catalog never loaded, so the incoming set really is empty.
        #expect(try Self.labelIds(forHeader: newHeaderId, pool: pool) == [seeded.selectedLabelId],
                "the user's label must survive the replacement even though the incoming label set is empty")
        #expect(try Self.labelIds(forHeader: seeded.decoyHeaderId, pool: pool) == [seeded.decoyLabelId],
                "the survivor's label membership must remain on the survivor")
    }

    // MARK: - Exchange

    /// Exchange's `info.userLabelIds` IS authoritative (`msg.categories`, filtered
    /// only for legacy `tm_*`), so this test states the two-sided version of the
    /// invariant that the Gmail test cannot: the carried label must survive
    /// **and** the incoming set must still be applied. A carry that clobbered
    /// the rebuild would be the mirror image of the bug it fixes (`MIS-005`), and
    /// asserting only on the carried label would not see it.
    ///
    /// Reachability of the empty-for-this-label incoming set on Exchange: the
    /// user applied `Receipts` locally and the `.addUserLabel` op has not drained
    /// to Graph, so the server's echo names `Work` and not `Receipts`.
    @Test("Exchange delta dedup keeps a carried label and still applies the incoming categories")
    func exchangeSentDedupCarriesUserLabelAlongsideIncomingCategories() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let accountId = "r18exchangecarry"
        let sentPath = "sentitems-r18"
        let serverMessageId = "ex-r18-carry-1"
        let rfc822Raw = "<r18-exchange-carry@example.com>"

        let seeded = try Self.seed(
            accountId: accountId,
            provider: .outlook,
            historyCursor: "",
            sentPath: sentPath,
            optimisticMessageId: "optimistic-outbox-2",
            rfc822Raw: rfc822Raw,
            providerLabelId: "Receipts",
            pool: pool
        )

        #expect(try Self.labelIds(forHeader: seeded.selectedHeaderId, pool: pool) == [seeded.selectedLabelId],
                "precondition: the selected label must be on the lower-id optimistic header")
        #expect(try Self.labelIds(forHeader: seeded.decoyHeaderId, pool: pool) == [seeded.decoyLabelId],
                "precondition: the decoy label must be on the higher-id optimistic header")

        // Graph as the change reader sees it: the Sent folder in the folder tree,
        // its message delta and header fetches.
        let server = StatefulExchangeActionServer(messages: [])
        defer { server.close() }
        server.addFolder(id: "inbox-r18", name: "Inbox", wellKnownName: "inbox")
        server.addFolder(id: sentPath, name: "Sent Items", wellKnownName: "sentitems")
        server.addFolder(id: "drafts-r18", name: "Drafts", wellKnownName: "drafts")
        server.addFolder(id: "deleted-r18", name: "Deleted Items", wellKnownName: "deleteditems")
        server.addFolder(id: "archive-r18", name: "Archive", wellKnownName: "archive")
        let provider = server.provider()

        // The first pass reads Sent's first round (empty), so the server's copy
        // arrives as a change in the next one.
        _ = try await SyncEngine().performDeltaSync(account: seeded.account, provider: provider)
        server.deliver(StatefulExchangeActionServer.Seed(
            rfc822MessageId: String(rfc822Raw.dropFirst().dropLast()), providerMessageId: serverMessageId,
            folderId: sentPath, isRead: true, receivedAt: Date(), categories: ["Work"]))
        let account = try #require(try await pool.read { db in try Account.fetchOne(db, key: accountId) })
        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)
        #expect(outcome.succeeded, "precondition: the delta pass must have run")

        let newHeaderId = MessageIdentity.headerId(
            accountId: accountId, folderPath: sentPath, messageId: serverMessageId)
        #expect(try Self.headerExists(newHeaderId, pool: pool),
                "the real server header must have been inserted")
        #expect(try Self.headerExists(seeded.selectedHeaderId, pool: pool) == false,
                "the lowest-id optimistic header must be the one replaced")
        #expect(try Self.headerExists(seeded.decoyHeaderId, pool: pool),
                "the higher-id decoy must survive untouched")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: ContentKey(rawValue: newHeaderId)) }?.htmlContent
                == "<p>selected sent body</p>",
                "the selected optimistic body's bytes must move to the server address")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: ContentKey(rawValue: seeded.decoyHeaderId)) }?.htmlContent
                == "<p>decoy sent body</p>",
                "the surviving decoy must keep its own body")

        let incomingLabelId = UserLabel(
            accountId: accountId, providerLabelId: "Work", name: "Work", isSystem: false).id
        #expect(try Self.labelIds(forHeader: newHeaderId, pool: pool)
                    == [seeded.selectedLabelId, incomingLabelId].sorted(),
                "the carried label AND the incoming category must both be on the replacement header")
        #expect(try Self.labelIds(forHeader: seeded.decoyHeaderId, pool: pool) == [seeded.decoyLabelId],
                "the survivor's label membership must remain on the survivor")
    }
}
