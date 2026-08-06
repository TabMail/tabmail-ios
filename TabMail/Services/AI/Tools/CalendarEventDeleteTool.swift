/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `calendar_event_delete` tool matching TB addon's `calendar_event_delete.js`.
/// Deletes a calendar event with user confirmation (ADR-IOS-024).
/// Queued for crash-safe async execution via PendingCalendarOperation.
struct CalendarEventDeleteTool: AgentTool, Sendable {
    let name = "calendar_event_delete"
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
        guard case .string(let rawEventId) = arguments["event_id"],
              !rawEventId.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "missing event_id — use calendar_event_read or calendar_search to look up the event first"}"#
        }

        // LLM sends numeric IDs (translated by processToolOutputForLLM) — resolve back to compound event ID
        let compoundId: String
        let numericId: Int?
        if let n = Int(rawEventId), let realId = await ctx.translator.toRealId(n) {
            compoundId = realId
            numericId = n
            print("[CalendarEventDeleteTool] Resolved numeric id \(n) → \(realId.prefix(50))...")
        } else {
            compoundId = rawEventId.trimmingCharacters(in: .whitespaces)
            numericId = nil
        }

        // Extract accountId + rawEventId from compound ID
        let accountId: String
        let eventId: String
        if let parts = CompoundEventId.split(compoundId) {
            accountId = parts.accountId
            eventId = parts.eventId
        } else {
            accountId = ""
            eventId = compoundId
        }

        // Resolve calendarId from cache
        let calInfo: EventCalendarInfo?
        if let numId = numericId {
            calInfo = await ctx.translator.resolveEventCalendarInfo(numId)
        } else {
            calInfo = nil
        }
        let resolvedAccountId = calInfo?.accountId ?? accountId
        let calendarId = calInfo?.calendarId
        let calendarName = calInfo?.calendarName

        // Fetch current event details from API for confirmation card
        var fetchedEvent: GCalEvent?

        let provider: (any CalendarProvider)?
        if !resolvedAccountId.isEmpty {
            provider = await AccountManager.shared.calendarProviders[resolvedAccountId]
        } else {
            provider = await CalendarProviderDispatch.resolve(db: ctx.db).resolved?.provider
        }

        if let provider, let calId = calendarId {
            fetchedEvent = try? await provider.getEvent(calendarId: calId, eventId: eventId)
            if let event = fetchedEvent {
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: calId,
                        calendarName: calendarName, translator: ctx.translator
                    )
                }
            }
        } else if let provider {
            let defaultCalId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
            fetchedEvent = try? await provider.getEvent(calendarId: defaultCalId, eventId: eventId)
            if let event = fetchedEvent {
                // Update cache with discovered calendarId for this session
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: defaultCalId,
                        calendarName: nil, translator: ctx.translator
                    )
                }
            }
        }

        // 🚨 A DELETE IS NOT CONFIRMABLE ON AN UNESTABLISHED IDENTITY (R12-T2).
        // This mirrors `CalendarEventEditTool`'s existing refusal, verbatim in
        // shape, because the two tools were disagreeing and the DESTRUCTIVE one was
        // the permissive one. Without this guard the confirmation card rendered the
        // placeholder title "(Event)" with `Date()` for both ends — the user
        // confirmed THAT — and `queueCalendarDelete` then persisted an
        // irreversible delete against an href whose current occupant had never been
        // read. On CalDAV that reaches `CalDAVProvider.deleteEvent`, a WebDAV
        // `DELETE` for which RFC 4918/4791 define no trash, undelete or restore, so
        // being wrong there cannot be undone (C3).
        //
        // ⚠️ THIS IS NOT A DROPPED INTENTION, and the distinction is the whole
        // argument: the refusal happens BEFORE `queueCalendarOperation`, so no
        // `PendingCalendarOperation` row and no user-visible acknowledgement exists
        // yet. Never-drop governs intentions that were persisted or acknowledged;
        // this one is neither. The agent is handed a structured error naming the
        // re-lookup tools and can retry with a real id.
        //
        // ⚠️ THE COUNTERFACTUAL. Keeping the permissive path would buy exactly one
        // thing — deleting an event whose id we hold but cannot read (a transient
        // provider outage during the confirmation). That is recoverable by one
        // ordinary gesture (ask again once the provider answers). Its opposite,
        // deleting the wrong or an already-replaced event, is not recoverable at
        // all. Fail closed.
        guard let resolvedEvent = fetchedEvent else {
            print("[CalendarEventDeleteTool] Could not dereference event_id='\(eventId.prefix(50))' (compound='\(compoundId.prefix(50))') — refusing delete")
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_delete failed: could not find event with id '\(compoundId)'. The id may be wrong or the event may have been deleted. Call calendar_event_read or calendar_search to look up the correct event, then retry.",
                "event_id": compoundId,
            ] as [String: Any])
        }

        let confirmTitle = (resolvedEvent.summary ?? "").isEmpty ? "(No title)" : resolvedEvent.summary!
        let confirmStart = resolvedEvent.startDate ?? Date()
        let confirmEnd = resolvedEvent.endDate ?? Date()
        let confirmIsAllDay = resolvedEvent.isAllDay
        let confirmNotes = resolvedEvent.description

        // ADR-IOS-024: Show confirmation card and await user response
        let (confirmed, cardState) = await AgentToolRouter.ActionConfirmation.awaitConfirmation(
            action: .calendarEventDelete,
            calendarEvents: [.init(
                eventId: eventId,
                calendarId: calendarName ?? "",
                title: confirmTitle,
                startDate: confirmStart,
                endDate: confirmEnd,
                isAllDay: confirmIsAllDay,
                notes: confirmNotes
            )],
            via: invocation.uiSink
        )

        guard confirmed else {
            print("[CalendarEventDeleteTool] User declined delete for event_id=\(eventId)")
            throw ToolDeclinedError(output: ToolJSON.string(from: [
                "cancelled": true,
                "message": "User declined to delete this event.",
            ] as [String: Any]))
        }

        guard !resolvedAccountId.isEmpty else {
            return CalendarProviderDispatch.notAvailableMessage
        }
        return try await queueCalendarDelete(accountId: resolvedAccountId, calendarId: calendarId, eventId: eventId, compoundId: compoundId, arguments: arguments, cardState: cardState)
    }

    // MARK: - Calendar (Queued)

    private func queueCalendarDelete(accountId: String, calendarId: String?, eventId: String, compoundId: String, arguments: [String: JSONValue], cardState: AgentToolRouter.ActionConfirmation.ResponseState) async throws -> String {
        let manager = AccountManager.shared
        let op = try await manager.queueCalendarOperation(
            type: .delete,
            accountId: accountId,
            eventId: eventId,
            calendarId: calendarId,
            arguments: arguments
        )

        // Evict cached details — event is being deleted
        await ctx.translator.evictEventDetail(realId: compoundId)
        print("[CalendarEventDeleteTool] Queued delete (op: \(op.id), event: \(eventId))")

        // Mirror edit/create: wait briefly for the drain to surface a terminal
        // outcome so a provider-side failure (404, permission denied, etc.)
        // flips the card to its failed state and tells the LLM the truth.
        let outcome = await manager.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 10.0)
        if case .permanentFailure(let reason) = outcome {
            print("[CalendarEventDeleteTool] Permanent failure for op \(op.id): \(reason)")
            await MainActor.run { cardState.failureReason = reason }
            return ToolJSON.string(from: [
                "ok": false,
                "error": "calendar_event_delete failed: \(reason). The event was NOT deleted.",
                "event_id": compoundId,
            ] as [String: Any])
        }
        let confirmedSync: Bool = if case .success = outcome { true } else { false }
        return [
            confirmedSync ? "Calendar event deleted successfully." : "Calendar event deletion queued successfully.",
            "event_id: \(compoundId)",
            confirmedSync ? nil : "The event will be removed from the calendar shortly. Cancellation notices will be sent to attendees.",
        ].compactMap { $0 }.joined(separator: "\n")
    }
}
