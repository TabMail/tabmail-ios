/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_event_read` tool matching TB addon's `calendar_event_read.js`.
/// Returns detailed event information. Supports two lookup paths:
/// 1. Direct: event_id (preferred, fastest)
/// 2. Search: start_iso + optional title filter
struct CalendarEventReadTool: AgentTool, Sendable {
    let name = "calendar_event_read"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let rawEventId = CalendarToolHelpers.stringArg(arguments, "event_id")
        let startIso = CalendarToolHelpers.stringArg(arguments, "start_iso")
        let titleFilter = CalendarToolHelpers.stringArg(arguments, "title")

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to compound event ID
        //
        // 🚨 **R13-U1 — a numeric id the translator cannot resolve is REFUSED, not
        // passed through as a literal event id.** This is the contract all four mail
        // tools already had (`EmailReadTool`: `guard let realId = await
        // translator.toRealId(numericId) else { return … }`) and the three calendar
        // tools did not. `ChatIdTranslator` evicts orphan mappings at
        // `Config.maxMappings`, so `toRealId` returning nil is an ordinary
        // occurrence in a long session — and continuing with the numeral itself
        // addresses whatever event happens to be named "42" on the server. The
        // agent is told to re-look-up instead, which is exactly what it does with a
        // stale `unique_id` today.
        //
        // ⚠️ **The non-numeric branch is deliberately KEPT, and that is not an
        // oversight.** These tools' own failure strings interpolate the raw
        // `compoundId` into prose (`CalendarEventEditTool` / `CalendarEventDeleteTool`
        // "could not find event with id '…'"), and `processToolOutputForLLM` only
        // rewrites ids on a `event_id: <value>` LINE — so a real compound id does
        // reach the model untranslated, and echoing it back is a *working recovery
        // path*, not an attack. Refusing it would be the mirror image of the defect:
        // it removes a legitimate path while the hazard it is aimed at lives
        // somewhere else entirely. The hazard — an agent-authored string becoming a
        // URL **authority** or extra path segments, with the account credential
        // attached — is closed at the boundary where it actually happens and where
        // the string's provenance no longer matters: `CalDAVProvider.resolveURL`
        // (origin containment) and `GoogleCalendarProvider.encodedPathSegment`
        // (one-path-segment containment).
        let compoundId: String
        let numericId: Int?
        if !rawEventId.isEmpty, let n = Int(rawEventId) {
            guard let realId = await ctx.translator.toRealId(n) else {
                print("[CalendarEventReadTool] Failed to resolve numeric id \(n)")
                return #"{"error": "no event found for the given event_id. Call calendar_search or calendar_read to look up the event again, then retry."}"#
            }
            compoundId = realId
            numericId = n
            print("[CalendarEventReadTool] Resolved numeric id \(n) → \(realId.prefix(50))...")
        } else {
            compoundId = rawEventId
            numericId = nil
        }

        // Path 1: Direct lookup by event_id
        if !compoundId.isEmpty {
            let tz = CalendarToolHelpers.resolveTimeZone(arguments)
            return await directLookup(compoundId: compoundId, numericId: numericId, timeZone: tz)
        }

        // Path 2: Search by start_iso across all calendars
        if startIso.isEmpty {
            return #"{"error": "provide either 'event_id' or 'start_iso'"}"#
        }

        let tz = CalendarToolHelpers.resolveTimeZone(arguments)
        guard let targetDate = EKEventStoreHelper.parseNaiveISO(startIso, timeZone: tz) else {
            return ToolJSON.string(from: ["error": "invalid start datetime: \(startIso)"])
        }

        let backends = await CalendarProviderDispatch.resolveAll()
        guard !backends.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }

        let toleranceSeconds: TimeInterval = 60
        let windowStart = targetDate.addingTimeInterval(-toleranceSeconds)
        let windowEnd = targetDate.addingTimeInterval(toleranceSeconds)

        let result = await CalendarToolHelpers.fetchEventsFromAllCalendars(
            backends: backends,
            timeMin: windowStart,
            timeMax: windowEnd,
            query: nil,
            maxResults: 250
        )

        let matches = result.events.filter { entry in
            guard let start = entry.event.startDate else { return false }
            let diff = abs(start.timeIntervalSince(targetDate))
            guard diff <= toleranceSeconds else { return false }
            if !titleFilter.isEmpty && (entry.event.summary ?? "") != titleFilter { return false }
            return true
        }

        if matches.isEmpty {
            return "No entries matched."
        }

        Task { await CalendarToolHelpers.cacheEventDetailsForPills(matches, calendarNames: result.calendarNames, translator: ctx.translator) }
        let results: [String] = matches.map { entry in
            let calNameKey = CompoundEventId.make(accountId: entry.accountId, eventId: entry.calendarId)
            return CalendarToolHelpers.formatDetailedEvent(
                entry.event,
                accountId: entry.accountId,
                calendarId: entry.calendarId,
                accessRole: entry.accessRole,
                calendarName: result.calendarNames[calNameKey],
                timeZone: tz
            )
        }
        print("[CalendarEventReadTool] \(matches.count) matches for start_iso=\(startIso)")
        return results.joined(separator: "\n-----\n")
    }

    /// Direct lookup: resolve account + calendar from compound ID or cache, then getEvent.
    private func directLookup(compoundId: String, numericId: Int?, timeZone: TimeZone? = nil) async -> String {
        // Try to extract accountId + rawEventId from compound ID
        var accountId: String?
        var rawEventId: String
        var calendarId: String?

        if let parts = CompoundEventId.split(compoundId) {
            accountId = parts.accountId
            rawEventId = parts.eventId
        } else {
            rawEventId = compoundId // Legacy bare event ID
        }

        // Try cache for calendarId
        if let numId = numericId, let calInfo = await ctx.translator.resolveEventCalendarInfo(numId) {
            accountId = calInfo.accountId
            calendarId = calInfo.calendarId
        }

        // If we have accountId + calendarId, do targeted lookup
        if let accId = accountId, let calId = calendarId {
            let provider = await AccountManager.shared.calendarProviders[accId]
            if let provider {
                do {
                    let event = try await provider.getEvent(calendarId: calId, eventId: rawEventId)
                    // Look up the parent calendar's accessRole — needed so a
                    // direct event tap on a freeBusyReader entry renders as
                    // "Busy" instead of "(No title)".
                    var accessRole: String? = nil
                    var calName: String? = nil
                    if let cals = try? await provider.listCalendars(),
                       let cal = cals.first(where: { $0.id == calId }) {
                        accessRole = cal.accessRole
                        calName = cal.summary
                    }
                    let isFreeBusy = (accessRole == CalendarToolHelpers.freeBusyAccessRole)
                    let cachedTitle: String = {
                        if isFreeBusy {
                            return "Busy — \(CalendarToolHelpers.freeBusyDisplayName(calendarName: calName, calendarId: calId))"
                        }
                        return (event.summary ?? "").isEmpty ? "(No title)" : event.summary!
                    }()
                    let rrule = (event.recurrence ?? []).first(where: { $0.uppercased().hasPrefix("RRULE:") })
                    Task {
                        await ctx.translator.cacheEventDetail(
                            realId: rawEventId, accountId: accId, calendarId: calId, calendarName: calName,
                            title: cachedTitle,
                            startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay,
                            location: isFreeBusy ? nil : event.location,
                            notes: isFreeBusy ? nil : event.description,
                            attendees: isFreeBusy ? [] : CalendarToolHelpers.eventPillAttendees(from: event),
                            isRecurring: !isFreeBusy && !(event.recurrence ?? []).isEmpty,
                            recurrenceRule: isFreeBusy ? nil : rrule,
                            availability: event.transparency == "transparent" ? "free" : "busy", htmlLink: isFreeBusy ? nil : event.htmlLink,
                            eventTimeZone: event.start?.timeZone ?? event.end?.timeZone
                        )
                    }
                    print("[CalendarEventReadTool] Direct lookup event_id=\(rawEventId) in account=\(accId)")
                    return CalendarToolHelpers.formatDetailedEvent(event, accountId: accId, calendarId: calId, accessRole: accessRole, calendarName: calName, timeZone: timeZone)
                } catch {
                    if !CalendarToolHelpers.isEventNotFoundError(error) {
                        return #"{"error": "Calendar access error. Please check your calendar connection in Settings."}"#
                    }
                    // Fall through to scan other calendars
                }
            }
        }

        // Fallback: scan all accounts/calendars
        let backends = await CalendarProviderDispatch.resolveAll()
        for backend in backends {
            let accId = backend.account.id
            if accId == accountId { continue } // Already tried above
            do {
                let calendars = try await backend.provider.listCalendars()
                for calendar in calendars {
                    do {
                        let event = try await backend.provider.getEvent(calendarId: calendar.id, eventId: rawEventId)
                        let isFreeBusy = (calendar.accessRole == CalendarToolHelpers.freeBusyAccessRole)
                        let cachedTitle: String = {
                            if isFreeBusy {
                                return "Busy — \(CalendarToolHelpers.freeBusyDisplayName(calendarName: calendar.summary, calendarId: calendar.id))"
                            }
                            return (event.summary ?? "").isEmpty ? "(No title)" : event.summary!
                        }()
                        let rrule = (event.recurrence ?? []).first(where: { $0.uppercased().hasPrefix("RRULE:") })
                        Task {
                            await ctx.translator.cacheEventDetail(
                                realId: rawEventId, accountId: accId, calendarId: calendar.id, calendarName: calendar.summary,
                                title: cachedTitle,
                                startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay,
                                location: isFreeBusy ? nil : event.location,
                                notes: isFreeBusy ? nil : event.description,
                                attendees: isFreeBusy ? [] : CalendarToolHelpers.eventPillAttendees(from: event),
                                isRecurring: !isFreeBusy && !(event.recurrence ?? []).isEmpty,
                                recurrenceRule: isFreeBusy ? nil : rrule,
                                availability: event.transparency == "transparent" ? "free" : "busy", htmlLink: isFreeBusy ? nil : event.htmlLink,
                                eventTimeZone: event.start?.timeZone ?? event.end?.timeZone
                            )
                        }
                        print("[CalendarEventReadTool] Fallback found event_id=\(rawEventId) in account=\(accId) calendar=\(calendar.id)")
                        return CalendarToolHelpers.formatDetailedEvent(event, accountId: accId, calendarId: calendar.id, accessRole: calendar.accessRole, calendarName: calendar.summary, timeZone: timeZone)
                    } catch {
                        if CalendarToolHelpers.isEventNotFoundError(error) { continue }
                    }
                }
            } catch {
                print("[CalendarEventReadTool] listCalendars failed for account \(accId): \(error)")
            }
        }

        return #"{"error": "Event not found in any calendar."}"#
    }
}
