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

/// Why a calendar change is still queued, when the user can do something about it: written on the
/// queued row by the drain's transient arm (`PendingCalendarOperation.waitReasonKey`), so the inbox
/// can say it. The change is still made once the cause is gone (#865).
enum CalendarWaitReason: String, Sendable, CaseIterable {
    /// The mailbox is over its storage quota (`ExchangeCalendarError.mailboxFull`).
    case mailboxFull

    /// The plain line the inbox shows for this reason.
    var userReason: String {
        switch self {
        case .mailboxFull: return "Your Outlook mailbox is full. Free up space and it will go through."
        }
    }

    /// The clause a calendar tool's "queued" result adds, so the model can tell the user why.
    var toolClause: String {
        switch self {
        case .mailboxFull: return "waiting because the Outlook mailbox is full"
        }
    }
}

/// A queued calendar change waiting for a reason the user can act on.
struct WaitingCalendarChange: Identifiable, Equatable, Sendable {
    /// The `PendingCalendarOperation.id` of the queued operation.
    let id: String
    let title: String
    let reason: CalendarWaitReason

    /// The inbox banner's line.
    var bannerText: String {
        "A calendar change is waiting: \(title). \(reason.userReason)"
    }
}

/// A queued calendar change that failed for good where nobody saw it: after the chat turn
/// that queued it had ended, or in a drain no chat turn started.
struct LateCalendarFailure: Identifiable, Equatable, Sendable {
    /// The `PendingCalendarOperation.id` of the retired operation.
    let id: String
    let title: String
    let kind: CalendarFailureKind
    /// The files of changed occurrences the change saved on this device and could not attach
    /// again (#718): kept with the row until the user saves or dismisses them. Empty for any
    /// other failure.
    var heldFiles: [PutBackFile] = []

    /// Whether the row holds saved files, so dismissing it deletes them.
    var holdsFiles: Bool { !heldFiles.isEmpty }

    /// The inbox banner's line.
    var bannerText: String {
        guard holdsFiles else { return "A calendar change couldn't be made: \(title). \(kind.userReason)" }
        return "A calendar change wasn't finished: \(title). \(PutBackFile.notRestoredMessage(heldFiles.count))"
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
///
/// It also reads the changes still queued with a wait reason (`waiting`): a queued or in-flight
/// row whose last attempt gave a reason the user can act on, such as a full mailbox (#865).
@MainActor
@Observable
final class LateCalendarFailureStore {
    static let shared = LateCalendarFailureStore()

    /// The failures to show, oldest first.
    private(set) var failures: [LateCalendarFailure] = []

    /// The changes still queued for a reason the user can act on, oldest first. Each goes when its
    /// change is made or fails for good; there is nothing to dismiss.
    private(set) var waiting: [WaitingCalendarChange] = []

    /// Counts reloads, so an older read that finishes last does not overwrite a newer one.
    private var reloadGeneration = 0

    init() {}

    /// Read the failures again from the database.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let rows: [PendingCalendarOperation]
        let queued: [PendingCalendarOperation]
        do {
            (rows, queued) = try await AppDatabase.dbPool.read { db in
                let failed = try PendingCalendarOperation
                    .filter(Column("status") == PendingStatus.failed.rawValue)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
                let pending = try PendingCalendarOperation
                    .filter([PendingStatus.queued.rawValue, PendingStatus.inFlight.rawValue].contains(Column("status")))
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
                return (failed, pending)
            }
        } catch {
            BackgroundSyncLogger.logError(
                "[CalendarQueue] could not read failed calendar changes for the inbox: \(error)",
                source: "CalendarQueue")
            return
        }
        guard generation == reloadGeneration else { return }
        failures = rows.compactMap { row in
            // A row holding saved files is shown until the user dismisses it, seen or not: its
            // files are the only copy (#718).
            let held = CalendarPutBackFiles.holdsBytes(row.id) ? (((try? SeriesEditRecord.stored(row.arguments)) ?? nil)?.files ?? []) : []
            guard let kind = row.failureKind, !row.failureSeen || !held.isEmpty else { return nil }
            return LateCalendarFailure(id: row.id, title: row.eventTitle ?? "(No title)", kind: kind, heldFiles: held)
        }
        waiting = queued.compactMap { row in
            guard let reason = row.waitReason else { return nil }
            return WaitingCalendarChange(id: row.id, title: row.eventTitle ?? "(No title)", reason: reason)
        }
    }

    /// Dismiss a failure: its row is deleted, so it is not shown again. When the delete
    /// fails the banner stays and the user can dismiss it again. A failure holding saved files
    /// (`holdsFiles`) is dismissed only after the user was warned (the banner's confirmation);
    /// its files are deleted once the row's deletion committed (#718).
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
        if failure.holdsFiles { CalendarPutBackFiles.remove(opId: failure.id) }
        failures.removeAll { $0.id == failure.id }
    }

    /// The saved files of one calendar operation (#718).
    struct HeldFiles: Sendable {
        let opId: String
        let files: [PutBackFile]
    }

    /// The saved files of every calendar operation of the account `accountId`, whatever its
    /// status: what removing the account deletes. Empty when none, or when the rows can't be read.
    nonisolated static func heldFiles(accountId: String) async -> [HeldFiles] {
        let held = CalendarPutBackFiles.heldOperationIds()
        guard !held.isEmpty else { return [] }
        let rows = (try? await AppDatabase.dbPool.read { db in
            try PendingCalendarOperation.filter(Column("accountId") == accountId).fetchAll(db)
        }) ?? []
        return rows.filter { held.contains($0.id) }.map { row in
            HeldFiles(opId: row.id, files: ((try? SeriesEditRecord.stored(row.arguments)) ?? nil)?.files ?? [])
        }
    }

    /// Copies of the saved files `held` under their own names, for the share sheet.
    nonisolated static func exportFiles(_ held: [HeldFiles]) throws -> [URL] {
        try held.flatMap { try CalendarPutBackFiles.exportCopies(of: $0.files, opId: $0.opId) }
    }

    /// Copies of a failure's saved files under their own names, for the share sheet ("Save
    /// File"). Throws when a copy can't be read or written.
    func exportFiles(of failure: LateCalendarFailure) throws -> [URL] {
        try CalendarPutBackFiles.exportCopies(of: failure.heldFiles, opId: failure.id)
    }
}
