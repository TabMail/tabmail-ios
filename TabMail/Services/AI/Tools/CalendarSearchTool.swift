/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_search` tool matching TB addon's `calendar_search.js`.
/// Searches events by date range with query filtering.
/// Returns compact calendar summary grouped by date/calendar.
/// Supports pagination via `page_index` (matching TB v1.0.17).
struct CalendarSearchTool: AgentTool, Sendable {
    let name = "calendar_search"

    private enum Config {
        /// TB uses pageSize=100 (calendarPageSizeDefault=100 clamped by calendarPageSizeMax=100)
        static let eventsPerPage = 100
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let backends = await CalendarProviderDispatch.resolveAll()
        guard !backends.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }

        guard case .string(let query) = arguments["query"],
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing required 'query' string"}"#
        }

        var pageIndex = 1
        if case .int(let n) = arguments["page_index"] { pageIndex = max(1, n) }
        else if case .double(let d) = arguments["page_index"] { pageIndex = max(1, Int(d)) }

        let (startDate, endDate) = CalendarToolHelpers.resolveDateRange(arguments)
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: backends,
            timeMin: startDate,
            timeMax: endDate,
            query: trimmedQuery,
            maxResults: 250
        )

        if result.events.isEmpty {
            return "No calendar events found matching '\(trimmedQuery)' in the requested date range."
        }

        // Google's `singleEvents=true` expansion returns each occurrence as its
        // own row with `recurrence` empty and `recurringEventId` set on the
        // instance. Resolve the master's RRULE up-front (deduped, concurrent)
        // so the LLM sees UNTIL/COUNT on every line and can tell a capped
        // predecessor series from its open-ended successor — matches TB's
        // calendar_search behavior where the bridge always returns the rule.
        let masterRRuleById = await CalendarToolHelpers.resolveMasterRecurrence(
            events: result.events, backends: backends
        )

        let tz = CalendarToolHelpers.resolveTimeZone(arguments)
        Task { await CalendarToolHelpers.cacheEventDetailsForPills(result.events, calendarNames: result.calendarNames) }
        return paginateAndFormat(
            events: result.events, calendarNames: result.calendarNames,
            pageIndex: pageIndex, timeZone: tz, masterRRuleById: masterRRuleById
        )
    }

    private func paginateAndFormat(
        events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)],
        calendarNames: [String: String], pageIndex: Int, timeZone: TimeZone? = nil,
        masterRRuleById: [String: String] = [:]
    ) -> String {
        let totalEvents = events.count
        let totalPages = (totalEvents + Config.eventsPerPage - 1) / Config.eventsPerPage
        let startIdx = (pageIndex - 1) * Config.eventsPerPage
        let endIdx = min(startIdx + Config.eventsPerPage, totalEvents)

        guard startIdx < totalEvents else {
            return "Page \(pageIndex) is beyond the last page (\(totalPages)). Total events: \(totalEvents)."
        }

        let pageEvents = Array(events[startIdx..<endIdx])
        var output = CalendarToolHelpers.formatGroupedSummary(
            pageEvents, calendarNames: calendarNames, timeZone: timeZone,
            masterRRuleById: masterRRuleById
        )

        if totalPages > 1 {
            output += "\n\n--- Page \(pageIndex) of \(totalPages) (showing \(pageEvents.count) of \(totalEvents) events) ---"
        }

        print("[CalendarSearchTool] Page \(pageIndex)/\(totalPages) (\(pageEvents.count) events) tz=\(timeZone?.identifier ?? "device")")
        print("[CalendarSearchTool] tool_result:\n\(output)\n[CalendarSearchTool] tool_result_end")
        return output
    }
}
