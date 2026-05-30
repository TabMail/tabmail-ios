/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// In-memory mock of ChatIdTranslating for tool tests.
/// Assigns sequential numeric IDs starting from 1.
/// No persistence, no DB access, no side effects.
actor MockChatIdTranslator: ChatIdTranslating {
    private var idMap: [Int: String] = [:]
    private var reverseMap: [String: Int] = [:]
    private var nextId = 1

    func toNumericId(_ realId: String) -> Int {
        if let existing = reverseMap[realId] {
            return existing
        }
        let numericId = nextId
        nextId += 1
        idMap[numericId] = realId
        reverseMap[realId] = numericId
        return numericId
    }

    func toRealId(_ numericId: Int) -> String? {
        idMap[numericId]
    }

    /// Seed a known mapping for tests that need predictable IDs.
    func seed(_ realId: String, as numericId: Int) {
        idMap[numericId] = realId
        reverseMap[realId] = numericId
        if numericId >= nextId { nextId = numericId + 1 }
    }

    /// Alternate seed signature (numericId first) for convenience.
    func seed(_ numericId: Int, realId: String) {
        seed(realId, as: numericId)
    }

    // MARK: - Event Detail Caching (no-op for most tests)

    private var eventDetailCache: [String: EventPillDetail] = [:]
    private var calendarInfoCache: [String: EventCalendarInfo] = [:]

    func cacheEventDetail(
        realId: String,
        accountId: String?,
        calendarId: String?,
        calendarName: String?,
        title: String,
        startDate: Date?,
        endDate: Date?,
        isAllDay: Bool,
        location: String?,
        notes: String? = nil,
        attendees: [EventPillAttendee],
        isRecurring: Bool,
        recurrenceRule: String?,
        availability: String,
        htmlLink: String?,
        eventTimeZone: String?
    ) {
        // Build compound key (mirrors production ChatIdTranslator behavior)
        let compoundKey = if let accountId, !accountId.isEmpty {
            CompoundEventId.make(accountId: accountId, eventId: realId)
        } else {
            realId
        }
        let numericId = reverseMap[compoundKey] ?? reverseMap[realId] ?? toNumericId(realId)
        eventDetailCache[compoundKey] = EventPillDetail(
            id: numericId,
            realId: compoundKey,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            attendees: attendees,
            isRecurring: isRecurring,
            recurrenceRule: recurrenceRule,
            availability: availability,
            htmlLink: htmlLink,
            calendarName: calendarName,
            eventTimeZone: eventTimeZone
        )
        if let accountId, !accountId.isEmpty, let calendarId, !calendarId.isEmpty {
            calendarInfoCache[compoundKey] = EventCalendarInfo(
                accountId: accountId,
                calendarId: calendarId,
                calendarName: calendarName
            )
        }
    }

    func resolveEventDetail(_ numericId: Int) -> EventPillDetail? {
        guard let compoundId = idMap[numericId] else { return nil }
        return eventDetailCache[compoundId]
    }

    func resolveEventCalendarInfo(_ numericId: Int) -> EventCalendarInfo? {
        guard let compoundId = idMap[numericId] else { return nil }
        return calendarInfoCache[compoundId]
    }

    func evictEventDetail(realId: String) {
        eventDetailCache.removeValue(forKey: realId)
        calendarInfoCache.removeValue(forKey: realId)
    }

    // MARK: - Template Name Caching (no-op for most tests)

    private var templateNameCache: [Int: String] = [:]

    func cacheTemplateName(numericId: Int, name: String) {
        templateNameCache[numericId] = name
    }

    // MARK: - Template Detail (for tool tests that want to seed popover detail)

    private var templateDetailCache: [Int: TemplatePillDetail] = [:]

    func cacheTemplateDetail(_ detail: TemplatePillDetail) {
        templateDetailCache[detail.id] = detail
    }

    func resolveTemplateDetail(_ numericId: Int) -> TemplatePillDetail? {
        templateDetailCache[numericId]
    }
}
