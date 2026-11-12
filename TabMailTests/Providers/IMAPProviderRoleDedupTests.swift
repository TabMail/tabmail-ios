/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

// Verifies the role-detection + dedup logic that prevents iCloud's "Trash" +
// "Deleted Messages" pair (and similar legacy/modern aliases) from both
// inheriting `.trash`. The runtime path lives in `IMAPProvider.fetchFolders`;
// the migration path mirrors the same canonical-name preference but without
// access to SPECIAL-USE attributes.

private typealias Attrs = Mailbox.Info.Attributes

private func info(_ name: String, role: FolderRole = .custom) -> FolderInfo {
    FolderInfo(name: name, path: name, role: role, unreadCount: 0, totalCount: 0)
}

@Suite("IMAPProvider.mapRole")
struct MapRoleTests {

    @Test("SPECIAL-USE \\Trash beats name heuristic")
    func specialUseTrashWins() {
        let role = IMAPProvider.mapRole(attributes: [.trash], name: "Anything", delimiter: nil)
        #expect(role == .trash)
    }

    @Test("Name heuristic catches Trash without SPECIAL-USE")
    func nameTrash() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Trash", delimiter: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Messages", delimiter: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Items", delimiter: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Bin", delimiter: nil) == .trash)
    }

    @Test("Name heuristic is case-insensitive")
    func caseInsensitive() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "TRASH", delimiter: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "deleted messages", delimiter: nil) == .trash)
    }

    @Test("INBOX always wins")
    func inbox() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX", delimiter: nil) == .inbox)
        #expect(IMAPProvider.mapRole(attributes: [.inbox], name: "Whatever", delimiter: nil) == .inbox)
    }

    @Test("Custom folder returns .custom")
    func customFolder() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Receipts", delimiter: nil) == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Family", delimiter: nil) == .custom)
    }

    @Test("Drafts/Sent/Archive/Spam name fallback")
    func otherRoles() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Drafts", delimiter: nil) == .drafts)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Sent Messages", delimiter: nil) == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Archive", delimiter: nil) == .archive)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Junk", delimiter: nil) == .spam)
    }

    @Test("Name fallback matches the leaf after the server's delimiter")
    func leafMatch() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Sent", delimiter: ".") == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX/Sent Items", delimiter: "/") == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Trash", delimiter: ".") == .trash)
        // Without the delimiter the whole name is the leaf.
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Sent", delimiter: nil) == .custom)
        // A delimiter that is not in the name leaves the whole name.
        #expect(IMAPProvider.mapRole(attributes: [], name: "Sent", delimiter: "/") == .sent)
    }

    @Test("INBOX matches only as the whole name, never as a leaf")
    func inboxOnlyWholeName() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Old/INBOX", delimiter: "/") == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX", delimiter: "/") == .inbox)
    }

    @Test("leafName takes the last segment")
    func leafName() {
        #expect(IMAPProvider.leafName("INBOX.Clients.Sent", delimiter: ".") == "Sent")
        #expect(IMAPProvider.leafName("Sent", delimiter: ".") == "Sent")
        #expect(IMAPProvider.leafName("A/B", delimiter: nil) == "A/B")
        #expect(IMAPProvider.leafName("A/B", delimiter: "") == "A/B")
    }
}

@Suite("IMAPProvider.mergeSpecialUseAttributes")
struct MergeSpecialUseAttributesTests {

    @Test("RETURN (SPECIAL-USE) attributes are added to the plain entry of the same name")
    func mergesByName() {
        let plain = [
            Mailbox.Info(name: "INBOX", attributes: [], hierarchyDelimiter: "/"),
            Mailbox.Info(name: "Envoyes", attributes: [], hierarchyDelimiter: "/"),
            Mailbox.Info(name: "Projects", attributes: [], hierarchyDelimiter: "/"),
        ]
        let special = [
            Mailbox.Info(name: "Envoyes", attributes: [.sent], hierarchyDelimiter: "/"),
            Mailbox.Info(name: "Elsewhere", attributes: [.trash], hierarchyDelimiter: "/"),
        ]
        let merged = IMAPProvider.mergeSpecialUseAttributes(into: plain, from: special)
        #expect(merged.map(\.name) == ["INBOX", "Envoyes", "Projects"],
                "the plain listing stays the folder list; a special-only name is not added")
        #expect(merged.first { $0.name == "Envoyes" }?.attributes.contains(.sent) == true)
        #expect(merged.first { $0.name == "Envoyes" }?.hierarchyDelimiter == "/")
        #expect(merged.first { $0.name == "Projects" }?.attributes.isEmpty == true)
    }
}

@Suite("IMAPProvider.canonicalNameRank")
struct CanonicalNameRankTests {

    @Test("Canonical primary name has rank 0")
    func primary() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .trash, delimiter: nil) == 0)
        #expect(IMAPProvider.canonicalNameRank("Sent", role: .sent, delimiter: nil) == 0)
    }

    @Test("Legacy alias has higher rank")
    func legacyAlias() {
        let trashRank = IMAPProvider.canonicalNameRank("Trash", role: .trash, delimiter: nil)
        let deletedRank = IMAPProvider.canonicalNameRank("Deleted Messages", role: .trash, delimiter: nil)
        #expect(trashRank < deletedRank)
    }

    @Test("Unknown name returns Int.max")
    func unknown() {
        #expect(IMAPProvider.canonicalNameRank("Garbage", role: .trash, delimiter: nil) == .max)
    }

    @Test("Rank uses the leaf; INBOX ranks only as the whole name")
    func leafRank() {
        #expect(IMAPProvider.canonicalNameRank("INBOX.Sent Items", role: .sent, delimiter: ".") == 2)
        #expect(IMAPProvider.canonicalNameRank("INBOX.Sent Items", role: .sent, delimiter: nil) == .max)
        #expect(IMAPProvider.canonicalNameRank("Old/INBOX", role: .inbox, delimiter: "/") == .max)
    }

    @Test("Mismatched role returns Int.max")
    func wrongRole() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .sent, delimiter: nil) == .max)
    }
}

@Suite("IMAPProvider.dedupRoles")
struct DedupRolesTests {

    @Test("iCloud Trash + Deleted Messages — Trash wins on canonical name")
    func iCloudPair() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX", role: .inbox), [], nil),
            (info("Trash", role: .trash), [], nil),
            (info("Deleted Messages", role: .trash), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        let trashFolders = result.filter { $0.role == .trash }.map(\.name)
        let customFolders = result.filter { $0.role == .custom }.map(\.name)
        #expect(trashFolders == ["Trash"])
        #expect(customFolders == ["Deleted Messages"])
    }

    @Test("SPECIAL-USE flag wins over canonical name preference")
    func specialUseBeatsName() {
        // Hypothetical server: "Deleted Messages" carries `\Trash` flag,
        // bare "Trash" is just a custom folder named "Trash". The flag wins.
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Trash", role: .trash), [], nil),
            (info("Deleted Messages", role: .trash), [.trash], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        let trashFolders = result.filter { $0.role == .trash }.map(\.name)
        #expect(trashFolders == ["Deleted Messages"])
    }

    @Test("Both have SPECIAL-USE — fall back to canonical name")
    func bothHaveAttribute() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Deleted Messages", role: .trash), [.trash], nil),
            (info("Trash", role: .trash), [.trash], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.first { $0.role == .trash }?.name == "Trash")
    }

    @Test("Single folder per role — no demotion")
    func noDuplicates() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX", role: .inbox), [.inbox], nil),
            (info("Trash", role: .trash), [.trash], nil),
            (info("Sent", role: .sent), [.sent], nil),
            (info("Receipts", role: .custom), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.count == 4)
        #expect(result.first { $0.name == "Trash" }?.role == .trash)
        #expect(result.first { $0.name == "Receipts" }?.role == .custom)
    }

    @Test("Multiple .custom folders are not deduped")
    func customNotDeduped() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Receipts", role: .custom), [], nil),
            (info("Travel", role: .custom), [], nil),
            (info("Family", role: .custom), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.filter { $0.role == .custom }.count == 3)
    }

    @Test("Sent + Sent Messages — Sent wins")
    func sentDedup() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Sent Messages", role: .sent), [], nil),
            (info("Sent", role: .sent), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.first { $0.role == .sent }?.name == "Sent")
    }

    @Test("Nested Sent folders under INBOX — the canonical leaf wins")
    func nestedLeafRank() {
        // Same leaf rank decides before name length: "Sent Items" (rank 2)
        // beats "Sent Mail" (rank 3) although its full name is longer.
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX.Sent Mail", role: .sent), [], "."),
            (info("INBOX.Sent Items", role: .sent), [], ".")
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.first { $0.role == .sent }?.name == "INBOX.Sent Items")
    }

    @Test("Original order preserved")
    func ordering() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX", role: .inbox), [], nil),
            (info("Trash", role: .trash), [], nil),
            (info("Sent", role: .sent), [], nil),
            (info("Deleted Messages", role: .trash), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.map(\.name) == ["INBOX", "Trash", "Sent", "Deleted Messages"])
    }
}
