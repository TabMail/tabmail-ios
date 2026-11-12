/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// MARK: - The calendar oracle fixtures are all there (ADR-IOS-110)
//
// A parameterized test with no arguments passes without running anything, and a test bundle
// built before a fixture was added reports a plausible count. So this suite checks, before any
// result of the oracle suites is believed, that every file the manifest names is in the bundle
// with the bytes the generator wrote, that the case counts match, and that the argument lists
// are not empty. Dates in the fixtures are fixed; see `CalendarOracleFixtures.swift`.

@Suite("Calendar oracle fixtures are complete")
struct CalendarOracleIntegrityTests {

    @Test("the manifest and every family file load")
    func everythingLoads() {
        #expect(CalendarOracle.loadErrors == [], "load errors: \(CalendarOracle.loadErrors)")
        let files = CalendarOracle.loaded.manifest?.files ?? []
        #expect(CalendarOracle.loaded.manifest != nil)
        #expect(!files.isEmpty, "the manifest names no family file")
    }

    @Test("every family file has the SHA-256 and case count the manifest gives")
    func filesMatchTheManifest() {
        for file in CalendarOracle.loaded.manifest?.files ?? [] {
            let data = CalendarOracle.loaded.fileData[file.file]
            #expect(data.map(CalendarOracle.sha256) == file.sha256, "\(file.file): bytes differ from the manifest (regenerate, then ./Scripts/xcodegen.sh)")
            #expect(CalendarOracle.loaded.casesByFile[file.file]?.count == file.cases, "\(file.file): case count differs from the manifest")
        }
    }

    @Test("case ids are unique, every case says what it expects, and no expected key repeats")
    func casesAreWellFormed() {
        let ids = CalendarOracle.allCases.map(\.id)
        #expect(Set(ids).count == ids.count, "a case id appears twice")
        for oracleCase in CalendarOracle.allCases {
            #expect(["occurrences", "notListed"].contains(oracleCase.expect), "\(oracleCase.id): expect is \(oracleCase.expect)")
            // Only a disagreement resolved as excluded asserts nothing.
            #expect((oracleCase.expected == nil) == (oracleCase.resolution?.follows == "excluded"), "\(oracleCase.id): expected list and resolution do not match")
            let keys = (oracleCase.expected ?? []).map(\.key)
            #expect(Set(keys).count == keys.count, "\(oracleCase.id): an expected occurrence key appears twice")
        }
    }

    @Test("the listing suite's arguments are every asserted case")
    func listingArgumentsAreTheCensus() {
        let total = CalendarOracle.loaded.manifest?.files.reduce(0) { $0 + $1.cases } ?? 0
        let excluded = CalendarOracle.allCases.filter { $0.expected == nil }.count
        #expect(total > 0)
        #expect(!CalendarOracle.listingCases.isEmpty)
        #expect(CalendarOracle.listingCases.count == total - excluded - CalendarOracle.parked.count)
    }

    @Test("every parked case exists, asserts something, and names its issue")
    func parkedCasesNameTheirIssue() {
        let issuePrefix = "https://github.com/TabMail/tabmail-ios/issues/"
        for (id, issue) in CalendarOracle.parked {
            #expect(CalendarOracle.casesByID[id]?.expected != nil, "parked \(id) is not an asserted case")
            #expect(issue.hasPrefix(issuePrefix) && issue.count > issuePrefix.count, "parked \(id) names no issue")
        }
    }
}
