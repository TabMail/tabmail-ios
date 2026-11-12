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
        let role = IMAPProvider.mapRole(attributes: [.trash], name: "Anything", delimiter: nil, namespacePrefix: nil)
        #expect(role == .trash)
    }

    @Test("Name heuristic catches Trash without SPECIAL-USE")
    func nameTrash() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Trash", delimiter: nil, namespacePrefix: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Messages", delimiter: nil, namespacePrefix: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Deleted Items", delimiter: nil, namespacePrefix: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Bin", delimiter: nil, namespacePrefix: nil) == .trash)
    }

    @Test("Name heuristic is case-insensitive")
    func caseInsensitive() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "TRASH", delimiter: nil, namespacePrefix: nil) == .trash)
        #expect(IMAPProvider.mapRole(attributes: [], name: "deleted messages", delimiter: nil, namespacePrefix: nil) == .trash)
    }

    @Test("INBOX always wins")
    func inbox() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX", delimiter: nil, namespacePrefix: nil) == .inbox)
        #expect(IMAPProvider.mapRole(attributes: [.inbox], name: "Whatever", delimiter: nil, namespacePrefix: nil) == .inbox)
    }

    @Test("Custom folder returns .custom")
    func customFolder() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Receipts", delimiter: nil, namespacePrefix: nil) == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Family", delimiter: nil, namespacePrefix: nil) == .custom)
    }

    @Test("Drafts/Sent/Archive/Spam name fallback")
    func otherRoles() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Drafts", delimiter: nil, namespacePrefix: nil) == .drafts)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Sent Messages", delimiter: nil, namespacePrefix: nil) == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Archive", delimiter: nil, namespacePrefix: nil) == .archive)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Junk", delimiter: nil, namespacePrefix: nil) == .spam)
    }

    @Test("Name fallback matches a folder directly under INBOX")
    func inboxParentMatch() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Sent", delimiter: ".", namespacePrefix: nil) == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX/Sent Items", delimiter: "/", namespacePrefix: nil) == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "inbox.Trash", delimiter: ".", namespacePrefix: nil) == .trash)
        // Without the delimiter the whole name is compared.
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Sent", delimiter: nil, namespacePrefix: nil) == .custom)
        // A delimiter that is not in the name leaves the whole name.
        #expect(IMAPProvider.mapRole(attributes: [], name: "Sent", delimiter: "/", namespacePrefix: nil) == .sent)
    }

    @Test("Name fallback matches a folder directly under the personal-namespace prefix")
    func namespacePrefixMatch() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Mail/Sent", delimiter: "/", namespacePrefix: "Mail/") == .sent)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Mail/Sent", delimiter: "/", namespacePrefix: nil) == .custom)
    }

    @Test("A role name nested under a user folder is an ordinary folder")
    func nestedUnderUserFolderIsCustom() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Clients/Sent", delimiter: "/", namespacePrefix: nil) == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Projects/Trash", delimiter: "/", namespacePrefix: "") == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "Work/Archive", delimiter: "/", namespacePrefix: nil) == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX.Clients.Sent", delimiter: ".", namespacePrefix: "INBOX.") == .custom)
        // The special-use attribute still decides, wherever the folder is.
        #expect(IMAPProvider.mapRole(attributes: [.sent], name: "Clients/Sent", delimiter: "/", namespacePrefix: nil) == .sent)
    }

    @Test("INBOX matches only as the whole name, never nested")
    func inboxOnlyWholeName() {
        #expect(IMAPProvider.mapRole(attributes: [], name: "Old/INBOX", delimiter: "/", namespacePrefix: nil) == .custom)
        #expect(IMAPProvider.mapRole(attributes: [], name: "INBOX", delimiter: "/", namespacePrefix: nil) == .inbox)
    }

    @Test("roleMatchName strips only a leading INBOX parent or the namespace prefix")
    func roleMatchName() {
        #expect(IMAPProvider.roleMatchName("INBOX.Sent", delimiter: ".", namespacePrefix: nil) == "Sent")
        #expect(IMAPProvider.roleMatchName("Inbox/Sent Items", delimiter: "/", namespacePrefix: nil) == "Sent Items")
        #expect(IMAPProvider.roleMatchName("INBOX.Clients.Sent", delimiter: ".", namespacePrefix: nil) == "Clients.Sent")
        #expect(IMAPProvider.roleMatchName("Clients/Sent", delimiter: "/", namespacePrefix: nil) == "Clients/Sent")
        #expect(IMAPProvider.roleMatchName("Mail/Sent", delimiter: "/", namespacePrefix: "Mail/") == "Sent")
        // INBOX itself, or the bare prefix, is returned whole.
        #expect(IMAPProvider.roleMatchName("INBOX", delimiter: ".", namespacePrefix: "INBOX.") == "INBOX")
        #expect(IMAPProvider.roleMatchName("INBOX.", delimiter: ".", namespacePrefix: nil) == "INBOX.")
        #expect(IMAPProvider.roleMatchName("A/B", delimiter: nil, namespacePrefix: nil) == "A/B")
        #expect(IMAPProvider.roleMatchName("A/B", delimiter: "", namespacePrefix: "") == "A/B")
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

    @Test("Plain and special-use attributes of one folder are united, not replaced")
    func keepsPlainAttributes() {
        let plain = [Mailbox.Info(name: "Envoyes", attributes: [.hasNoChildren], hierarchyDelimiter: "/")]
        let special = [Mailbox.Info(name: "Envoyes", attributes: [.sent], hierarchyDelimiter: "/")]
        let merged = IMAPProvider.mergeSpecialUseAttributes(into: plain, from: special)
        guard merged.count == 1 else { Issue.record("expected one folder, got \(merged.count)"); return }
        #expect(merged[0].attributes.contains(.sent))
        #expect(merged[0].attributes.contains(.hasNoChildren))
    }
}

@Suite("IMAPProvider.canonicalNameRank")
struct CanonicalNameRankTests {

    @Test("Canonical primary name has rank 0")
    func primary() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .trash, delimiter: nil, namespacePrefix: nil) == 0)
        #expect(IMAPProvider.canonicalNameRank("Sent", role: .sent, delimiter: nil, namespacePrefix: nil) == 0)
    }

    @Test("Legacy alias has higher rank")
    func legacyAlias() {
        let trashRank = IMAPProvider.canonicalNameRank("Trash", role: .trash, delimiter: nil, namespacePrefix: nil)
        let deletedRank = IMAPProvider.canonicalNameRank("Deleted Messages", role: .trash, delimiter: nil, namespacePrefix: nil)
        #expect(trashRank < deletedRank)
    }

    @Test("Unknown name returns Int.max")
    func unknown() {
        #expect(IMAPProvider.canonicalNameRank("Garbage", role: .trash, delimiter: nil, namespacePrefix: nil) == .max)
    }

    @Test("Rank uses the name under INBOX or the namespace prefix; INBOX ranks only as the whole name")
    func inboxParentRank() {
        #expect(IMAPProvider.canonicalNameRank("INBOX.Sent Items", role: .sent, delimiter: ".", namespacePrefix: nil) == 2)
        #expect(IMAPProvider.canonicalNameRank("INBOX.Sent Items", role: .sent, delimiter: nil, namespacePrefix: nil) == .max)
        #expect(IMAPProvider.canonicalNameRank("Mail/Sent", role: .sent, delimiter: "/", namespacePrefix: "Mail/") == 0)
        #expect(IMAPProvider.canonicalNameRank("Clients/Sent", role: .sent, delimiter: "/", namespacePrefix: nil) == .max)
        #expect(IMAPProvider.canonicalNameRank("Old/INBOX", role: .inbox, delimiter: "/", namespacePrefix: nil) == .max)
    }

    @Test("Mismatched role returns Int.max")
    func wrongRole() {
        #expect(IMAPProvider.canonicalNameRank("Trash", role: .sent, delimiter: nil, namespacePrefix: nil) == .max)
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
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
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
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        let trashFolders = result.filter { $0.role == .trash }.map(\.name)
        #expect(trashFolders == ["Deleted Messages"])
    }

    @Test("Both have SPECIAL-USE — fall back to canonical name")
    func bothHaveAttribute() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Deleted Messages", role: .trash), [.trash], nil),
            (info("Trash", role: .trash), [.trash], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
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
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
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
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        #expect(result.filter { $0.role == .custom }.count == 3)
    }

    @Test("Sent + Sent Messages — Sent wins")
    func sentDedup() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Sent Messages", role: .sent), [], nil),
            (info("Sent", role: .sent), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        #expect(result.first { $0.role == .sent }?.name == "Sent")
    }

    @Test("Sent folders under INBOX — the canonical name wins")
    func nestedLeafRank() {
        // The rank under INBOX decides before name length: "Sent Items" (rank 2)
        // beats "Sent Mail" (rank 3) although its full name is longer.
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX.Sent Mail", role: .sent), [], "."),
            (info("INBOX.Sent Items", role: .sent), [], ".")
        ]
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        #expect(result.first { $0.role == .sent }?.name == "INBOX.Sent Items")
    }

    @Test("A folder nested under a user folder never outranks a top-level alias")
    func nestedUserFolderLosesToTopLevelAlias() {
        // Both carry the role here (as if both had matched by name): the nested
        // one ranks as its whole name (unknown), so the top-level alias wins.
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("Clients/Sent", role: .sent), [], "/"),
            (info("Sent Messages", role: .sent), [], "/"),
            (info("Projects/Trash", role: .trash), [], "/"),
            (info("Deleted Items", role: .trash), [], "/"),
        ]
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        #expect(result.filter { $0.role == .sent }.map(\.name) == ["Sent Messages"])
        #expect(result.filter { $0.role == .trash }.map(\.name) == ["Deleted Items"])
    }

    @Test("Original order preserved")
    func ordering() {
        let pairs: [(info: FolderInfo, attributes: Attrs, delimiter: String?)] = [
            (info("INBOX", role: .inbox), [], nil),
            (info("Trash", role: .trash), [], nil),
            (info("Sent", role: .sent), [], nil),
            (info("Deleted Messages", role: .trash), [], nil)
        ]
        let result = IMAPProvider.dedupRoles(pairs, namespacePrefix: nil)
        #expect(result.map(\.name) == ["INBOX", "Trash", "Sent", "Deleted Messages"])
    }
}
