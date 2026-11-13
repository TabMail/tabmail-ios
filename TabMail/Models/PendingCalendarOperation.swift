/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

enum CalendarOperationType: String, Codable, Sendable {
    case create
    case edit
    case delete
}

struct PendingCalendarOperation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "pendingCalendarOperation"

    var id: String
    var operationType: String
    var accountId: String
    /// Google Calendar event ID (required for edit/delete; for create, pre-generated for idempotency)
    var eventId: String?
    /// Calendar ID where the event lives (for edit/delete). Nil = use preferred calendar (legacy/create).
    var calendarId: String?
    /// Full tool arguments serialized as JSON (replayed during drain)
    var argumentsJSON: String
    var status: String
    var createdAt: Date
    var retryCount: Int
    /// Why a terminal arm retired this operation (R16-1). Non-nil exactly when
    /// `status == PendingStatus.failed.rawValue`.
    ///
    /// 🚨 THIS COLUMN IS THE DURABLE HALF OF THE TERMINAL OUTCOME. The drain used
    /// to report a permanent failure only through `signalCalendarOpOutcome`, an
    /// in-memory continuation registered by the calendar tool that queued the op —
    /// and five of the six drain triggers can never have one, while the sixth loses
    /// it after the tool's 10 s wait. The row was deleted in the same breath, so an
    /// op that failed after the agent had already told the user *"queued … will
    /// appear on the calendar shortly"* left no record anywhere. Writing the reason
    /// in the SAME write that retires the row is what makes the outcome outlive the
    /// waiter.
    ///
    /// This text is for the assistant and the logs, never for the user. The inbox banner
    /// for a failure nobody saw (`LateCalendarFailureStore`) reads `failureKind` instead.
    var failureReason: String?

    /// The reserved key in `argumentsJSON` for the event's title as the confirmation card
    /// showed it, so a late failure can name the event (an edit or delete carries no title
    /// of its own). Only `init` writes it, from its `eventTitle`; a tool call that carries
    /// it in its arguments has it removed there. No provider reads it.
    static let eventTitleKey = "_event_title"

    /// The event's title as the card showed it, or nil when the row has none.
    var eventTitle: String? {
        guard case .string(let title)? = arguments[Self.eventTitleKey], !title.isEmpty else { return nil }
        return title
    }

    /// The reserved key in `argumentsJSON` for the kind of a terminal failure
    /// (`CalendarFailureKind`), written with the retirement (`retireCalendarOperation`).
    static let failureKindKey = "_failure_kind"

    /// The reserved key in `argumentsJSON` marking a failure as seen: the tool that queued it
    /// was still waiting and its card showed it (`retireAndAnnounce`), so the inbox does not.
    static let failureSeenKey = "_failure_seen"

    /// The kind of this row's terminal failure, or nil when it has none (not retired, or
    /// retired by an app version that did not record it).
    var failureKind: CalendarFailureKind? {
        guard case .string(let raw)? = arguments[Self.failureKindKey] else { return nil }
        return CalendarFailureKind(rawValue: raw)
    }

    /// Whether this row's failure was already shown on its card.
    var failureSeen: Bool {
        if case .bool(true)? = arguments[Self.failureSeenKey] { return true }
        return false
    }

    /// The keys only the queue writes. A tool call that carries one has it removed in `init`.
    static let reservedKeys = [eventTitleKey, failureKindKey, failureSeenKey]

    /// Set reserved keys in `argumentsJSON`, keeping every other argument.
    mutating func setReservedArguments(_ values: [String: JSONValue]) {
        argumentsJSON = Self.encode(arguments.merging(values) { _, new in new })
    }

    /// Decoded arguments from JSON storage
    var arguments: [String: JSONValue] {
        guard let data = argumentsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return raw.mapValues { PendingCalendarOperation.toJSONValue($0) }
    }

    init(
        operationType: CalendarOperationType,
        accountId: String,
        eventId: String? = nil,
        calendarId: String? = nil,
        arguments: [String: JSONValue],
        eventTitle: String? = nil
    ) {
        self.id = UUID().uuidString
        self.operationType = operationType.rawValue
        self.accountId = accountId
        self.eventId = eventId
        self.calendarId = calendarId
        var arguments = arguments
        for key in Self.reservedKeys { arguments.removeValue(forKey: key) }
        if let eventTitle { arguments[Self.eventTitleKey] = .string(eventTitle) }
        self.argumentsJSON = Self.encode(arguments)
        self.status = PendingStatus.queued.rawValue
        self.createdAt = Date()
        self.retryCount = 0
        self.failureReason = nil
    }

    /// Serialize arguments via JSONEncoder (JSONValue is Encodable).
    private static func encode(_ arguments: [String: JSONValue]) -> String {
        if let data = try? JSONEncoder().encode(arguments),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// Convert Foundation Any to JSONValue for argument replay.
    /// JSONSerialization returns NSNumber for both booleans and numbers.
    /// Uses CFBoolean type check to distinguish them (NSNumber `as? Bool` matches integers too).
    private static func toJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let arr as [Any]: return .array(arr.map { toJSONValue($0) })
        case let dict as [String: Any]: return .dictionary(dict.mapValues { toJSONValue($0) })
        case let num as NSNumber:
            if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            } else if num.doubleValue != Double(num.intValue) {
                return .double(num.doubleValue)
            } else {
                return .int(num.intValue)
            }
        default: return .string("\(value)")
        }
    }

    /// Generate a Google Calendar-compatible event ID from our UUID.
    /// Google requires: 5-1024 chars, lowercase a-v and digits 0-9.
    /// We use a "tm" prefix + UUID hex (lowercase, no hyphens).
    static func generateGoogleEventId(from uuid: String) -> String {
        return "tm" + uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
