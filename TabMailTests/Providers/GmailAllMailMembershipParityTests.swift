/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The All Mail listing query and the delta's membership helper are one rule:
/// the query is built from the excluded-label list, and for any label set the
/// helper answers what the fake Gmail server answers for the listing query.
@Suite("Gmail All Mail listing and delta membership agree")
struct GmailAllMailMembershipParityTests {
    static let labelSets: [Set<String>] = [
        [], ["UNREAD"], ["STARRED", "IMPORTANT"], ["CATEGORY_PROMOTIONS"], ["Label_1"],
        ["INBOX"], ["INBOX", "UNREAD"], ["SENT"], ["SENT", "Label_1"], ["TRASH"],
        ["SPAM"], ["DRAFT"], ["CHAT"], ["TRASH", "Label_1"], ["INBOX", "SENT", "TRASH", "SPAM", "DRAFT"],
    ]

    @Test("The listing query is the excluded labels' -in: tokens, in order")
    func queryIsBuiltFromTheList() {
        let tokens = GmailProvider.allMailExcludedLabelIds.map { "-in:\($0.lowercased())" }
        #expect(GmailProvider.allMailExclusionQuery == tokens.joined(separator: " "))
        #expect(GmailProvider.allMailExclusionQuery == "-in:inbox -in:sent -in:trash -in:spam -in:draft",
                "the query string the listing sends is unchanged")
    }

    @Test("For every label set the helper agrees with the fake server's listing", arguments: labelSets)
    func helperMatchesListing(labels: Set<String>) {
        let listed = StatefulGmailActionServer.satisfiesQueryExclusions(GmailProvider.allMailExclusionQuery, labels: labels)
        #expect(GmailProvider.folder(GmailProvider.archivePath, containsMessageWithLabels: Array(labels)) == listed)
    }

    @Test("A real folder holds exactly the messages carrying its label", arguments: labelSets)
    func labelFolderMembership(labels: Set<String>) {
        for path in ["INBOX", "SENT", "TRASH", "Label_1"] {
            #expect(GmailProvider.folder(path, containsMessageWithLabels: Array(labels)) == labels.contains(path))
        }
    }
}
