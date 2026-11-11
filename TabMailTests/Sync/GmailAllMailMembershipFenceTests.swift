/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// All Mail membership has one source: `GmailProvider.allMailExcludedLabelIds`,
/// asked through `GmailProvider.folder(_:containsMessageWithLabels:)`. The Gmail
/// history delta must not skip All Mail or test membership by label equality,
/// and no other app file may hold its own copy of the excluded-label list.
@Suite("Gmail All Mail membership has one source")
struct GmailAllMailMembershipFenceTests {
    static let deltaFile = "TabMail/Services/Sync/SyncEngineDeltaSync.swift"
    static let providerFile = "TabMail/Providers/GmailProvider.swift"
    static let excludedLabels = ["INBOX", "SENT", "TRASH", "SPAM", "DRAFT"].map { "\"\($0)\"" }

    /// Array literals that name every excluded label.
    static func excludedLabelListCount(in source: String) -> Int {
        source.matches(of: try! Regex(#"\[[^\[\]]*\]"#)).filter { match in
            let literal = String(source[match.range])
            return excludedLabels.allSatisfy { literal.contains($0) }
        }.count
    }

    @Test("The delta loop neither skips All Mail nor tests membership by label equality")
    func deltaUsesTheMembershipHelper() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        let delta = try #require(files.first { $0.relativePath == Self.deltaFile })
        #expect(!delta.source.contains("archivePath"))
        #expect(!delta.source.contains("labelIds.contains(folder.path)"))
        #expect(delta.source.contains("GmailProvider.folder("))
    }

    @Test("The excluded-label list exists only in GmailProvider")
    func excludedLabelListLivesInGmailProvider() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        #expect(files.count > 100, "precondition: the scan read the app target")
        var counts: [String: Int] = [:]
        for file in files {
            let hits = Self.excludedLabelListCount(in: file.source)
            if hits > 0 { counts[file.relativePath] = hits }
        }
        #expect(counts == [Self.providerFile: 1], "excluded-label lists by file: \(counts)")
    }

    @Test("The list pattern finds the list in any order and ignores a partial one")
    func patternMatchesWholeListsOnly() {
        #expect(Self.excludedLabelListCount(in: #"let x = ["DRAFT", "SPAM", "TRASH", "SENT", "INBOX"]"#) == 1)
        #expect(Self.excludedLabelListCount(in: #"let x: Set<String> = ["SENT", "DRAFT"]"#) == 0)
    }
}
