/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// The per-resource CalDAV builders as a write operation calls them: with the zone context of the
/// stored resource they are given, built from that resource. Tests that exercise one builder on one
/// resource call these, so the context is the one the provider would have read.
extension CalDAVProvider {
    static func mergePatchIntoICS(_ ics: String, patch: GCalEventInput) throws -> String {
        try mergePatchIntoICS(ics, patch: patch, zones: CalendarTimeZoneContext(calendarText: ics))
    }

    static func extractMasterDuration(from ics: String) throws -> TimeInterval? {
        try extractMasterDuration(from: ics, zones: CalendarTimeZoneContext(calendarText: ics))
    }

    static func seriesSplitResources(
        storedICS: String, slotNaiveISO: String, cappedRRule: String, newRRule: String,
        newUid: String, patch: GCalEventInput, now: Date
    ) throws -> SeriesSplitResources {
        try seriesSplitResources(
            storedICS: storedICS, slotNaiveISO: slotNaiveISO, cappedRRule: cappedRRule, newRRule: newRRule,
            newUid: newUid, patch: patch, now: now, zones: CalendarTimeZoneContext(calendarText: storedICS))
    }

    static func occurrenceOverrideResource(
        storedICS: String, recurrenceIdNaive: String, patch: GCalEventInput, now: Date
    ) throws -> String {
        try occurrenceOverrideResource(
            storedICS: storedICS, recurrenceIdNaive: recurrenceIdNaive, patch: patch, now: now,
            zones: CalendarTimeZoneContext(calendarText: storedICS))
    }
}
