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
    var failureReason: String?

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
        arguments: [String: JSONValue]
    ) {
        self.id = UUID().uuidString
        self.operationType = operationType.rawValue
        self.accountId = accountId
        self.eventId = eventId
        self.calendarId = calendarId
        // Serialize arguments via JSONEncoder (JSONValue is Encodable)
        if let data = try? JSONEncoder().encode(arguments),
           let str = String(data: data, encoding: .utf8) {
            self.argumentsJSON = str
        } else {
            self.argumentsJSON = "{}"
        }
        self.status = PendingStatus.queued.rawValue
        self.createdAt = Date()
        self.retryCount = 0
        self.failureReason = nil
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
