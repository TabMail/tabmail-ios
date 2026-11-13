/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Why the calendar queue retired a change for good: one case per terminal arm of
/// `AccountManager.drainCalendarQueue`. Stored with the retired row
/// (`PendingCalendarOperation.failureKindKey`), so the inbox can say it in plain words.
enum CalendarFailureKind: String, Sendable, CaseIterable {
    /// The event is gone from the calendar.
    case notFound
    /// The account has not granted calendar access.
    case missingPermission
    /// The calendar account's sign-in was refused.
    case signInFailed
    /// This calendar can't make this change.
    case unsupported
    /// The calendar refused the request as malformed.
    case refused

    /// The plain line the inbox shows for this kind. The stored `failureReason` is text for
    /// the assistant and is never shown.
    var userReason: String {
        switch self {
        case .notFound: return "The event no longer exists."
        case .missingPermission: return "TabMail doesn't have permission to change this calendar."
        case .signInFailed: return "The calendar account needs you to sign in again."
        case .unsupported: return "This calendar can't make this kind of change."
        case .refused: return "The calendar refused the change."
        }
    }
}

/// A queued calendar change that failed for good where nobody saw it: after the chat turn
/// that queued it had ended, or in a drain no chat turn started.
struct LateCalendarFailure: Identifiable, Equatable, Sendable {
    /// The `PendingCalendarOperation.id` of the retired operation.
    let id: String
    let title: String
    let kind: CalendarFailureKind

    /// The inbox banner's line.
    var bannerText: String {
        "A calendar change couldn't be made: \(title). \(kind.userReason)"
    }
}

/// The calendar changes the inbox shows as failed, read from the database.
///
/// The database is the whole state: a `pendingCalendarOperation` row with status
/// `failed`, a failure kind and no seen mark is a failure nobody has seen. The drain
/// marks a failure the queueing tool's card already showed as seen
/// (`AccountManager.retireAndAnnounce`), so every row shown here is shown once, after a
/// relaunch too, until the user dismisses it. Dismiss deletes the row. Nothing is
/// retried. A row retired by an app version that recorded no kind is not shown.
@MainActor
@Observable
final class LateCalendarFailureStore {
    static let shared = LateCalendarFailureStore()

    /// The failures to show, oldest first.
    private(set) var failures: [LateCalendarFailure] = []

    /// Counts reloads, so an older read that finishes last does not overwrite a newer one.
    private var reloadGeneration = 0

    init() {}

    /// Read the failures again from the database.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let rows: [PendingCalendarOperation]
        do {
            rows = try await AppDatabase.dbPool.read { db in
                try PendingCalendarOperation
                    .filter(Column("status") == PendingStatus.failed.rawValue)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            BackgroundSyncLogger.logError(
                "[CalendarQueue] could not read failed calendar changes for the inbox: \(error)",
                source: "CalendarQueue")
            return
        }
        guard generation == reloadGeneration else { return }
        failures = rows.compactMap { row in
            guard let kind = row.failureKind, !row.failureSeen else { return nil }
            return LateCalendarFailure(id: row.id, title: row.eventTitle ?? "(No title)", kind: kind)
        }
    }

    /// Dismiss a failure: its row is deleted, so it is not shown again. When the delete
    /// fails the banner stays and the user can dismiss it again.
    func dismiss(_ failure: LateCalendarFailure) async {
        do {
            try await AppDatabase.dbPool.write { db in
                _ = try PendingCalendarOperation
                    .filter(Column("id") == failure.id)
                    .filter(Column("status") == PendingStatus.failed.rawValue)
                    .deleteAll(db)
            }
        } catch {
            BackgroundSyncLogger.logError(
                "[CalendarQueue] could not dismiss failed calendar change \(failure.id): \(error)",
                source: "CalendarQueue")
            return
        }
        failures.removeAll { $0.id == failure.id }
    }
}
