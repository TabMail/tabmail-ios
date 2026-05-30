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
        var confirmTitle = "(Event)"
        var confirmStart = Date()
        var confirmEnd = Date()
        var confirmIsAllDay = false
        var confirmNotes: String?

        let provider: (any CalendarProvider)?
        if !resolvedAccountId.isEmpty {
            provider = await AccountManager.shared.calendarProviders[resolvedAccountId]
        } else {
            provider = await CalendarProviderDispatch.resolve(db: ctx.db).resolved?.provider
        }

        if let provider, let calId = calendarId {
            if let event = try? await provider.getEvent(calendarId: calId, eventId: eventId) {
                confirmTitle = (event.summary ?? "").isEmpty ? "(No title)" : event.summary!
                confirmStart = event.startDate ?? Date()
                confirmEnd = event.endDate ?? Date()
                confirmIsAllDay = event.isAllDay
                confirmNotes = event.description
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: calId,
                        calendarName: calendarName, translator: ctx.translator
                    )
                }
            }
        } else if let provider {
            let defaultCalId = await CalendarProviderDispatch.defaultCalendarIdForCreation(for: provider)
            if let event = try? await provider.getEvent(calendarId: defaultCalId, eventId: eventId) {
                confirmTitle = (event.summary ?? "").isEmpty ? "(No title)" : event.summary!
                confirmStart = event.startDate ?? Date()
                confirmEnd = event.endDate ?? Date()
                confirmIsAllDay = event.isAllDay
                confirmNotes = event.description
                // Update cache with discovered calendarId for this session
                Task {
                    await CalendarToolHelpers.cacheEventDetailsForPills(
                        [event], accountId: resolvedAccountId, calendarId: defaultCalId,
                        calendarName: nil, translator: ctx.translator
                    )
                }
            }
        }

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
            )]
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
