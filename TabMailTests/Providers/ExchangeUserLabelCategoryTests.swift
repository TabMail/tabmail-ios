/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

// MARK: - 1. The wire

/// `IOS-LABEL-002` — an Outlook user label IS a Graph message `category`, and it
/// must actually reach the server.
///
/// Before this change the queue's Exchange arms were
/// `print("[Queue] addUserLabel not yet supported for Exchange")` followed by
/// `return .allMembers`: the durable op was **retired as successful having done
/// nothing**. That is not a missing feature, it is a never-drop violation — the
/// op left the queue without provider success, without a provider-authoritative
/// no-op, without annihilation and without a proven id reset.
///
/// Every test here asserts the SYSTEM PROPERTY — *what the server ends up
/// holding* — read back through the fixture's own model, never "the adapter
/// called method X". A mechanism-pinning test would stay green on an adapter
/// that PATCHed the wrong array.
@Suite("Outlook user labels reach Graph as message categories (IOS-LABEL-002)")
struct ExchangeUserLabelCategoryWireTests {

    private func addOp(messageId: String, label: String) -> PendingOperation {
        PendingOperation(
            type: .addUserLabel, messageIds: [messageId],
            accountId: "acc-outlook", folderPath: "Inbox", userLabelId: label)
    }

    private func removeOp(messageId: String, label: String) -> PendingOperation {
        PendingOperation(
            type: .removeUserLabel, messageIds: [messageId],
            accountId: "acc-outlook", folderPath: "Inbox", userLabelId: label)
    }

    /// Every `categories` array the adapter PATCHed, in order.
    private func patchedCategoryArrays(
        _ server: StatefulExchangeActionServer
    ) -> [[String]] {
        server.http.recordedCalls().compactMap { call in
            guard call.method == "PATCH",
                  let body = call.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["categories"] as? [String]
        }
    }

    // MARK: 1a — the op reaches the server at all

    /// The `print`-and-retire path is gone: the durable op now produces a real
    /// mutation the server holds.
    @Test("An addUserLabel op on Exchange leaves the category on the server")
    @MainActor
    func addUserLabelOpLeavesTheCategoryOnTheServer() async throws {
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "label-add@example.com",
            providerMessageId: "graph-msg-1",
            folderId: "Inbox"
        )])
        defer { server.close() }

        _ = try await AccountManager.shared.executeOperation(
            addOp(messageId: "graph-msg-1", label: "Receipts"),
            provider: server.provider())

        #expect(server.categories(providerMessageId: "graph-msg-1") == ["Receipts"],
                """
                the user's label never reached the server — the executor retired \
                the op having done nothing
                """)
    }

    // MARK: 1b — the clobber guard (the most important test here)

    /// 🚨 Graph's PATCH REPLACES the whole `categories` array. A blind write
    /// would destroy categories the user set in Outlook desktop, Outlook web or
    /// via a server-side rule. The adapter must read, filter and write back.
    @Test("Adding a label preserves categories another client already set")
    @MainActor
    func addingALabelPreservesCategoriesAnotherClientSet() async throws {
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "label-foreign@example.com",
            providerMessageId: "graph-msg-2",
            folderId: "Inbox",
            categories: ["Work", "Travel"]
        )])
        defer { server.close() }

        _ = try await AccountManager.shared.executeOperation(
            addOp(messageId: "graph-msg-2", label: "Receipts"),
            provider: server.provider())

        #expect(server.categories(providerMessageId: "graph-msg-2")
                    == ["Work", "Travel", "Receipts"],
                """
                a category set by another client was destroyed — the PATCH \
                replaced the array instead of extending the server's own
                """)
    }

    /// The same guard on the way out: removal must subtract exactly one name.
    @Test("Removing a label takes only its own name out")
    @MainActor
    func removingALabelTakesOnlyItsOwnNameOut() async throws {
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "label-remove@example.com",
            providerMessageId: "graph-msg-3",
            folderId: "Inbox",
            categories: ["Work", "Receipts", "Travel"]
        )])
        defer { server.close() }

        _ = try await AccountManager.shared.executeOperation(
            removeOp(messageId: "graph-msg-3", label: "Receipts"),
            provider: server.provider())

        #expect(server.categories(providerMessageId: "graph-msg-3") == ["Work", "Travel"],
                "removal must subtract exactly the op's own category and nothing else")
    }

    // MARK: 1c — no mutation when there is nothing to change

    /// A redundant add costs one read and NO write. Two-sided: the GET must
    /// still have happened, so a zero PATCH count cannot come from an adapter
    /// that did nothing at all.
    @Test("A redundant add reads the server but issues no PATCH")
    @MainActor
    func aRedundantAddIssuesNoPatch() async throws {
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "label-redundant@example.com",
            providerMessageId: "graph-msg-4",
            folderId: "Inbox",
            categories: ["Receipts"]
        )])
        defer { server.close() }

        _ = try await AccountManager.shared.executeOperation(
            addOp(messageId: "graph-msg-4", label: "Receipts"),
            provider: server.provider())

        #expect(patchedCategoryArrays(server).isEmpty,
                "an unchanged array must not be written back")
        #expect(server.http.recordedCalls().contains {
            $0.method == "GET" && $0.url.contains("select=categories")
        }, """
        the adapter issued no categories read either — the zero PATCH count \
        above would then be vacuous
        """)
        #expect(server.categories(providerMessageId: "graph-msg-4") == ["Receipts"])
    }

    // MARK: 1d — the value on the wire is the BARE provider id

    /// D10 / `IOS-LABEL-001`: `PendingOperation.userLabelId` carries
    /// `UserLabel.providerLabelId`, never the account-prefixed `UserLabel.id`.
    /// A prefixed value here would write a wrong category name onto the user's
    /// real message.
    @Test("The PATCHed category is the bare provider value, not the account-prefixed surrogate")
    @MainActor
    func thePatchedCategoryIsTheBareProviderValue() async throws {
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "label-bare@example.com",
            providerMessageId: "graph-msg-5",
            folderId: "Inbox"
        )])
        defer { server.close() }

        let label = UserLabel(
            accountId: "acc-outlook", providerLabelId: "Receipts",
            name: "Receipts", isSystem: false)

        _ = try await AccountManager.shared.executeOperation(
            addOp(messageId: "graph-msg-5", label: label.providerLabelId),
            provider: server.provider())

        let onServer = server.categories(providerMessageId: "graph-msg-5") ?? []
        #expect(onServer == ["Receipts"])
        #expect(!onServer.contains(label.id),
                "the account-prefixed surrogate reached the user's real message")
    }
}

// MARK: - 2. The read path

/// The mapping that was missing: `categories` was already selected and already
/// decoded, and `parseGraphMessage` threw it away with `userLabelIds: []`.
@Suite("Graph categories become user labels on parse (IOS-LABEL-002)")
struct ExchangeCategoryParseTests {

    private func makeProvider() -> ExchangeProvider {
        ExchangeProvider(userEmail: "test@example.com", accessToken: { _ in "dummy-token" })
    }

    private func parse(categories: [String]) async throws -> MessageHeaderInfo {
        let json: [String: Any] = [
            "id": "graph-parse-1",
            "subject": "Parsed",
            "receivedDateTime": "2026-01-14T12:00:00Z",
            "isRead": false,
            "hasAttachments": false,
            "internetMessageId": "<parse@example.com>",
            "categories": categories,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let msg = try JSONDecoder().decode(GraphMessage.self, from: data)
        return try #require(await makeProvider().parseGraphMessage(msg))
    }

    @Test("A real Graph category surfaces as a user label")
    func realCategorySurfacesAsAUserLabel() async throws {
        let header = try await parse(categories: ["Receipts"])
        #expect(header.userLabelIds == ["Receipts"],
                "the category the server holds was dropped on the floor")
    }

    /// ADR-IOS-036 keeps action tags local-only, and
    /// `ExchangeProvider.stripLegacyCategories` actively DELETES `tm_*`
    /// categories from the server. Surfacing one as a user label would show the
    /// user a label another code path is busy erasing.
    @Test("tm_* categories never surface as user labels, in any casing")
    func legacyActionTagCategoriesNeverSurface() async throws {
        let header = try await parse(
            categories: ["tm_todo", "TM_Done", "tM_later", "Receipts", "Work"])
        #expect(header.userLabelIds == ["Receipts", "Work"],
                "a tm_* category leaked into the user's labels")
    }

    /// A message with no categories is not a message with unknown categories —
    /// the empty set is the truth Graph reported.
    @Test("No categories yields no user labels")
    func noCategoriesYieldsNoUserLabels() async throws {
        let header = try await parse(categories: [])
        #expect(header.userLabelIds.isEmpty)
    }

    /// Every `parseGraphMessage` caller fetches a `$select` derived from
    /// `GraphAPI.headerOnlyFields`, which names `categories`, so the set really
    /// is exact. This pins the field list, not the flag: a `$select` that lost
    /// `categories` would make the `true` a lie that a future reconcile turns
    /// into wholesale label erasure.
    @Test("Every Graph header $select still carries categories, so the set is authoritative")
    func headerSelectCarriesCategoriesSoTheSetIsAuthoritative() async throws {
        #expect(GraphAPI.headerOnlyFields.contains("categories"))
        #expect(GraphAPI.metadataSelectFields.contains("categories"))
        #expect(GraphAPI.backfillSelectFields.contains("categories"))
        #expect(GraphAPI.fullSelectFields.contains("categories"))

        let header = try await parse(categories: ["Receipts"])
        #expect(header.userLabelIdsAreAuthoritative)
    }
}

// MARK: - 3. The menu, and the verbatim round trip

/// The user-visible half: an Outlook account's label sheet is no longer empty
/// and disabled, and the name the user types is the name the server echoes.
@Suite("Outlook label menu and verbatim round trip (IOS-LABEL-002)", .serialized, .processGlobalState)
struct OutlookUserLabelMenuTests {

    // MARK: Harness (mirrors UserLabelWireValueTests.fixture)

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(accountId: String, provider: AccountProvider) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Labels",
                provider: provider)
            account.id = accountId
            try account.insert(db)
            // Graph folder ids stand in for paths on Outlook, exactly as the
            // provider uses them; the value only has to be consistent here.
            let folder = Folder(name: "Inbox", path: "Inbox", role: .inbox, accountId: accountId)
            try folder.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    private func restore(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    @discardableResult
    private func insertHeader(_ fixture: Fixture, messageId: String) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Labels", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "labels",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "Inbox"),
            accountId: fixture.accountId, folderPath: "Inbox", isInInbox: true)
        header.rfc822MessageId = "\(messageId)@example.com"
        header.headerComplete = true
        let stored = header
        try fixture.pool.writeWithoutTransaction { db in try stored.insert(db) }
        return stored
    }

    // MARK: 3a — the menu is no longer empty

    /// The gate hid an Outlook account's OWN existing label rows behind an
    /// empty, disabled sheet. Both halves are asserted: the capability flag and
    /// the rows it gates.
    @Test("An Outlook account's label menu offers its labels and is enabled")
    @MainActor
    func outlookMenuOffersItsLabels() async throws {
        let f = try fixture(accountId: "labels-outlook", provider: .outlook)
        defer { restore(f) }

        let header = try insertHeader(f, messageId: "graph-menu-1")
        let label = UserLabel(
            accountId: f.accountId, providerLabelId: "Receipts",
            name: "Receipts", isSystem: false)
        try await f.pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.loadLabels()

        #expect(model.supportsRemoteUserLabels,
                "Outlook's adapter mutates labels remotely — the menu must not be inert")
        #expect(model.sortedLabels.map(\.id) == [label.id],
                "the account's own label rows were hidden from its own menu")
    }

    /// NON-VACUITY, the refusing side. CalDAV carries no mail, so the question
    /// is inapplicable rather than unimplemented; a gate that now says `true`
    /// for everything must still fail this.
    @Test("CalDAV still refuses: no menu, no queued op")
    @MainActor
    func caldavStillRefuses() async throws {
        let f = try fixture(accountId: "labels-caldav", provider: .caldav)
        defer { restore(f) }

        let header = try insertHeader(f, messageId: "caldav-1")
        let label = UserLabel(
            accountId: f.accountId, providerLabelId: "Receipts",
            name: "Receipts", isSystem: false)
        try await f.pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        model.loadLabels()
        #expect(model.supportsRemoteUserLabels == false)
        #expect(model.sortedLabels.isEmpty)

        #expect(await model.applyLabel(label) == false)
        let ops = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.isEmpty, "a label op was queued for a provider that can never execute it")
    }

    // MARK: 3b — the verbatim round trip (D-B's decisive argument)

    /// 🚨 THE INVARIANT: the label the user creates and the label the server
    /// echoes back are ONE row, not two.
    ///
    /// Graph category names are case-SENSITIVE display strings. Lowercasing at
    /// creation (which is what IMAP does, because RFC 3501 keywords are
    /// case-INsensitive) would make the user's `Receipts` and the server's
    /// echoed `Receipts` derive two different `UserLabel.id`s, and the menu would
    /// grow a duplicate row for one category.
    ///
    /// This is deliberately expressed as "how many rows survive", the way the
    /// sync arms actually insert them (`insert(db, onConflict: .ignore)`), and
    /// not as "the id has no lowercase in it" — the latter would pin the fix's
    /// mechanism and stay green on a system that still duplicates.
    @Test("A label created as Receipts and the server's echoed Receipts are ONE row")
    @MainActor
    func createdLabelAndServerEchoAreOneRow() async throws {
        let f = try fixture(accountId: "labels-roundtrip", provider: .outlook)
        defer { restore(f) }

        let header = try insertHeader(f, messageId: "graph-roundtrip-1")
        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        #expect(await model.createAndApply(name: "Receipts"),
                "creating a label on Outlook must succeed")

        // What the server is told, and what the server says back.
        let queued = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(queued.count == 1)
        #expect(queued.first?.userLabelId == "Receipts",
                """
                the wire value was not the user's name verbatim — got \
                \(queued.first?.userLabelId ?? "<nil>")
                """)

        let echoedJSON: [String: Any] = [
            "id": header.messageId,
            "subject": "Labels",
            "receivedDateTime": "2026-01-14T12:00:00Z",
            "isRead": false,
            "hasAttachments": false,
            "internetMessageId": "<\(header.messageId)@example.com>",
            "categories": ["Receipts"],
        ]
        let msg = try JSONDecoder().decode(
            GraphMessage.self, from: JSONSerialization.data(withJSONObject: echoedJSON))
        let provider = ExchangeProvider(
            userEmail: "labels-roundtrip@example.com", accessToken: { _ in "dummy-token" })
        let parsed = try #require(await provider.parseGraphMessage(msg))

        // The sync arms' own insert shape, applied to what the server echoed.
        try await f.pool.write { db in
            for labelId in parsed.userLabelIds {
                try UserLabel(
                    accountId: f.accountId, providerLabelId: labelId,
                    name: labelId, isSystem: false
                ).insert(db, onConflict: .ignore)
            }
        }

        let rows = try await f.pool.read { db in try UserLabel.fetchAll(db) }
        #expect(rows.count == 1, """
            the user's label and the server's echo of the SAME category produced \
            \(rows.count) rows: \(rows.map(\.id))
            """)
    }

    // MARK: 3c — non-vacuity: the other providers are untouched

    /// IMAP still lowercases, because its reason (RFC 3501 case-insensitivity)
    /// has not changed. This is the second side of the verbatim argument: it
    /// proves the Outlook arm deviates for a reason and did not simply delete a
    /// normalization everywhere.
    @Test("IMAP still lowercases its keyword id")
    @MainActor
    func imapStillLowercasesItsKeyword() async throws {
        let f = try fixture(accountId: "labels-imap", provider: .imap)
        defer { restore(f) }

        let header = try insertHeader(f, messageId: "42")
        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header))
        #expect(await model.createAndApply(name: "Receipts"))

        let rows = try await f.pool.read { db in try UserLabel.fetchAll(db) }
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row.providerLabelId == "receipts",
                "IMAP's keyword normalization was removed along with Outlook's")
        #expect(row.name == "Receipts", "the DISPLAY name is never normalized")
    }

    /// The capability ladder as a CLOSURE over every provider, not as the one
    /// case that changed. `AccountProvider` is not `CaseIterable` (and adding
    /// the conformance is a production change out of this scope), so the list is
    /// spelled out here; the compile-time guard against a sixth provider is
    /// `supportsRemoteUserLabels(_:)`'s own exhaustive `default:`-free switch,
    /// and this is its behavioural counterpart.
    @Test("Exactly one provider refuses remote user labels: CalDAV")
    func exactlyCaldavRefusesRemoteUserLabels() {
        let everyProvider: [AccountProvider] = [.gmail, .outlook, .imap, .icloud, .caldav]
        let refusing = everyProvider.filter {
            !UserLabelMenuModel.supportsRemoteUserLabels($0)
        }
        #expect(refusing == [.caldav],
                "the set of providers without remote user labels changed: \(refusing)")
    }
}
