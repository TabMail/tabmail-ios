/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Folder role changes go through `FolderRoleEdit`, which marks the account's full
/// sync due when the Inbox moves to another folder, so the full sync takes the new
/// Inbox's state and delta cursor. A role written anywhere else would move the
/// Inbox without that, so this scans the app target's source for SQL that sets
/// `folder.role`.
///
/// The Settings screen's three role edits (`AccountDetailView.setFolderRole`,
/// `assignRole`, `clearRole`) are the production callers; a view is not run in
/// tests, so this fence is what keeps them on `FolderRoleEdit`.
@Suite("Folder roles are changed only through FolderRoleEdit")
struct FolderRoleWriterFenceTests {
    /// SQL that sets a folder's role, as a raw statement or a GRDB column assignment.
    static var roleWrite: Regex<AnyRegexOutput> {
        try! Regex(#"(?i)UPDATE\s+folder\s+SET\s+role\b|Column\("role"\)\.set\("#)
    }

    /// Each file allowed to set roles, with how many such writes it holds. The
    /// migration is frozen (it ran on every installed database), so its count stays.
    static let allowed: [String: Int] = [
        "TabMail/Models/FolderRoleEdit.swift": 4,
        "TabMail/Services/AppDatabase.swift": 1,
    ]

    @Test("No role write outside FolderRoleEdit and the frozen migration")
    func roleWritesStayInFolderRoleEdit() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        var counts: [String: Int] = [:]
        for file in files {
            let hits = file.source.matches(of: Self.roleWrite).count
            if hits > 0 { counts[file.relativePath] = hits }
        }

        #expect(files.count > 100, "precondition: the scan read the app target")
        #expect(counts == Self.allowed,
                "role writes by file: \(counts.sorted { $0.key < $1.key }); route a new one through FolderRoleEdit")
    }

    @Test("The pattern finds a raw role write and a column assignment, and ignores reads")
    func patternMatchesWritesOnly() {
        #expect("try db.execute(sql: \"UPDATE folder SET role = ? WHERE id = ?\")".contains(Self.roleWrite))
        #expect("update folder set role = 'custom'".contains(Self.roleWrite))
        #expect(".updateAll(db, Column(\"role\").set(to: FolderRole.inbox.rawValue))".contains(Self.roleWrite))
        #expect(!"SELECT id FROM folder WHERE role = ?".contains(Self.roleWrite))
        #expect(!"Folder.filter(Column(\"role\") == FolderRole.inbox.rawValue)".contains(Self.roleWrite))
    }
}
