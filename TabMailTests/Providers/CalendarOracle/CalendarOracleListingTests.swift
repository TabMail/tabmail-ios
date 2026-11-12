/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// MARK: - A CalDAV listing shows the occurrences libical and ical.js give (ADR-IOS-110)
//
// INVARIANT (system property): `CalDAVOccurrences.listing` lists, for the exact calendar text
// both engines read, every occurrence that overlaps the window where the engines (or, where they
// disagree, the written decision) put it: the same keys, starts, ends, status and moved flag, no
// key twice; and each key reads back (`CalDAVOccurrences.occurrence(key:)`, the read, edit and
// delete by occurrence id) as the row the listing gave. A rule TabMail does not expand is one row
// that says its occurrences are not listed.
//
// Dates are fixed (1896-2019), under the testing rules' exception for dates in 2020 and earlier:
// see `CalendarOracleFixtures.swift`.

@Suite("CalDAV listings match the calendar oracles")
struct CalendarOracleListingTests {

    private static let href = "/cal/oracle.ics"

    @Test("listing and read-back", arguments: CalendarOracle.listingCases)
    func listingMatchesTheOracles(_ caseID: OracleCaseID) throws {
        let oracleCase = try #require(CalendarOracle.casesByID[caseID.id])
        let expected = try #require(oracleCase.expected)
        guard zoneDataAgrees(oracleCase, expected) else { return }
        let from = try #require(CalendarOracle.instant(oracleCase.window.from))
        let to = try #require(CalendarOracle.instant(oracleCase.window.to))

        let rows = CalDAVOccurrences.listing(icsText: oracleCase.ics, href: Self.href, timeMin: from, timeMax: to)

        if oracleCase.expect == "notListed" {
            #expect(rows.count == 1, "\(oracleCase.id): a rule TabMail does not expand is one row")
            guard rows.count == 1 else { return }
            #expect(rows[0].occurrencesNotListed == true, "\(oracleCase.id): the row does not say its occurrences are not listed")
            return
        }

        var listed: [String: OracleOccurrence.Compared] = [:]
        var keys: [String] = []
        for row in rows {
            switch CalendarOracle.normalize(row, frame: oracleCase.frame) {
            case .success(let occurrence):
                keys.append(occurrence.key)
                listed[occurrence.key] = occurrence.compared
            case .failure(let failure):
                Issue.record("\(oracleCase.id): \(failure)")
            }
        }
        let wanted = Dictionary(expected.map { ($0.key, $0.compared) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(keys).count == keys.count, "\(oracleCase.id): a key is listed twice: \(keys.sorted())")
        #expect(listed == wanted, "\(oracleCase.id): \(Self.difference(listed: listed, wanted: wanted))")

        // Read-back: every expected key names the occurrence the listing showed.
        for occurrence in expected {
            let read = CalDAVOccurrences.occurrence(key: occurrence.key, icsText: oracleCase.ics, href: Self.href)
            let normalized = read.map { CalendarOracle.normalize($0, frame: oracleCase.frame) }
            switch normalized {
            case .success(let got)?:
                #expect(got.key == occurrence.key && got.compared == occurrence.compared,
                        "\(oracleCase.id): \(occurrence.key) reads back as \(got), the oracles give \(occurrence)")
            case .failure(let failure)?:
                Issue.record("\(oracleCase.id): \(occurrence.key) reads back unreadable: \(failure)")
            case nil:
                Issue.record("\(oracleCase.id): \(occurrence.key) does not read back")
            }
        }
    }

    /// Foundation's zone data must give each zoned occurrence the offset the engines and Node's
    /// zone data agreed on; otherwise the comparison would report a zone-data difference as an
    /// expansion bug. The case still fails, labelled as zone data.
    private func zoneDataAgrees(_ oracleCase: OracleCase, _ expected: [OracleOccurrence]) -> Bool {
        guard let identifier = oracleCase.zoneIdentifier else { return true }
        guard let zone = TimeZone(identifier: identifier) else {
            Issue.record("time-zone data drift in \(oracleCase.id): Foundation \(TimeZone.timeZoneDataVersion) has no zone \(identifier)")
            return false
        }
        for occurrence in expected {
            guard let offset = occurrence.offset, let instant = CalendarOracle.instant(occurrence.start) else {
                Issue.record("\(oracleCase.id): zoned occurrence \(occurrence.key) has no offset or instant")
                return false
            }
            if zone.secondsFromGMT(for: instant) != offset {
                Issue.record("time-zone data drift in \(oracleCase.id): Foundation \(TimeZone.timeZoneDataVersion), fixture \(CalendarOracle.fixtureTzdata) (\(identifier) at \(occurrence.start): \(zone.secondsFromGMT(for: instant)) s, fixture \(offset) s)")
                return false
            }
        }
        return true
    }

    private static func difference(listed: [String: OracleOccurrence.Compared], wanted: [String: OracleOccurrence.Compared]) -> String {
        let keys = Set(listed.keys).union(wanted.keys).sorted()
        return keys.compactMap { key -> String? in
            let got = listed[key]
            let want = wanted[key]
            guard got != want else { return nil }
            return "\(key): listed \(got.map(String.init(describing:)) ?? "nothing"), oracles \(want.map(String.init(describing:)) ?? "nothing")"
        }.joined(separator: "; ")
    }
}
