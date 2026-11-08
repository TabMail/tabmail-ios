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

    /// Six folders under the root (three pages), one of them hidden, an Inbox
    /// with three children (two pages), a branch four levels deep, and a hidden
    /// folder below a visible one.
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
        ]),
        Node("f-sent", "Sent Items"),
        Node("f-projects", "Projects", [
            Node("f-launch", "Launch"),
        ]),
        Node("f-digest", "Weekly digests", search: true),
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

    @Test("Every real folder at every depth and on every page, hidden ones included, is listed once with its own counts; search folders are not")
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
        let listedIds = folders.map(\.path)
        #expect(listedIds.count == Set(listedIds).count, "a folder was listed twice: \(listedIds)")
        #expect(Set(listedIds) == Set(realFolders.map(\.id)))
        #expect(!listedIds.contains("f-digest"))

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
/// the account's whole folder table. So a listing that cannot finish must fail as a
/// whole, through the real sync path, and leave the stored folders, headers and
/// queued actions as they were; a later sync lists the tree again.
@Suite("ExchangeProvider — folder tree failures", .serialized, .processGlobalState)
struct ExchangeFolderTreeFailureTests {
    private static let root = "/v1.0/me/mailFolders"
    private static let graph = "https://graph.microsoft.com/v1.0/me/mailFolders"
    /// Stops a server that would otherwise answer forever, so a walker with no
    /// end of its own fails the test instead of hanging it.
    private static let fuse = 32

    private static func folder(_ id: String, children: Int = 0) -> String {
        "{\"id\":\"\(id)\",\"displayName\":\"\(id)\",\"unreadItemCount\":2,\"totalItemCount\":7,\"childFolderCount\":\(children)}"
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

    @Test("A page that fails after earlier pages, at the root or inside a folder, fails the whole sync and changes nothing stored",
          arguments: [false, true])
    func aFailedPageChangesNothing(insideAFolder: Bool) async throws {
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
            return Self.page([Self.folder("new-parent", children: 1)], next: insideAFolder ? nil : Self.graph + "?$skiptoken=failed")
        }
        http.register(path: Self.root + "/new-parent/childFolders") { request in
            if request.url.query?.contains("failed") == true { return .status(503) }
            return Self.page([Self.folder("new-leaf")], next: insideAFolder ? Self.graph + "/new-parent/childFolders?$skiptoken=failed" : nil)
        }
        do {
            try await SyncEngine().fullSync(account: account, provider: Self.provider(http))
            Issue.record("a listing with a failed page must not be stored as the whole folder list")
        } catch ProviderError.networkError { }
        let calls = http.recordedCalls().map(\.url)
        #expect(calls.contains { $0.contains("failed") }, "the failing page was reached")
        if insideAFolder { #expect(calls.contains { $0.contains("new-parent/childFolders") }) }
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
