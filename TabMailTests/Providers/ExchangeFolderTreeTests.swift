/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// `ExchangeProvider.fetchFolders` against a model Outlook mailbox whose folder
/// tree is deeper than two levels and whose listings come back in pages.
///
/// The model follows Microsoft Graph's documented contract:
/// - `GET /me/mailFolders` returns only the root's children, and "to return all
///   mail folders in a mailbox, each child folder must be traversed separately"
///   (List mailFolders);
/// - a listing longer than the page returns `@odata.nextLink`, and "to read all
///   results, you must continue to call Microsoft Graph with the @odata.nextLink
///   property returned in each response until the @odata.nextLink property is no
///   longer returned" (Paging). The model's page is deliberately smaller than the
///   `$top` the app asks for, which Graph allows ("different APIs might have
///   different default and maximum page sizes");
/// - a mail search folder under the root comes back in the same listing, marked
///   `"@odata.type": "#microsoft.graph.mailSearchFolder"`. It is a saved query
///   over messages that live in real folders, not a place mail can be filed;
/// - a hidden folder (`isHidden`), at the root or below it, is listed only when
///   that listing's request asks for it with `includeHiddenFolders=true` (List
///   mailFolders, List childFolders);
/// - a folder carries only the properties the request's `$select` names (Use
///   query parameters), and the nextLink carries the request's options to the
///   following pages.
@Suite("ExchangeProvider — whole folder tree")
struct ExchangeFolderTreeTests {
    private struct Node {
        let id: String
        let name: String
        let isSearchFolder: Bool
        let isHidden: Bool
        let children: [Node]

        init(_ id: String, _ name: String, search: Bool = false, hidden: Bool = false, _ children: [Node] = []) {
            self.id = id
            self.name = name
            self.isSearchFolder = search
            self.isHidden = hidden
            self.children = children
        }

        var subtree: [Node] { [self] + children.flatMap(\.subtree) }
    }

    /// A search folder whose parent is the Inbox. Graph's root listing can
    /// return such a folder as well as the Inbox's own listing, so it is listed
    /// twice here.
    private static let inboxSearch = Node("f-inbox-unread", "Unread", search: true)

    /// Seven folders under the root (four pages), one of them hidden, an Inbox
    /// with four children (two pages), a branch four levels deep, a hidden
    /// folder below a visible one, and search folders at the root, below a
    /// folder, and in both places at once.
    private static let rootChildren: [Node] = [
        Node("f-inbox", "Inbox", [
            Node("f-clients", "Clients", [
                Node("f-clients-private", "Private", hidden: true),
                Node("f-acme", "Acme", [
                    Node("f-acme-contracts", "Contracts"),
                ]),
            ]),
            Node("f-receipts", "Receipts"),
            Node("f-newsletters", "Newsletters"),
            inboxSearch,
        ]),
        Node("f-sent", "Sent Items"),
        Node("f-projects", "Projects", [
            Node("f-launch", "Launch"),
            Node("f-projects-flagged", "Flagged in Projects", search: true),
        ]),
        Node("f-digest", "Weekly digests", search: true),
        inboxSearch,
        Node("f-archive", "Archive"),
        Node("f-hidden", "Hidden notes", hidden: true),
    ]

    /// Every folder's own unread and total counts, all different, so a count
    /// taken from the wrong field or the wrong folder shows.
    private static func counts(_ id: String) -> (unread: Int, total: Int) {
        let index = rootChildren.flatMap(\.subtree).firstIndex { $0.id == id } ?? 0
        return (unread: index + 1, total: 100 + 7 * index)
    }

    /// Smaller than both `$top` values the app sends, so every listing with
    /// more than this many folders needs `@odata.nextLink`.
    private static let pageSize = 2
    private static let graphBase = "https://graph.microsoft.com/v1.0/me"

    /// A folder as Graph returns it: its `id` and type annotation always, and
    /// each other property only when `selected` names it.
    private static func folderJSON(_ node: Node, selected: Set<String>) -> String {
        let count = counts(node.id)
        var fields = ["\"id\": \"\(node.id)\""]
        if node.isSearchFolder { fields.insert("\"@odata.type\": \"#microsoft.graph.mailSearchFolder\"", at: 0) }
        let properties: [(String, String)] = [
            ("displayName", "\"\(node.name)\""),
            ("unreadItemCount", "\(count.unread)"),
            ("totalItemCount", "\(count.total)"),
            ("childFolderCount", "\(node.children.count)"),
        ]
        for (name, value) in properties where selected.contains(name) {
            fields.append("\"\(name)\": \(value)")
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// One page of `children`, starting at the `$skiptoken` the request carries.
    /// Hidden folders are in the listing only when the request asks for them,
    /// and the next page's link keeps every option of the request.
    private static func page(of allChildren: [Node], listingPath: String, url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = items.first { $0.name == "$skiptoken" }.flatMap { Int($0.value ?? "") } ?? 0
        let withHidden = items.contains { $0.name == "includeHiddenFolders" && $0.value == "true" }
        let selected = Set((items.first { $0.name == "$select" }?.value ?? "").split(separator: ",").map(String.init))
        let children = allChildren.filter { withHidden || !$0.isHidden }
        let end = min(start + pageSize, children.count)
        let values = children[start..<end].map { folderJSON($0, selected: selected) }.joined(separator: ", ")
        var next = ""
        if end < children.count {
            var link = URLComponents(string: graphBase + listingPath)!
            link.queryItems = items.filter { $0.name != "$skiptoken" } + [URLQueryItem(name: "$skiptoken", value: "\(end)")]
            next = ", \"@odata.nextLink\": \"\(link.url!.absoluteString)\""
        }
        return "{\"value\": [\(values)]\(next)}"
    }

    /// Serves the model: well-known names (`/mailFolders/inbox`), the root
    /// listing, and each folder's `childFolders` listing, all paged.
    private static func serve(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        let all = rootChildren.flatMap(\.subtree)
        let prefix = "/v1.0/me/mailFolders"
        let rest = String(request.url.path.dropFirst(prefix.count))
        if rest.isEmpty || rest == "/" {
            return .json(raw: page(of: rootChildren, listingPath: "/mailFolders", url: request.url))
        }
        let parts = rest.split(separator: "/").map(String.init)
        if parts.count == 2, parts[1] == "childFolders",
           let parent = all.first(where: { $0.id == parts[0] }) {
            return .json(raw: page(
                of: parent.children,
                listingPath: "/mailFolders/\(parent.id)/childFolders",
                url: request.url))
        }
        if parts.count == 1, parts[0] == "inbox" {
            return .json(raw: "{\"id\": \"f-inbox\", \"displayName\": \"Inbox\"}")
        }
        if parts.count == 1, parts[0] == "sentitems" {
            return .json(raw: "{\"id\": \"f-sent\", \"displayName\": \"Sent Items\"}")
        }
        return .status(404)
    }

    @Test("Every real folder at every depth and on every page, hidden ones included, is listed once with its own counts; search folders at any depth, even listed twice, are not")
    func everyFolderInTheTreeIsListed() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/v1.0/me/mailFolders", handler: Self.serve)

        let provider = ExchangeProvider(
            userEmail: "folder-tree@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )
        let folders = try await provider.fetchFolders()

        let realFolders = Self.rootChildren.flatMap(\.subtree).filter { !$0.isSearchFolder }
        let searchFolderIds = Set(Self.rootChildren.flatMap(\.subtree).filter(\.isSearchFolder).map(\.id))
        let listedIds = folders.map(\.path)
        #expect(listedIds.count == Set(listedIds).count, "a folder was listed twice: \(listedIds)")
        #expect(Set(listedIds) == Set(realFolders.map(\.id)))
        #expect(searchFolderIds == ["f-digest", "f-projects-flagged", "f-inbox-unread"])
        #expect(Set(listedIds).isDisjoint(with: searchFolderIds), "a search folder only shows mail stored in other folders")

        let byId = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
        for node in realFolders {
            #expect(byId[node.id]?.name == node.name)
            #expect(byId[node.id]?.unreadCount == Self.counts(node.id).unread, "\(node.id) unread")
            #expect(byId[node.id]?.totalCount == Self.counts(node.id).total, "\(node.id) total")
        }
        #expect(listedIds.contains("f-hidden"), "a hidden folder is a real folder mail can be filed in")
        #expect(listedIds.contains("f-clients-private"), "so is a hidden folder below a visible one")
        #expect(byId["f-inbox"]?.role == .inbox)
        #expect(byId["f-sent"]?.role == .sent)
        #expect(byId["f-acme-contracts"]?.role == .custom)
    }
}

/// `fetchFolders` feeds `SyncEngine.fullSync`, which stores the list it returns as
/// the account's whole folder table. So a listing that finishes reaches the stored
/// folders and the move picker, and a listing that cannot finish must fail as a
/// whole, through the real sync path, and leave the stored folders, headers and
/// queued actions as they were; a later sync lists the tree again.
@Suite("ExchangeProvider — folder tree through the full sync", .serialized, .processGlobalState)
struct ExchangeFolderTreeSyncTests {
    private static let root = "/v1.0/me/mailFolders"
    private static let graph = "https://graph.microsoft.com/v1.0/me/mailFolders"
    /// Stops a server that would otherwise answer forever, so a walker with no
    /// end of its own fails the test instead of hanging it.
    private static let fuse = 32

    private static func folder(_ id: String, children: Int = 0) -> String {
        "{\"id\":\"\(id)\",\"displayName\":\"\(id)\",\"unreadItemCount\":2,\"totalItemCount\":7,\"childFolderCount\":\(children)}"
    }

    private static func searchFolder(_ id: String) -> String {
        "{\"@odata.type\":\"#microsoft.graph.mailSearchFolder\",\"id\":\"\(id)\",\"displayName\":\"\(id)\",\"unreadItemCount\":0,\"totalItemCount\":3,\"childFolderCount\":0}"
    }

    private static func page(_ entries: [String], next: String? = nil) -> FakeHTTP.CannedResponse {
        let tail = next.map { ",\"@odata.nextLink\":\"\($0)\"" } ?? ""
        return .json(raw: "{\"value\":[\(entries.joined(separator: ","))]\(tail)}")
    }

    private static func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "folder-tree@example.com", accessToken: { _ in "fake-graph-token" }, session: http.session)
    }

    /// An account with a stored folder `kept`, two headers in it and a queued move.
    private static func seed(_ id: String, pool: DatabasePool) async throws -> Account {
        let account = try FolderEpochTestFixture.makeAccount(id: id, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account.id, path: "kept", role: .custom, pool: pool, totalCount: 2)
        try FolderEpochTestFixture.insertHeaders(accountId: account.id, path: "kept", uids: [1, 2], pool: pool)
        try await pool.write { db in
            var op = PendingOperation(type: .move, messageIds: ["1"], accountId: account.id, folderPath: "kept", destinationPath: "destination")
            try op.insert(db)
        }
        return account
    }

    private static func expectSeedUnchanged(_ pool: DatabasePool) async throws {
        let state = try await pool.read { db in
            (try Folder.fetchAll(db), try MessageHeader.fetchAll(db), try PendingOperation.fetchAll(db))
        }
        #expect(state.0.map(\.path) == ["kept"], "the stored folders stay as they were")
        #expect(Set(state.1.map(\.messageId)) == ["1", "2"])
        #expect(state.1.allSatisfy { $0.folderPath == "kept" })
        #expect(state.2.count == 1 && state.2.first?.folderPath == "kept")
    }

    enum FailingPage: CaseIterable {
        /// The root listing's second page.
        case laterRootPage
        /// The first request for a folder's own subfolders.
        case firstFolderPage
        /// The second page of a folder's subfolders.
        case laterFolderPage
    }

    @Test("A complete listing reaches the stored folders and the move picker: a new subfolder is added, a known folder keeps its id, counts and backfill state, a stored search folder goes, and the mail and queued action stay")
    func aCompleteListingIsStored() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try FolderEpochTestFixture.makeAccount(id: "folder-tree-success", provider: .outlook, pool: pool)
        // `kept` is a known folder with mail and a finished backfill; `old-search` was stored as
        // a folder before search folders were left out, and a queued move names its mail.
        for (path, uid) in [("kept", 1), ("old-search", 2)] {
            try FolderEpochTestFixture.insertFolder(accountId: account.id, path: path, role: .custom, pool: pool)
            try FolderEpochTestFixture.insertHeaders(accountId: account.id, path: path, uids: [uid], pool: pool)
        }
        try await pool.write { db in
            var kept = try #require(try Folder.fetchOne(db, key: account.id + ":kept"))
            kept.backfillComplete = true
            kept.backfillPageToken = "backfill-cursor"
            try kept.update(db)
            var op = PendingOperation(type: .move, messageIds: ["2"], accountId: account.id, folderPath: "old-search", destinationPath: "kept")
            try op.insert(db)
        }
        let wellKnown = ["inbox", "sentitems", "drafts", "deleteditems", "junkemail", "archive"]
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: Self.root) { request in
            let path = request.url.path
            if path == Self.root {
                let system = wellKnown.map { "{\"id\":\"sys-\($0)\",\"displayName\":\"\($0)\",\"unreadItemCount\":0,\"totalItemCount\":0,\"childFolderCount\":0}" }
                return Self.page(system + [Self.folder("kept", children: 1), Self.searchFolder("old-search")])
            }
            if let name = wellKnown.first(where: { path == Self.root + "/" + $0 }) {
                return .json(raw: "{\"id\":\"sys-\(name)\",\"displayName\":\"\(name)\"}")
            }
            if wellKnown.contains(where: { path == Self.root + "/sys-" + $0 + "/messages" }) { return Self.page([]) }
            return .status(404)
        }
        http.register(path: Self.root + "/kept/childFolders", response: Self.page([Self.folder("new-child")]))

        try await SyncEngine().fullSync(account: account, provider: Self.provider(http))

        let state = try await pool.read { db in
            (try Folder.fetchAll(db), try MessageHeader.fetchAll(db), try PendingOperation.fetchAll(db))
        }
        let folders = state.0
        #expect(Set(folders.map(\.path)) == Set(wellKnown.map { "sys-" + $0 } + ["kept", "new-child"]),
                "the new subfolder is stored and the search folder is not: \(folders.map(\.path))")
        let kept = try #require(folders.first { $0.path == "kept" })
        #expect(kept.id == account.id + ":kept", "a known folder keeps its id")
        #expect(kept.totalCount == 7, "and takes the listing's count")
        #expect(kept.backfillComplete && kept.backfillPageToken == "backfill-cursor", "and keeps its backfill state")
        #expect(Set(state.1.map(\.messageId)) == ["1", "2"], "no stored mail is removed")
        #expect(state.2.count == 1 && state.2.first?.folderPath == "old-search" && state.2.first?.messageIds == ["2"]
                && state.2.first?.destinationPath == "kept", "the queued move stays as it was")
        let picker = MoveFolderPicker.partition(folders: folders, currentFolderPath: "kept")
        let offered = Set((picker.favorites + picker.others).map(\.path))
        #expect(offered.contains("new-child"), "the new subfolder can be picked as a move target")
        #expect(offered.isDisjoint(with: ["kept", "old-search"]))
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "listing writes nothing to the server")
    }

    @Test("A page that fails, at the root or inside a folder, first or after earlier pages, fails the whole sync and changes nothing stored",
          arguments: FailingPage.allCases)
    func aFailedPageChangesNothing(failing: FailingPage) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try await Self.seed("folder-tree-failure", pool: pool)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: Self.root) { request in
            guard request.url.path == Self.root else { return .status(404) }
            if request.url.query?.contains("failed") == true { return .status(503) }
            return Self.page([Self.folder("new-parent", children: 1)], next: failing == .laterRootPage ? Self.graph + "?$skiptoken=failed" : nil)
        }
        http.register(path: Self.root + "/new-parent/childFolders") { request in
            if failing == .firstFolderPage || request.url.query?.contains("failed") == true { return .status(503) }
            return Self.page([Self.folder("new-leaf")], next: failing == .laterFolderPage ? Self.graph + "/new-parent/childFolders?$skiptoken=failed" : nil)
        }
        do {
            try await SyncEngine().fullSync(account: account, provider: Self.provider(http))
            Issue.record("a listing with a failed page must not be stored as the whole folder list")
        } catch ProviderError.networkError { }
        let calls = http.recordedCalls().map(\.url)
        switch failing {
        case .laterRootPage, .laterFolderPage:
            #expect(calls.contains { $0.contains("failed") }, "the failing page was reached")
        case .firstFolderPage:
            #expect(!calls.contains { $0.contains("failed") })
        }
        if failing != .laterRootPage { #expect(calls.contains { $0.contains("new-parent/childFolders") }, "the folder's own listing was asked for") }
        try await Self.expectSeedUnchanged(pool)
    }

    @Test("A next-page link already followed, or a folder listed again below itself, ends the sync with an error, not a loop",
          arguments: [false, true])
    func aCycleEndsTheListing(folderInsideItself: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let account = try await Self.seed("folder-tree-cycle", pool: pool)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let requests = Mutex(0)
        let fuseHit = Mutex(false)
        // Counts the requests the cycle repeats; past the fuse the server fails them.
        let repeated: @Sendable () -> Bool = {
            let n = requests.withLock { $0 += 1; return $0 }
            guard n >= Self.fuse else { return false }
            fuseHit.withLock { $0 = true }
            return true
        }
        if folderInsideItself {
            http.register(path: Self.root) { request in
                request.url.path == Self.root ? Self.page([Self.folder("self-parent", children: 1)]) : .status(404)
            }
            http.register(path: Self.root + "/self-parent/childFolders") { _ in
                repeated() ? .status(503) : Self.page([Self.folder("self-parent", children: 1)])
            }
        } else {
            let link = Self.graph + "?$skiptoken=repeat"
            http.register(path: Self.root) { request in
                guard request.url.path == Self.root else { return .status(404) }
                if request.url.query?.contains("repeat") == true, repeated() { return .status(503) }
                return Self.page(request.url.query?.contains("repeat") == true ? [] : [Self.folder("first")], next: link)
            }
        }
        let provider = Self.provider(http)
        let queue = ProviderWorkQueue(provider: provider, maxConcurrency: 1)
        let engine = SyncEngine()
        await engine.register(accountId: account.id, provider: provider, workQueue: queue)
        do {
            _ = try await engine.sync(account: account)
            Issue.record("a listing with a cycle must not be stored as the whole folder list")
        } catch {
            #expect(error is ExchangeProvider.GraphFolderTreeCycle, "\(error)")
        }
        #expect(requests.withLock { $0 } > 0, "the cycle was reached")
        #expect(!fuseHit.withLock { $0 }, "the cycle was requested \(requests.withLock { $0 }) times and ended only at the server's fuse")
        #expect(await queue.activeOperations == 0)
        try await Self.expectSeedUnchanged(pool)
    }
}
