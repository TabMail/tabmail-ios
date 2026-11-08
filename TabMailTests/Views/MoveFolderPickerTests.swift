/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MoveFolderPicker.partition")
struct MoveFolderPickerTests {

    private func makeFolder(_ name: String, path: String, role: FolderRole, accountId: String = "a1", isFavorite: Bool = false) -> Folder {
        var f = Folder(name: name, path: path, role: role, accountId: accountId)
        f.isFavorite = isFavorite
        return f
    }

    @Test("Excludes the current folder path")
    func excludesCurrent() {
        let folders = [
            makeFolder("Inbox", path: "INBOX", role: .inbox),
            makeFolder("Sent", path: "SENT", role: .sent)
        ]
        let result = MoveFolderPicker.partition(folders: folders, currentFolderPath: "INBOX", provider: .imap)
        #expect(result.favorites.isEmpty)
        #expect(result.others.map(\.path) == ["SENT"])
    }

    @Test("No favorites → all rows in `others`, sorted by role")
    func noFavoritesSortedByRole() {
        let folders = [
            makeFolder("Spam", path: "SPAM", role: .spam),
            makeFolder("Custom", path: "CUSTOM", role: .custom),
            makeFolder("Inbox", path: "INBOX", role: .inbox),
            makeFolder("Trash", path: "TRASH", role: .trash),
            makeFolder("Sent", path: "SENT", role: .sent),
            makeFolder("Archive", path: "ARCHIVE", role: .archive),
            makeFolder("Drafts", path: "DRAFTS", role: .drafts)
        ]
        let result = MoveFolderPicker.partition(folders: folders, currentFolderPath: "", provider: .imap)
        #expect(result.favorites.isEmpty)
        // Role order: inbox, archive, sent, drafts, trash, spam, custom
        #expect(result.others.map(\.path) == ["INBOX", "ARCHIVE", "SENT", "DRAFTS", "TRASH", "SPAM", "CUSTOM"])
    }

    @Test("Favorites are split out and ordered by role within their group")
    func favoritesPartitioned() {
        let folders = [
            makeFolder("Inbox", path: "INBOX", role: .inbox),
            makeFolder("Sent", path: "SENT", role: .sent),
            makeFolder("Drafts", path: "DRAFTS", role: .drafts),
            makeFolder("ProjectX", path: "ProjectX", role: .custom, isFavorite: true),
            makeFolder("Archive", path: "ARCHIVE", role: .archive, isFavorite: true)
        ]
        let result = MoveFolderPicker.partition(folders: folders, currentFolderPath: "", provider: .imap)
        guard result.favorites.count == 2 else {
            Issue.record("Expected 2 favorites, got \(result.favorites.count)")
            return
        }
        // Within favorites: archive (1) before custom (6)
        #expect(result.favorites.map(\.path) == ["ARCHIVE", "ProjectX"])
        // Others retain role order, with no favorites mixed in
        #expect(result.others.map(\.path) == ["INBOX", "SENT", "DRAFTS"])
    }

    @Test("Current folder is excluded even if favorite")
    func favoriteCurrentExcluded() {
        let folders = [
            makeFolder("ProjectX", path: "ProjectX", role: .custom, isFavorite: true),
            makeFolder("Inbox", path: "INBOX", role: .inbox)
        ]
        let result = MoveFolderPicker.partition(folders: folders, currentFolderPath: "ProjectX", provider: .imap)
        #expect(result.favorites.isEmpty)
        #expect(result.others.map(\.path) == ["INBOX"])
    }

    @Test("All favorites → others is empty")
    func allFavorites() {
        let folders = [
            makeFolder("Inbox", path: "INBOX", role: .inbox, isFavorite: true),
            makeFolder("Sent", path: "SENT", role: .sent, isFavorite: true)
        ]
        let result = MoveFolderPicker.partition(folders: folders, currentFolderPath: "", provider: .imap)
        #expect(result.favorites.map(\.path) == ["INBOX", "SENT"])
        #expect(result.others.isEmpty)
    }

    @Test("Empty input → empty partitions")
    func emptyInput() {
        let result = MoveFolderPicker.partition(folders: [], currentFolderPath: "", provider: .imap)
        #expect(result.favorites.isEmpty)
        #expect(result.others.isEmpty)
    }

    @Test("On Gmail, Sent and Drafts are never offered as a destination; elsewhere they are")
    func gmailOmitsTheLabelsGmailKeeps() {
        let folders = [
            makeFolder("Inbox", path: "INBOX", role: .inbox),
            makeFolder("Sent", path: "SENT", role: .sent),
            makeFolder("Drafts", path: "DRAFT", role: .drafts),
            makeFolder("Trash", path: "TRASH", role: .trash),
            makeFolder("Projects", path: "Label_7", role: .custom, isFavorite: true),
        ]
        let gmail = MoveFolderPicker.partition(folders: folders, currentFolderPath: "INBOX", provider: .gmail)
        #expect((gmail.favorites + gmail.others).map(\.path) == ["Label_7", "TRASH"])
        let imap = MoveFolderPicker.partition(folders: folders, currentFolderPath: "INBOX", provider: .imap)
        #expect((imap.favorites + imap.others).map(\.path) == ["Label_7", "SENT", "DRAFT", "TRASH"])
    }

    @Test("folderOrder produces the documented role ordering")
    func roleOrdering() {
        let order: [FolderRole] = [.inbox, .archive, .sent, .drafts, .trash, .spam, .custom]
        let mapped = order.map { MoveFolderPicker.folderOrder($0) }
        #expect(mapped == [0, 1, 2, 3, 4, 5, 6])
    }

    /// The picker reads each account's own provider from the database: a Gmail
    /// account's picker hides Sent and Drafts (Gmail keeps those labels itself,
    /// and a move into them is refused), while another account with folders at
    /// the same paths keeps them.
    @Test("The picker hides Sent and Drafts for a Gmail account read from the database, and only for it")
    func loadReadsTheAccountsProvider() throws {
        let db = try TestDatabase.make()
        let paths = ["INBOX", "SENT", "DRAFT", "TRASH", "Label_7"]
        let roles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .custom]
        for (accountId, provider) in [("picker-gmail", AccountProvider.gmail), ("picker-imap", AccountProvider.imap)] {
            try TestDatabase.insertAccount(db, id: accountId, email: "\(accountId)@example.com", provider: provider)
            try db.write { database in
                for (path, role) in zip(paths, roles) {
                    try Folder(name: path, path: path, role: role, accountId: accountId).insert(database)
                }
            }
        }

        let gmail = try db.read { try MoveFolderPicker.load(accountId: "picker-gmail", currentFolderPath: "INBOX", db: $0) }
        let imap = try db.read { try MoveFolderPicker.load(accountId: "picker-imap", currentFolderPath: "INBOX", db: $0) }

        let gmailPaths = Set((gmail.favorites + gmail.others).map(\.path))
        let imapPaths = Set((imap.favorites + imap.others).map(\.path))
        #expect(gmailPaths == ["TRASH", "Label_7"], "Gmail picker offered \(gmailPaths.sorted())")
        #expect(imapPaths == ["SENT", "DRAFT", "TRASH", "Label_7"], "IMAP picker offered \(imapPaths.sorted())")
    }
}
