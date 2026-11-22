/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Outlook's progress total on the scheduled route (#755): a warm provider's
/// successful change pass hands its applied folder list to the full sync of the
/// same pass, and that full sync must still take a current complete total.
extension OutlookChangeReadingTests {

    enum FolderListOutcome: String, CaseIterable, Sendable {
        /// Only known folders' counts changed: the change read reports `.updated`.
        case updated
        /// A new folder appeared: the change read lists the tree (`.complete`).
        case complete
    }

    @Test("A warm provider's scheduled full sync after a successful change pass refreshes the progress total",
          arguments: FolderListOutcome.allCases)
    func scheduledFullSyncRefreshesTheTotal(outcome: FolderListOutcome) async throws {
        let first = (1...7).map { Self.seed("m-\($0)", in: Self.inbox) }
        try await Self.withWorld(seeds: first) { w in
            // Cold pass: the full sync lists the tree and adopts its total.
            try await w.foregroundPass()
            #expect(await w.provider.progressTotal(crawling: true) == .messages(7), "precondition: the first full sync adopted 7")

            // The server's total becomes 11.
            for index in 8...11 { w.server.deliver(Self.seed("m-\(index)", in: Self.inbox)) }
            if outcome == .complete { w.server.addFolder(id: "fld-new", name: "New") }

            // A successful change pass, then its scheduled full sync.
            try await w.foregroundPass()
            #expect(await w.provider.progressTotal(crawling: true) == .messages(11),
                    "the scheduled full sync took the current complete total")

            // The published denominator follows.
            let engine = SyncEngine()
            await engine.register(accountId: w.accountId, provider: w.provider,
                                  workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            await AccountManager.shared.clearBackfillProgress(accountId: w.accountId)
            await engine.updateBackfillProgressForAccount(try w.account())
            let progress = try #require(await AccountManager.shared._backfillBacking[w.accountId], "progress is published")
            #expect(progress.totalEmails == 11)
            await AccountManager.shared.clearBackfillProgress(accountId: w.accountId)
            await engine.remove(accountId: w.accountId)
        }
    }
}
