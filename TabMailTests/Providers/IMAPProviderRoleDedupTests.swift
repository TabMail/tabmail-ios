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
        let role = IMAPProvider.mapRole(attributes: [.trash], name: "Anything")
        #expect(role == .trash)
    }

    @Test("Name heuristic catches Trash without SPECIAL-USE")
    func nameTrash() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Trash") == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Messages") == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Items") == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Bin") == .trash)
    }

    @Test("Name heuristic is case-insensitive")
    func caseInsensitive() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "TRASH") == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "deleted messages") == .trash)
    }

    @Test("INBOX always wins")
    func inbox() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX") == .inbox)
        #expect(IMAPProvider.mapRole(attributes: [.inbox], name: "Whatever") == .inbox)
    }

    @Test("Custom folder returns .custom")
    func customFolder() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Receipts") == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Family") == .custom)
    }

    @Test("Drafts/Sent/Archive/Spam name fallback")
    func otherRoles() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Drafts") == .drafts)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Sent Messages") == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Archive") == .archive)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Junk") == .spam)
    }
}

@Suite("IMAPProvider.canonicalNameRank")
struct CanonicalNameRankTests {

    @Test("Canonical primary name has rank 0")
    func primary() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .trash) == 0)
        #expect(IMAPProvider.canonicalNameRank("Sent", role: .sent) == 0)
    }

    @Test("Legacy alias has higher rank")
    func legacyAlias() {
        let trashRank = IMAPProvider.canonicalNameRank("Trash", role: .trash)
        let deletedRank = IMAPProvider.canonicalNameRank("Deleted Messages", role: .trash)
        #expect(trashRank < deletedRank)
    }

    @Test("Unknown name returns Int.max")
    func unknown() {
        #expect(IMAPProvider.canonicalNameRank("Garbage", role: .trash) == .max)
    }

    @Test("Mismatched role returns Int.max")
    func wrongRole() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .sent) == .max)
    }
}

@Suite("IMAPProvider.dedupRoles")
struct DedupRolesTests {

    @Test("iCloud Trash + Deleted Messages — Trash wins on canonical name")
    func iCloudPair() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("INBOX", role: .inbox), []),
            (info("Trash", role: .trash), []),
            (info("Deleted Messages", role: .trash), [])
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
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("Trash", role: .trash), []),
            (info("Deleted Messages", role: .trash), [.trash])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        let trashFolders = result.filter { $0.role == .trash }.map(\.name)
        #expect(trashFolders == ["Deleted Messages"])
    }

    @Test("Both have SPECIAL-USE — fall back to canonical name")
    func bothHaveAttribute() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("Deleted Messages", role: .trash), [.trash]),
            (info("Trash", role: .trash), [.trash])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.first { $0.role == .trash }?.name == "Trash")
    }

    @Test("Single folder per role — no demotion")
    func noDuplicates() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("INBOX", role: .inbox), [.inbox]),
            (info("Trash", role: .trash), [.trash]),
            (info("Sent", role: .sent), [.sent]),
            (info("Receipts", role: .custom), [])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.count == 4)
        #expect(result.first { $0.name == "Trash" }?.role == .trash)
        #expect(result.first { $0.name == "Receipts" }?.role == .custom)
    }

    @Test("Multiple .custom folders are not deduped")
    func customNotDeduped() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("Receipts", role: .custom), []),
            (info("Travel", role: .custom), []),
            (info("Family", role: .custom), [])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.filter { $0.role == .custom }.count == 3)
    }

    @Test("Sent + Sent Messages — Sent wins")
    func sentDedup() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("Sent Messages", role: .sent), []),
            (info("Sent", role: .sent), [])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.first { $0.role == .sent }?.name == "Sent")
    }

    @Test("Original order preserved")
    func ordering() {
        let pairs: [(info: FolderInfo, attributes: Attrs)] = [
            (info("INBOX", role: .inbox), []),
            (info("Trash", role: .trash), []),
            (info("Sent", role: .sent), []),
            (info("Deleted Messages", role: .trash), [])
        ]
        let result = IMAPProvider.dedupRoles(pairs)
        #expect(result.map(\.name) == ["INBOX", "Trash", "Sent", "Deleted Messages"])
    }
}
