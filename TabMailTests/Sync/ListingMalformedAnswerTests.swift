/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Malformed server answers on the full-sync listing's wire (#755): an EXISTS no
/// UID or sequence number can carry, and a SEARCH answer that pages its matches
/// (PARTIAL) without listing them.
extension ListingCountersTests {

    @Test("A SELECT whose EXISTS is above UInt32.max makes the folder not listable: no window FETCH, nothing removed, counters unwritten, the stamp allowed; a usable count then lists it")
    func outOfRangeExistsIsNotListable() async throws {
        try await E.withWorld("lc-exists-range", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            try Self.addArchive(w, serverUIDs: [1, 2, 3], localUIDs: [1, 2])
            w.server.setSelectExists(Int(UInt32.max) + 1, for: Self.archivePath)
            #expect(try Self.fullSyncStamp(w) == nil, "precondition: the full sync is due")
            _ = try await w.engine.sync(account: try Self.account(w))

            #expect(!w.server.recordedCommands().contains { $0.contains("FETCH 1:3") }, "no window FETCH built from the count")
            let held = try Self.archive(w)
            #expect(held.uids.isSuperset(of: ["1", "2"]), "nothing removed")
            #expect(held.folder.totalCount == 2 && held.folder.lastKnownUidNext == 3, "its counters stay unwritten")
            #expect(held.folder.lastKnownHighestModSeq == nil, "no MODSEQ without a proven listing")
            #expect(try Self.fullSyncStamp(w) != nil, "a folder the server made not listable does not withhold the stamp")

            w.server.setSelectExists(nil, for: Self.archivePath)
            let next = try await w.engine.fullSync(account: w.account, provider: w.provider)
            #expect(next.listedFolderIds.contains(Self.archiveId(w)), "a usable count lists the folder")
            let after = try Self.archive(w)
            #expect(after.uids == ["1", "2", "3"])
            #expect(after.folder.totalCount == 3)
        }
    }

    @Test("EXISTS 0 confirmed by a SEARCH answer that pages its matches (PARTIAL, COUNT 0) without ALL: nothing removed, counters and the due full sync kept; a complete empty answer empties the folder",
          arguments: ["partialCountZero", "partialOnly", "completeEmpty"])
    func partialSearchAnswerIsNotAbsence(_ answer: String) async throws {
        try await E.withWorld("lc-partial-\(answer)", capabilities: Self.condstoreNoReader, serverUIDs: [1], localUIDs: [1]) { w in
            // The control's server really is empty: its rows were deleted elsewhere.
            try Self.addArchive(w, serverUIDs: answer == "completeEmpty" ? [] : [1, 2], localUIDs: [1, 2])
            w.server.setSelectExists(0, for: Self.archivePath)
            switch answer {
            case "partialCountZero": w.server.answerNextUIDSearch(in: Self.archivePath, esearchData: "COUNT 0 PARTIAL (1:100 1:2)")
            case "partialOnly": w.server.answerNextUIDSearch(in: Self.archivePath, esearchData: "PARTIAL (1:100 1:2)")
            default: w.server.answerNextUIDSearch(in: Self.archivePath, esearchData: "COUNT 0")
            }
            let before = try Self.archive(w)
            _ = try await w.engine.sync(account: try Self.account(w))
            #expect(w.server.compactUIDSearchAnswersServed() == 1, "precondition: the confirmation SEARCH got the answer under test")
            let after = try Self.archive(w)
            if answer == "completeEmpty" {
                #expect(after.uids.isEmpty, "a complete answer listing nothing confirms the empty folder")
                #expect(after.folder.totalCount == 0)
            } else {
                #expect(after.uids == ["1", "2"], "a paged answer proves no message absent")
                #expect(after.folder.totalCount == before.folder.totalCount
                        && after.folder.lastKnownUidNext == before.folder.lastKnownUidNext
                        && after.folder.lastKnownHighestModSeq == before.folder.lastKnownHighestModSeq,
                        "its counters and MODSEQ bookmark stay unwritten")
                #expect(try Self.fullSyncStamp(w) == nil, "an unproven folder keeps the full sync due (the retry)")
            }
        }
    }
}
