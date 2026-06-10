/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("VTimeZoneBuilder")
struct VTimeZoneBuilderTests {

    /// First IANA zone whose tzdata still has a regular cadence of future DST
    /// transitions (≥2 upcoming). Hardcoding a single zone breaks when tzdata
    /// adopts permanent-time legislation — America/Vancouver went permanent-PDT
    /// in 2026 (no future transitions, fixed -0700) and broke the hardcoded
    /// version of these tests. Returns nil if every candidate has gone
    /// fixed-offset; callers then return early — the two-component VTIMEZONE
    /// path is unreachable for such a world, in production too.
    private static func zoneObservingDST() -> TimeZone? {
        let candidates = [
            "America/New_York", "America/Chicago", "America/Vancouver",
            "Europe/Berlin", "Europe/Paris", "Europe/London",
            "Australia/Sydney", "Pacific/Auckland",
        ]
        for id in candidates {
            guard let tz = TimeZone(identifier: id),
                  let first = tz.nextDaylightSavingTimeTransition(after: Date()),
                  tz.nextDaylightSavingTimeTransition(after: first) != nil
            else { continue }
            return tz
        }
        return nil
    }

    @Test("formatOffset renders RFC 5545 ±HHMM")
    func formatOffset() {
        #expect(VTimeZoneBuilder.formatOffset(0) == "+0000")
        #expect(VTimeZoneBuilder.formatOffset(-28800) == "-0800")   // PST
        #expect(VTimeZoneBuilder.formatOffset(3600) == "+0100")     // CET
        #expect(VTimeZoneBuilder.formatOffset(19800) == "+0530")    // India
        #expect(VTimeZoneBuilder.formatOffset(-12600) == "-0330")   // Newfoundland
    }

    @Test("a DST zone produces both DAYLIGHT and STANDARD components with yearly RRULEs")
    func dstZone() throws {
        guard let tz = Self.zoneObservingDST() else { return }
        let block = try #require(VTimeZoneBuilder.vtimezone(for: tz))
        let text = block.joined(separator: "\n")
        #expect(block.first == "BEGIN:VTIMEZONE")
        #expect(block.last == "END:VTIMEZONE")
        #expect(text.contains("TZID:\(tz.identifier)"))
        #expect(text.contains("BEGIN:DAYLIGHT"))
        #expect(text.contains("BEGIN:STANDARD"))
        // The two TZOFFSETTO values are the zone's offsets just after each of
        // the next two transitions — derived from the TimeZone API, not from
        // the builder's own logic.
        let first = try #require(tz.nextDaylightSavingTimeTransition(after: Date()))
        let second = try #require(tz.nextDaylightSavingTimeTransition(after: first))
        let expected = Set([
            "TZOFFSETTO:" + VTimeZoneBuilder.formatOffset(tz.secondsFromGMT(for: first.addingTimeInterval(1))),
            "TZOFFSETTO:" + VTimeZoneBuilder.formatOffset(tz.secondsFromGMT(for: second.addingTimeInterval(1))),
        ])
        #expect(Set(block.filter { $0.hasPrefix("TZOFFSETTO:") }) == expected)
        // Recurring transition rules.
        #expect(text.contains("RRULE:FREQ=YEARLY;BYMONTH="))
        // Every BEGIN has a matching END.
        #expect(block.filter { $0.hasPrefix("BEGIN:") }.count == block.filter { $0.hasPrefix("END:") }.count)
    }

    @Test("a non-DST zone produces a single fixed-offset STANDARD component, no RRULE")
    func fixedOffsetZone() throws {
        // Asia/Tokyo has not observed DST in the modern era.
        let tz = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let block = try #require(VTimeZoneBuilder.vtimezone(for: tz))
        let text = block.joined(separator: "\n")
        #expect(text.contains("TZID:Asia/Tokyo"))
        #expect(text.contains("BEGIN:STANDARD"))
        #expect(!text.contains("BEGIN:DAYLIGHT"))
        #expect(text.contains("TZOFFSETTO:+0900"))
        #expect(!text.contains("RRULE:"), "a fixed-offset zone needs no recurrence rule")
    }

    @Test("UTC produces a +0000 fixed-offset component")
    func utcZone() throws {
        let block = try #require(VTimeZoneBuilder.vtimezone(for: TimeZone(identifier: "UTC")!))
        let text = block.joined(separator: "\n")
        #expect(text.contains("TZOFFSETFROM:+0000"))
        #expect(text.contains("TZOFFSETTO:+0000"))
        #expect(!text.contains("BEGIN:DAYLIGHT"))
    }

    @Test("sub-component DTSTART is anchored in the past — every event date has a prior onset (RFC 5545 §3.6.5)")
    func dtstartIsPastAnchored() throws {
        // RFC 5545 §3.6.5: the applicable offset is the observance with the
        // last onset BEFORE the time in question. If DTSTART were the next
        // (future) transition, an event earlier than it would have no
        // resolvable offset — an RRULE only generates instances forward from
        // DTSTART. Every STANDARD/DAYLIGHT DTSTART must therefore be in the past.
        guard let tz = Self.zoneObservingDST() else { return }
        let block = try #require(VTimeZoneBuilder.vtimezone(for: tz))
        let dtstarts = block
            .filter { $0.hasPrefix("DTSTART:") }
            .map { String($0.dropFirst("DTSTART:".count)) }
        #expect(dtstarts.count == 2)
        for dt in dtstarts {
            // "YYYYMMDDThhmmss" — the year must be well in the past.
            let year = Int(dt.prefix(4)) ?? 9999
            #expect(year <= 1970, "DTSTART \(dt) is not past-anchored")
        }
    }

    @Test("anchored DTSTART is a real instance of its RRULE (date is the named weekday/month)")
    func dtstartMatchesRRule() throws {
        // RFC 5545: DTSTART must be synchronized with the RRULE. The anchored
        // onset date must actually fall on the weekday + month the rule names.
        guard let tz = Self.zoneObservingDST() else { return }
        let block = try #require(VTimeZoneBuilder.vtimezone(for: tz))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekdayAbbrev = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        var pendingDT: String?
        for line in block {
            if line.hasPrefix("DTSTART:") {
                pendingDT = String(line.dropFirst("DTSTART:".count))
            } else if line.hasPrefix("RRULE:"), let dt = pendingDT {
                let y = try #require(Int(dt.prefix(4)))
                let m = try #require(Int(dt.dropFirst(4).prefix(2)))
                let d = try #require(Int(dt.dropFirst(6).prefix(2)))
                let date = try #require(cal.date(from: DateComponents(year: y, month: m, day: d)))
                let weekday = cal.component(.weekday, from: date)
                #expect(line.contains("BYMONTH=\(m)"), "RRULE \(line) does not name month \(m)")
                #expect(line.contains(weekdayAbbrev[weekday - 1]),
                        "RRULE \(line) does not name the weekday of \(dt)")
                pendingDT = nil
            }
        }
    }

    @Test("the generated VTIMEZONE round-trips: TZOFFSETFROM of one component equals TZOFFSETTO of the other")
    func transitionsAreConsistent() throws {
        // For a 2-transition zone, the DAYLIGHT's FROM is the STANDARD's TO and
        // vice versa — the offsets must be internally consistent.
        guard let tz = Self.zoneObservingDST() else { return }
        let block = try #require(VTimeZoneBuilder.vtimezone(for: tz))
        let froms = block.filter { $0.hasPrefix("TZOFFSETFROM:") }.map { String($0.dropFirst("TZOFFSETFROM:".count)) }
        let tos = block.filter { $0.hasPrefix("TZOFFSETTO:") }.map { String($0.dropFirst("TZOFFSETTO:".count)) }
        #expect(froms.count == 2 && tos.count == 2)
        #expect(Set(froms) == Set(tos), "the two components' FROM/TO offsets must be the same pair, swapped")
        #expect(Set(tos).count == 2, "standard and daylight offsets must be distinct")
    }
}
