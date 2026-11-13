/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// `calendar_event_edit`'s `exdates_add` (#694): remove occurrences of a repeating event, as Google
/// Calendar's "delete this event" removes one. Each date is one ordinary delete of that occurrence,
/// by the id the provider's own lookup gives it, so it reaches the same write as
/// `calendar_event_delete` given that occurrence's id (CalDAV: the `EXDATE` write, #661).
///
/// - `exdates_add` is a call of its own: any argument outside `allowedKeys` is refused by name,
///   before anything is read, and the assistant is told to send that change FIRST, then read the
///   event again and send `exdates_add` alone (a series change on Google and Outlook brings back
///   occurrences deleted before it).
/// - Every date is looked up before the card, against the series (also when `event_id` names one
///   of its occurrences), read in the call's `timezone`, through `CalendarProvider.occurrence`
///   only. A date that names no occurrence (none there, or already deleted or cancelled), an
///   ambiguous or malformed one refuses the WHOLE call, with nothing queued.
/// - The card is the delete card: one row per occurrence, each with `occurrenceDeleteNote`.
/// - The occurrences the card shows are the ones queued, one delete each, in ONE write
///   (`AccountManager.queueCalendarOperations`): all or nothing. Nothing is looked up again.
/// - The result names each date beside the start of the occurrence it named, deleted, queued or
///   failed with the reason; never "updated". An occurrence id equal to the series' is refused.
/// - Deletes notify guests as every iOS calendar delete does (`sendUpdates` "all", in the queue).
enum CalendarEventEditExdates {

    /// How long the tool waits, for every queued delete together, for the drain to report them
    /// done: the wait every calendar tool gives one write (`awaitCalendarOpOutcome`).
    static let outcomeWaitSeconds: Double = 10

    /// The answer when the event's series is not on the server, only changed occurrences of it (a
    /// calendar entry holding no series, #729): no date of it can be removed here.
    static let seriesNotHere =
        "only changed occurrences of this repeating event are on the server, not the event itself, so its dates can't be removed here. Nothing was deleted. The user can change it in their calendar app"

    /// The only arguments an `exdates_add` call may carry. Any other key, in the schema or not, is a
    /// change this path would not make, so it is refused by name (fails closed). `edit_scope` is
    /// allowed only when it is "all" (`isAllScope`).
    static let allowedKeys: Set<String> = [
        "event_id", "calendar_id", "exdates_add", "timezone", "edit_scope",
    ]

    /// Whether `edit_scope` is absent, null or "all": the default, which changes nothing here.
    private static func isAllScope(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .null?: return true
        case .string(let scope)?: return scope.lowercased() == "all"
        default: return false
        }
    }

    /// Whether the call asks to remove occurrences.
    static func isRequested(_ arguments: [String: JSONValue]) -> Bool {
        given(arguments["exdates_add"])
    }

    /// Whether an argument is given: present, not null, and not an empty list.
    private static func given(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .null?: return false
        case .array(let items)?: return !items.isEmpty
        default: return true
        }
    }

    /// The call's dates and the zone they are read in, checked before anything is read; a refusal
    /// is the tool's whole answer.
    enum Checked {
        case dates([String], zone: TimeZone)
        case refused(String)
    }

    /// The call's own checks: `exdates_add` alone (no other argument outside `allowedKeys`), a
    /// non-empty list of dates (strings), and a `timezone` TabMail recognizes. With no `timezone`
    /// the dates are read in `deviceZone`, the zone the tool snapshotted at its start (#753).
    static func check(_ arguments: [String: JSONValue], compoundId: String, deviceZone: TimeZone) -> Checked {
        var others = arguments.keys.filter { !allowedKeys.contains($0) }.sorted()
        if !isAllScope(arguments["edit_scope"]) { others.append("edit_scope") }
        // The other change goes FIRST: on Google and Outlook a change to the series (its times, its
        // rule, a split) brings back occurrences deleted before it, so the deletes come after it,
        // named by the occurrences' starts as they are then.
        guard others.isEmpty else {
            return .refused(refusal(
                "exdates_add deletes occurrences and must be sent on its own, but this call also sets \(others.joined(separator: ", ")). The event was NOT changed. Nothing was deleted. First send the other change as its own calendar_event_edit call, without exdates_add. Then read the event again and call calendar_event_edit with only event_id and exdates_add (and timezone), naming the occurrences by their start_iso as they are then",
                compoundId: compoundId))
        }
        guard case .array(let items) = arguments["exdates_add"], !items.isEmpty else {
            return .refused(refusal(
                "exdates_add must be a list of occurrence starts (start_iso as calendar_event_read or calendar_read shows them). Nothing was deleted",
                compoundId: compoundId))
        }
        var dates: [String] = []
        for item in items {
            guard case .string(let raw) = item,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .refused(refusal(
                    "every exdates_add entry must be an occurrence start as text (start_iso as calendar_event_read or calendar_read shows it). Nothing was deleted",
                    compoundId: compoundId))
            }
            dates.append(raw.trimmingCharacters(in: .whitespaces))
        }
        // A zone TabMail does not recognize is refused, never read as the device's zone (which
        // would name other occurrences), as every calendar write refuses it.
        do {
            let zone = try CalendarToolHelpers.resolveWriteTimeZone(
                arguments, deviceZone: deviceZone, consequence: "it did not delete any occurrence",
                remedy: "Nothing was deleted. Name the zone by its IANA name (e.g. 'America/Los_Angeles') and call calendar_event_edit again")
            return .dates(dates, zone: zone)
        } catch CalendarProviderError.notSupported(let reason) {
            return .refused(refusal(reason, compoundId: compoundId))
        } catch {
            return .refused(refusal("\(error.localizedDescription). Nothing was deleted", compoundId: compoundId))
        }
    }

    /// An occurrence's start as the read tools show it (`formatDetailedEvent`'s `start_iso`): an
    /// all-day date as its own date, a timed start in the call's zone.
    private static func startISO(_ event: GCalEvent, zone: TimeZone) -> String {
        if event.isAllDay, let day = event.start?.date { return CalendarToolHelpers.allDayNaiveISO(day) }
        guard let start = event.startDate else { return "(start unknown)" }
        return EKEventStoreHelper.toNaiveISO(start, timeZone: zone)
    }

    private static func refusal(_ reason: String, compoundId: String) -> String {
        ToolJSON.string(from: [
            "ok": false,
            "error": "calendar_event_edit failed: \(reason).",
            "event_id": compoundId,
        ] as [String: Any])
    }

    /// The event the call names, as the edit tool read it, and where it is.
    struct Target {
        let event: GCalEvent
        let eventId: String
        let compoundId: String
        let accountId: String
        /// The calendar the event was read from.
        let lookupCalendarId: String
        /// The calendar the queued deletes name (nil: the account's default, as the edit tool queues).
        let calendarId: String?
        let calendarName: String?
    }

    /// Look every date up, show the delete card, and queue one delete per occurrence.
    static func execute(
        dates: [String], zone: TimeZone, target: Target, provider: any CalendarProvider,
        translator: any ChatIdTranslating, invocation: ToolInvocation
    ) async throws -> String {
        // The dates are the series' occurrences: an occurrence id is looked up through its series,
        // so a date of another occurrence names that one (the lookup refuses an occurrence id with
        // another occurrence's date).
        let seriesId: String
        if let series = target.event.recurringEventId, !series.isEmpty, series != target.eventId {
            seriesId = series
        } else if !(target.event.recurrence ?? []).isEmpty {
            seriesId = target.eventId
        } else {
            return refusal(
                "this event does not repeat, so it has no occurrences to exclude with exdates_add. Nothing was deleted. To delete the event, use calendar_event_delete",
                compoundId: target.compoundId)
        }

        // Every date, before the card; one that names no occurrence refuses the whole call.
        var found: [(date: String, occurrence: GCalEvent, id: String)] = []
        for date in dates {
            let occurrence: GCalEvent
            do {
                occurrence = try await provider.occurrence(
                    calendarId: target.lookupCalendarId, eventId: seriesId, recurrenceId: date, recurrenceIdZone: zone)
            } catch CalendarProviderError.seriesNotInThisCalendar {
                // An edit is told to change one occurrence on its own (`reason`), which no exdates
                // call can use: say what is true for removing dates instead.
                return refusal(Self.seriesNotHere, compoundId: target.compoundId)
            } catch CalendarProviderError.notSupported(let reason) {
                let reason = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                return refusal(
                    "exdates_add '\(date)': \(reason). Nothing was deleted",
                    compoundId: target.compoundId)
            } catch where AccountManager.isCalendarNotFoundError(error) {
                return refusal(
                    "exdates_add '\(date)' names none of this repeating event's occurrences (none starts there, or it was already deleted). Nothing was deleted. Look the occurrences up with calendar_read or calendar_search and pass their start_iso",
                    compoundId: target.compoundId)
            } catch {
                return refusal(
                    "could not look up the occurrence at exdates_add '\(date)' (\(error.localizedDescription)). Nothing was deleted",
                    compoundId: target.compoundId)
            }
            // An id of its own, never the series': a delete by the series' id removes every occurrence.
            guard let id = occurrence.id, !id.isEmpty, id != seriesId else {
                return refusal(
                    "the occurrence at exdates_add '\(date)' has no id of its own, so it can't be deleted alone. Nothing was deleted",
                    compoundId: target.compoundId)
            }
            found.append((date, occurrence, id))
        }
        // Two dates naming one occurrence delete it once.
        var occurrences: [(id: String, event: GCalEvent)] = []
        for entry in found where !occurrences.contains(where: { $0.id == entry.id }) {
            occurrences.append((entry.id, entry.occurrence))
        }
        BackgroundSyncLogger.logDebug("[CalendarEventEditExdates] \(dates.count) date(s) name \(occurrences.count) occurrence(s) of \(seriesId.prefix(50))")

        // The title each occurrence's card shows; a late failure names it the same way.
        func cardTitle(_ event: GCalEvent) -> String {
            let title = event.summary ?? target.event.summary ?? ""
            return title.isEmpty ? "(No title)" : title
        }
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventDelete,
            calendarEvents: occurrences.map { entry in
                .init(
                    eventId: entry.id,
                    calendarId: target.calendarName ?? "",
                    title: cardTitle(entry.event),
                    startDate: entry.event.startDate ?? Date(),
                    endDate: entry.event.endDate ?? entry.event.startDate ?? Date(),
                    isAllDay: entry.event.isAllDay,
                    changes: [CalendarToolHelpers.occurrenceDeleteNote],
                    notes: entry.event.description
                )
            },
            via: invocation.uiSink
        )
        guard confirmed else {
            BackgroundSyncLogger.logDebug("[CalendarEventEditExdates] User declined deleting \(occurrences.count) occurrence(s)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete these occurrences.",
            ] as [String: Any]))
        }
        guard !target.accountId.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }

        // One ordinary delete per occurrence, all in one write.
        let ops = occurrences.map { entry in
            var arguments: [String: JSONValue] = ["event_id": .string(entry.id)]
            if let calendarId = target.calendarId { arguments["calendar_id"] = .string(calendarId) }
            return PendingCalendarOperation(
                operationType: .delete, accountId: target.accountId, eventId: entry.id,
                calendarId: target.calendarId, arguments: arguments,
                eventTitle: cardTitle(entry.event))
        }
        let manager = AccountManager.shared
        try await manager.queueCalendarOperations(ops)

        // Every outcome, under one deadline.
        let outcomes = await withTaskGroup(of: (String, CalendarOpOutcome).self) { group in
            for op in ops {
                group.addTask { (op.id, await manager.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: Self.outcomeWaitSeconds)) }
            }
            var all: [String: CalendarOpOutcome] = [:]
            for await (id, outcome) in group { all[id] = outcome }
            return all
        }
        // The cached details of the occurrences are evicted, as `calendar_event_delete` evicts its event's.
        for entry in occurrences {
            await translator.evictEventDetail(realId: CompoundEventId.make(accountId: target.accountId, eventId: entry.id))
        }

        var lines: [String] = []
        var failures: [String] = []
        var allDeleted = true
        for entry in found {
            // `ops` is built from `occurrences`, index for index.
            let opId = occurrences.firstIndex { $0.id == entry.id }.map { ops[$0].id }
            let outcome = opId.flatMap { outcomes[$0] } ?? .timedOut
            // Each date beside the start of the occurrence it named, so a mismatch is visible.
            let named = "- \(entry.date) (occurrence starting \(startISO(entry.occurrence, zone: zone)))"
            switch outcome {
            case .success:
                lines.append("\(named): deleted")
            case .permanentFailure(let reason):
                lines.append("\(named): NOT deleted (\(reason))")
                failures.append("\(entry.date): \(reason)")
                allDeleted = false
            case .stillQueued, .timedOut:
                lines.append("\(named): queued, will be deleted shortly")
                allDeleted = false
            }
        }
        BackgroundSyncLogger.logDebug("[CalendarEventEditExdates] Outcomes: \(lines.joined(separator: " "))")

        if !failures.isEmpty {
            let failed = failures.joined(separator: "; ")
            await MainActor.run { cardState.failureReason = failed }
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_edit did not delete every occurrence asked for. Failed: \(failed). Do not tell the user those occurrences were deleted; report each date as listed.\n" + lines.joined(separator: "\n"),
                "event_id": target.compoundId,
            ] as [String: Any])
        }
        return ([
            allDeleted ? "Occurrences deleted successfully." : "Occurrence deletion queued successfully.",
            "event_id: \(target.compoundId)",
        ] + lines + [
            "The rest of the series stays.",
            allDeleted ? nil : "Queued occurrences will be removed from the calendar shortly. Cancellation notices will be sent to attendees.",
        ].compactMap { $0 }).joined(separator: "\n")
    }
}
