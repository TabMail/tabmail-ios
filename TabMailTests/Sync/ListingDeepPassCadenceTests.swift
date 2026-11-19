/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The deep-pass counter steps once per full sync (#755): a MODSEQ-quiet folder
/// is skipped by the full syncs between its listings and listed again on every
/// `SyncConfig.fullSyncDeepEveryN`th one, never sooner.
extension ListingCountersTests {

    @Test("A MODSEQ-quiet folder is listed by its first full sync, skipped by the next ones, and listed again exactly on the deep pass")
    func deepPassCounterStepsOncePerFullSync() async throws {
        try await E.withWorld("lc-deep-cadence", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2], localUIDs: [1, 2])
            var listedOn: [Int] = []
            let passes = SyncConfig.fullSyncDeepEveryN + 1
            for pass in 1...passes {
                let listing = try await w.engine.fullSync(account: w.account, provider: w.provider)
                if listing.listedFolderIds.contains(Self.archiveId(w)) { listedOn.append(pass) }
            }
            // Pass 1 lists (no stored MODSEQ yet); the counter reaches the deep
            // pass on the N-th full sync, so the next listing is pass N.
            #expect(listedOn == [1, SyncConfig.fullSyncDeepEveryN], "listed on passes \(listedOn)")
        }
    }
}
