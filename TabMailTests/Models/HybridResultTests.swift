/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("HybridCandidate")
struct HybridCandidateTests {

    @Test("Init with text and vector scores")
    func initScores() {
        let candidate = HybridCandidate(rowid: 42, textScore: 0.8, vectorScore: 0.6)
        #expect(candidate.rowid == 42)
        #expect(candidate.textScore == 0.8)
        #expect(candidate.vectorScore == 0.6)
    }
}

@Suite("HybridResult")
struct HybridResultTests {

    @Test("Init stores all fields")
    func initAllFields() {
        let result = HybridResult(rowid: 1, finalScore: 0.9, textScore: 0.8, vectorScore: 0.7)
        #expect(result.rowid == 1)
        #expect(result.finalScore == 0.9)
        #expect(result.textScore == 0.8)
        #expect(result.vectorScore == 0.7)
    }
}
