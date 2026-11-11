/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// `calendar_event_edit`'s `exdates_add` (#694): remove occurrences of a repeating event, as Google
/// Calendar's "delete this event" removes one. Each date is one ordinary delete of that occurrence,
/// by the id the provider's own lookup gives it, so it reaches the same write as
/// `calendar_event_delete` given that occurrence's id (CalDAV: the `EXDATE` write, #661).
///
/// - `exdates_add` is a call of its own: any other change in the same call is refused by name,
///   before anything is read, and the assistant is told to send that change as a second call.
/// - Every date is looked up before the card, against the series (also when `event_id` names one
///   of its occurrences), read in the call's `timezone`, through `CalendarProvider.occurrence`
///   only. A date that names no occurrence (none there, or already deleted or cancelled), an
///   ambiguous or malformed one refuses the WHOLE call, with nothing queued.
/// - The card is the delete card: one row per occurrence, each with `occurrenceDeleteNote`.
/// - The occurrences the card shows are the ones queued, one delete each, in ONE write
///   (`AccountManager.queueCalendarOperations`): all or nothing. Nothing is looked up again.
/// - The result names each date, deleted, queued or failed with the reason; never "updated".
/// - Deletes notify guests as every iOS calendar delete does (`sendUpdates` "all", in the queue).
enum CalendarEventEditExdates {

    /// How long the tool waits, for every queued delete together, for the drain to report them
    /// done: the wait every calendar tool gives one write (`awaitCalendarOpOutcome`).
    static let outcomeWaitSeconds: Double = 10

    /// The edit arguments that change the event. `edit_scope` is one too, unless it is "all".
    static let changeKeys = [
        "title", "start_iso", "end_iso", "all_day", "location", "description", "transparency",
        "add_attendees", "remove_attendees", "recurrence", "recurrence_id",
    ]

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

    /// The call's own checks: `exdates_add` alone (no other change), a non-empty list of dates
    /// (strings), and a `timezone` TabMail recognizes.
    static func check(_ arguments: [String: JSONValue], compoundId: String) -> Checked {
        var others = changeKeys.filter { given(arguments[$0]) }
        if let scope = CalendarToolHelpers.stringArgOpt(arguments, "edit_scope"), scope.lowercased() != "all" {
            others.append("edit_scope")
        }
        guard others.isEmpty else {
            return .refused(refusal(
                "exdates_add deletes occurrences and must be sent on its own, but this call also sets \(others.joined(separator: ", ")). The event was NOT changed. Nothing was deleted. Call calendar_event_edit with only event_id and exdates_add (and timezone) to delete the occurrences, then send the other change as a second calendar_event_edit call",
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
        guard let name = CalendarToolHelpers.stringArgOpt(arguments, "timezone"), !name.isEmpty else {
            return .dates(dates, zone: .current)
        }
        guard let zone = CalendarTimeZoneResolver.zone(named: name, in: .none) else {
            switch CalendarProviderError.unrecognizedTimeZone(
                name, consequence: "it did not delete any occurrence",
                remedy: "Nothing was deleted. Name the zone by its IANA name (e.g. 'America/Los_Angeles') and call calendar_event_edit again") {
            case .notSupported(let reason): return .refused(refusal(reason, compoundId: compoundId))
            }
        }
        return .dates(dates, zone: zone)
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
            guard let id = occurrence.id, !id.isEmpty else {
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

        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventDelete,
            calendarEvents: occurrences.map { entry in
                let title = entry.event.summary ?? target.event.summary ?? ""
                return .init(
                    eventId: entry.id,
                    calendarId: target.calendarName ?? "",
                    title: title.isEmpty ? "(No title)" : title,
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
                calendarId: target.calendarId, arguments: arguments)
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
        let opByOccurrence = Dictionary(uniqueKeysWithValues: ops.compactMap { op in op.eventId.map { ($0, op.id) } })

        var lines: [String] = []
        var failures: [String] = []
        var allDeleted = true
        for entry in found {
            let outcome = opByOccurrence[entry.id].flatMap { outcomes[$0] } ?? .timedOut
            switch outcome {
            case .success:
                lines.append("- \(entry.date): deleted")
            case .permanentFailure(let reason):
                lines.append("- \(entry.date): NOT deleted (\(reason))")
                failures.append("\(entry.date): \(reason)")
                allDeleted = false
            case .stillQueued, .timedOut:
                lines.append("- \(entry.date): queued, will be deleted shortly")
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
