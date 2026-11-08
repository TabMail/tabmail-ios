/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
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
///   over messages that live in real folders, not a place mail can be filed.
@Suite("ExchangeProvider — whole folder tree")
struct ExchangeFolderTreeTests {
    private struct Node {
        let id: String
        let name: String
        let isSearchFolder: Bool
        let children: [Node]

        init(_ id: String, _ name: String, search: Bool = false, _ children: [Node] = []) {
            self.id = id
            self.name = name
            self.isSearchFolder = search
            self.children = children
        }

        var subtree: [Node] { [self] + children.flatMap(\.subtree) }
    }

    /// Five folders under the root (three pages), an Inbox with three children
    /// (two pages), and a branch four levels deep.
    private static let rootChildren: [Node] = [
        Node("f-inbox", "Inbox", [
            Node("f-clients", "Clients", [
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
    ]

    /// Smaller than both `$top` values the app sends, so every listing with
    /// more than this many folders needs `@odata.nextLink`.
    private static let pageSize = 2
    private static let graphBase = "https://graph.microsoft.com/v1.0/me"

    private static func folderJSON(_ node: Node) -> String {
        let type = node.isSearchFolder
            ? "\"@odata.type\": \"#microsoft.graph.mailSearchFolder\", "
            : ""
        return """
        {\(type)"id": "\(node.id)", "displayName": "\(node.name)", \
        "unreadItemCount": 0, "totalItemCount": 0, "childFolderCount": \(node.children.count)}
        """
    }

    /// One page of `children`, starting at the `$skiptoken` the request carries.
    private static func page(of children: [Node], listingPath: String, url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = items.first { $0.name == "$skiptoken" }.flatMap { Int($0.value ?? "") } ?? 0
        let end = min(start + pageSize, children.count)
        let values = children[start..<end].map(folderJSON).joined(separator: ", ")
        let next = end < children.count
            ? ", \"@odata.nextLink\": \"\(graphBase)\(listingPath)?$skiptoken=\(end)\""
            : ""
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

    @Test("Every real folder at every depth and on every page is listed once; search folders are not")
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
        }
        #expect(byId["f-inbox"]?.role == .inbox)
        #expect(byId["f-sent"]?.role == .sent)
        #expect(byId["f-acme-contracts"]?.role == .custom)
    }
}
