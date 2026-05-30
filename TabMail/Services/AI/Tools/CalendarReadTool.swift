/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_read` tool matching TB addon's `calendar_read.js`.
/// Wrapper that delegates to CalendarSearchTool without a query string.
/// Returns a compact calendar summary grouped by date/calendar.
struct CalendarReadTool: AgentTool, Sendable {
    let name = "calendar_read"

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let backends = await CalendarProviderDispatch.resolveAll()
        guard !backends.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }

        let (startDate, endDate) = CalendarToolHelpers.resolveDateRange(arguments)

        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: backends,
            timeMin: startDate,
            timeMax: endDate,
            query: nil,
            maxResults: 2500
        )

        if result.events.isEmpty {
            return "No calendar events found in the requested date range."
        }

        let tz = CalendarToolHelpers.resolveTimeZone(arguments)
        Task { await CalendarToolHelpers.cacheEventDetailsForPills(result.events, calendarNames: result.calendarNames) }
        let output = CalendarToolHelpers.formatGroupedSummary(result.events, calendarNames: result.calendarNames, timeZone: tz)
        print("[CalendarReadTool] Returning \(result.events.count) events tz=\(tz.identifier)")
        // Print the exact tool result the LLM will see, so we can tell whether
        // a "day appears empty" complaint is a tool bug (missing rows) or an
        // LLM rendering bug (rows present but not surfaced to the user).
        print("[CalendarReadTool] tool_result:\n\(output)\n[CalendarReadTool] tool_result_end")
        return output
    }
}
