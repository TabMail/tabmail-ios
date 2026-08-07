/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_event_create` tool matching TB addon's `calendar_event_create.js`.
/// Creates a new calendar event with user confirmation (ADR-IOS-024).
/// Queued for crash-safe async execution via PendingCalendarOperation.
struct CalendarEventCreateTool: AgentTool, Sendable {
    let name = "calendar_event_create"
    private let ctx: ToolContext

    init(context: ToolContext? = nil) {
        self.ctx = context ?? ToolContext()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments, invocation: .noninteractive)
    }

    /// ADR-IOS-053: real entry point — delivers the confirmation card to the
    /// invoking session via `invocation.uiSink` (nil sink → declined fast-fail).
    func execute(arguments: [String: JSONValue], invocation: ToolInvocation) async throws -> String {
        let title = CalendarToolHelpers.stringArg(arguments, "title")
        let startIso = CalendarToolHelpers.stringArg(arguments, "start_iso")
        let endIso = CalendarToolHelpers.stringArg(arguments, "end_iso")
        let allDay = CalendarToolHelpers.boolArg(arguments, "all_day")
        let tz = CalendarToolHelpers.resolveTimeZone(arguments)

        // Resolve start date
        let startDate: Date
        if !startIso.isEmpty, let parsed = EKEventStoreHelper.parseNaiveISO(startIso, timeZone: tz) {
            startDate = parsed
        } else {
            startDate = Date()
        }

        // Resolve end date — when missing, apply the user's default duration
        // (Settings → Calendar → Default event duration). Computed client-side
        // so the LLM never has to.
        //
        // 🚨 THE ALL-DAY CONVENTION IS HALF-OPEN — `[start, end)`, END EXCLUSIVE
        // (R16-6). Stated here explicitly because leaving it implicit is exactly the
        // trap that produced the bug: this branch read `endDate = startDate`, which
        // for a TIMED event would be a zero-length event and for an ALL-DAY event is
        // an event covering NO days at all.
        //
        // All three providers use the exclusive form and `buildGCalEventInput` passes
        // the date strings through verbatim (`String(endIso.prefix(10))`) with no
        // normalization anywhere downstream, so whatever is computed here is what
        // reaches the wire: Google `end.date`, Graph's midnight-to-midnight values,
        // and CalDAV's `DTEND;VALUE=DATE`. The tree's own anchor for the convention
        // is `GoogleCalendarSplitHelpersTests.mergeMasterAndPatchAllDayPreserved` —
        // *"1-day all-day event → end is exclusive next day"*, `start=2026-05-27`,
        // `end=2026-05-28`.
        //
        // ⚠️ ONLY THE DEFAULT MOVES. A caller-supplied `end_iso` is taken verbatim by
        // the first branch, so an explicit multi-day range is untouched, and the
        // timed default still uses the user's `defaultEventDurationMinutes`. The
        // mirror image would be normalising every all-day end by +1 day, which would
        // silently extend every explicit range the agent already computed correctly.
        let endDate: Date
        if !endIso.isEmpty, let parsed = EKEventStoreHelper.parseNaiveISO(endIso, timeZone: tz) {
            endDate = parsed
        } else if allDay == true {
            // Default = ONE day, which under the half-open convention is the next
            // calendar day. Computed with the resolved calendar/timezone rather than
            // `+86400` so a DST transition day cannot land it on the wrong date.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            endDate = cal.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        } else {
            let minutes = CalendarProviderDispatch.defaultEventDurationMinutes
            endDate = startDate.addingTimeInterval(TimeInterval(minutes * 60))
        }

        let eventTitle = title.isEmpty ? "(No title)" : title

        // Extract attendee list for confirmation card
        var attendeeNames: [String] = []
        if case .array(let arr) = arguments["attendees"] {
            for item in arr {
                if case .dictionary(let dict) = item,
                   case .string(let email) = dict["email"], !email.isEmpty {
                    if case .string(let name) = dict["name"], !name.isEmpty {
                        attendeeNames.append("\(name) <\(email)>")
                    } else {
                        attendeeNames.append(email)
                    }
                } else if case .string(let email) = item, !email.isEmpty {
                    attendeeNames.append(email)
                }
            }
        }

        // Build details for confirmation card
        var details: [String] = []
        if let loc = CalendarToolHelpers.stringArgOpt(arguments, "location"), !loc.isEmpty {
            details.append("location: \(loc)")
        }
        if let transparency = CalendarToolHelpers.stringArgOpt(arguments, "transparency") {
            details.append("availability: \(transparency)")
        }
        if case .dictionary(let rec) = arguments["recurrence"],
           case .string(let freq) = rec["freq"] {
            var desc = freq.lowercased()
            if case .int(let n) = rec["interval"], n > 1 { desc = "every \(n) \(desc)" }
            if case .int(let count) = rec["count"] { desc += " (\(count) times)" }
            else if case .string(let until) = rec["until"] { desc += " (until \(until))" }
            details.append("recurrence: \(desc)")
        }

        // ADR-IOS-024: Show confirmation card and await user response
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventCreate,
            calendarEvents: [.init(
                eventId: "",
                calendarId: "",
                title: eventTitle,
                startDate: startDate,
                endDate: endDate,
                isAllDay: allDay ?? false,
                changes: details,
                attendees: attendeeNames,
                timeZoneId: CalendarToolHelpers.stringArgOpt(arguments, "timezone"),
                notes: CalendarToolHelpers.stringArgOpt(arguments, "description")
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            print("[CalendarEventCreateTool] User declined to create event")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to create this event.",
            ] as [String: Any]))
        }

        guard let backend = await CalendarProviderDispatch.resolve().resolved else {
            return CalendarProviderDispatch.notAvailableMessage
        }
        // Resolve the actual calendarId at creation time — stored in the queue and cache
        // so subsequent edit/delete targets the correct calendar even if the user changes
        // their preferred calendar later.
        let calendarId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: backend.provider)
        let result = try await queueCalendarCreate(accountId: backend.account.id, calendarId: calendarId, arguments: arguments, startDate: startDate, endDate: endDate, isAllDay: allDay ?? false, cardState: cardState)

        return result
    }

    // MARK: - Calendar (Queued)

    private func queueCalendarCreate(accountId: String, calendarId: String, arguments: [String: JSONValue], startDate: Date, endDate: Date, isAllDay: Bool, cardState: AgentToolRouter.ActionConfirmation.ResponseState) async throws -> String {
        let manager = AccountManager.shared
        let generatedEventId = PendingCalendarOperation.generateGoogleEventId(from: UUID().uuidString)

        // Normalize start_iso / end_iso into the queued args. The agent often
        // omits end_iso (the schema promises a +1h default) and the drain-side
        // `buildGCalEventInput` does not synthesize one — so the actual POST
        // would 400 with "Missing end time." even though execute() resolved
        // defaults locally for the confirmation card. Bake the resolved values
        // into the args we persist so the drain sees a complete payload.
        let resolvedTz = CalendarToolHelpers.resolveTimeZone(arguments)
        var queuedArgs = arguments
        let isoFmt = DateFormatter()
        isoFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        isoFmt.timeZone = resolvedTz
        if isAllDay {
            queuedArgs["start_iso"] = .string(String(isoFmt.string(from: startDate).prefix(10)))
            queuedArgs["end_iso"] = .string(String(isoFmt.string(from: endDate).prefix(10)))
        } else {
            queuedArgs["start_iso"] = .string(isoFmt.string(from: startDate))
            queuedArgs["end_iso"] = .string(isoFmt.string(from: endDate))
        }

        let op = try await manager.queueCalendarOperation(
            type: .create,
            accountId: accountId,
            eventId: generatedEventId,
            calendarId: calendarId,
            arguments: queuedArgs
        )

        let title = CalendarToolHelpers.stringArg(arguments, "title")
        let eventTitle = title.isEmpty ? "(No title)" : title
        print("[CalendarEventCreateTool] Queued create (op: \(op.id))")

        // Wait briefly for the drain to surface a terminal outcome so the LLM
        // can react in-turn. On permanent failure (HTTP 4xx — e.g. "Missing
        // end time") the agent gets a structured error and can retry with
        // corrected args. On timeout we fall through to the existing async
        // success message so the user is not blocked forever.
        let outcome = await manager.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 10.0)
        switch outcome {
        case .permanentFailure(let reason):
            print("[CalendarEventCreateTool] Permanent failure for op \(op.id): \(reason)")
            // Flip the confirmation card to its red/⚠ failed state so the user
            // sees the failure inline.
            await MainActor.run { cardState.failureReason = reason }
            // Evict the optimistic cache so the pill popover doesn't keep showing
            // a phantom event.
            await ctx.translator.evictEventDetail(realId: CompoundEventId.make(accountId: accountId, eventId: generatedEventId))
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_create failed: \(reason). The event was NOT created. Please correct the arguments and call calendar_event_create again — for example, ensure start_iso and end_iso are both present in 'yyyy-MM-dd'T'HH:mm:ss' form, or pass an explicit `timezone` if the user is not in their device timezone.",
                "event_title": eventTitle,
            ])
        case .success:
            // Fall through to the normal "queued/created" cache+return path.
            break
        case .stillQueued, .timedOut:
            // Drain is taking longer than expected (offline, retry backoff,
            // server slow). Keep the optimistic cache and tell the LLM the
            // event is in flight.
            break
        }

        // Provider-assigned real id (Exchange/CalDAV) — we use this in the
        // result string and the cache. Falls back to our pre-id if the drain
        // didn't return a real id (timedOut / stillQueued — the event will
        // be on the server eventually; the pre-id is the best optimistic
        // identifier we have until then). Without this fallback the LLM's
        // next edit would send Graph the pre-id and get HTTP 400.
        let resolvedRealId: String = {
            if case .success(_, let createdRealId) = outcome,
               let id = createdRealId, !id.isEmpty { return id }
            return generatedEventId
        }()

        // Surface the RRULE the create tool just built so the pill popover can
        // render "Repeats weekly" etc. before the event drains to the provider.
        // Reuses the same builder the drain runs, so the cached value matches
        // exactly what the provider will store.
        let createdRRule: String? = {
            let input = CalendarToolHelpers.buildGCalEventInput(queuedArgs, isAllDay: isAllDay)
            return (input.recurrence ?? []).first(where: { $0.uppercased().hasPrefix("RRULE:") })
        }()
        // Cache event details for pill popovers and subsequent edit/delete confirmations
        await ctx.translator.cacheEventDetail(
            realId: resolvedRealId,
            accountId: accountId,
            calendarId: calendarId,
            calendarName: nil,
            title: eventTitle,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: CalendarToolHelpers.stringArgOpt(arguments, "location"),
            notes: CalendarToolHelpers.stringArgOpt(arguments, "description"),
            attendees: CalendarToolHelpers.eventPillAttendees(fromArguments: arguments),
            isRecurring: arguments["recurrence"] != nil,
            recurrenceRule: createdRRule,
            availability: CalendarToolHelpers.stringArgOpt(arguments, "transparency") == "transparent" ? "free" : "busy",
            htmlLink: nil,
            eventTimeZone: resolvedTz.identifier
        )

        // Echo the resolved start/end so the LLM doesn't hallucinate a
        // duration. When the LLM omits `end_iso`, we default to the user's
        // Calendar setting (`defaultEventDurationMinutes`, typically 30 min) —
        // but the tool's return previously hid that, and the LLM would tell
        // the user "Created for 1 hour" assuming a fictitious default.
        let echoIsoFmt = DateFormatter()
        echoIsoFmt.dateFormat = isAllDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss"
        echoIsoFmt.timeZone = resolvedTz
        let startIsoLine = "start_iso: \(echoIsoFmt.string(from: startDate))"
        let endIsoLine = "end_iso: \(echoIsoFmt.string(from: endDate))"

        return [
            "Calendar event creation queued successfully.",
            "event_id: \(CompoundEventId.make(accountId: accountId, eventId: resolvedRealId))",
            "event_title: \(eventTitle)",
            startIsoLine,
            endIsoLine,
            "timezone: \(resolvedTz.identifier)",
            "The event will appear on the calendar shortly.",
        ].joined(separator: "\n")
    }
}
