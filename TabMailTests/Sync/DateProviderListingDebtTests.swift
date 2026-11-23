/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A date-window provider's folder (Gmail, Exchange) whose on-demand listing
/// failed once must become tracked again after its next proven listing, and
/// then need no window listing: the failure leaves no count-check debt that
/// nothing on these providers could clear (#755).
extension GmailChangeReadingTests {

    @Test("Gmail: a folder whose on-demand listing failed is tracked after its next listing works, and needs no further window listing")
    func failedOnDemandListingRecovers() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("debt-1", labels: [Pins.userLabelId], date: Pins.daysAgo(1)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.isTracking(w, w.label), "precondition: the label folder is tracked")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = NULL WHERE id = ?", arguments: [w.label.id])
            }

            w.server.failListings(status: 503, label: Pins.userLabelId)
            let outcome = await SyncEngine().listFolder(w.label, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            w.server.clearListingFailures()
            guard case .unproven = outcome else { Issue.record("precondition: the listing failed, got \(outcome)"); return }
            let afterFailure = try await w.pool.read { db in FolderChangeState(raw: try Folder.fetchOne(db, key: w.label.id)?.changeState) }
            #expect(!afterFailure.listingDue, "no count-check debt on a provider that has no count check")

            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.isTracking(w, w.label), "the next proven listing makes it tracked")

            let before = Self.windowListings(w)
            try await Self.foregroundPassFullSyncNotForced(w)
            #expect(Self.windowListings(w) == before, "a tracked folder needs no further window listing")
        }
    }
}

extension OutlookChangeReadingTests {

    @Test("Exchange: a folder whose on-demand listing failed is tracked after its next listing works, and needs no further window listing")
    func failedOnDemandListingRecovers() async throws {
        try await Self.withWorld(seeds: [Self.seed("debt-1", in: Self.archive)]) { w in
            try await w.foregroundPass()
            let tracked = { try FolderChangeState(raw: w.folder(Self.archive).changeState).tracking }
            #expect(try tracked(), "precondition: the archive is tracked")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = NULL WHERE id = ?", arguments: [w.folderId(Self.archive)])
            }

            w.server.failListings(status: 503)
            let outcome = await SyncEngine().listFolder(try w.folder(Self.archive), provider: w.provider, limit: SyncConfig.syncMessageLimit)
            w.server.clearListingFailures()
            guard case .unproven = outcome else { Issue.record("precondition: the listing failed, got \(outcome)"); return }
            #expect(try !FolderChangeState(raw: w.folder(Self.archive).changeState).listingDue,
                    "no count-check debt on a provider that has no count check")

            try await w.foregroundPass()
            #expect(try tracked(), "the next proven listing makes it tracked")

            let windowListings = {
                w.server.http.recordedCalls().filter {
                    $0.method == "GET" && $0.url.contains("/mailFolders/\(Self.archive)/messages")
                        && !$0.url.contains("/messages/delta")
                }.count
            }
            let before = windowListings()
            let engine = SyncEngine()
            await engine.register(accountId: w.accountId, provider: w.provider,
                                  workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            _ = try await engine.sync(account: try w.account())
            await engine.remove(accountId: w.accountId)
            #expect(windowListings() == before, "a tracked folder needs no further window listing")
        }
    }
}
