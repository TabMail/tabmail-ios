/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// Why an account's still-queued calendar changes wait (#865) is the wait reason of the account's
// FIRST queued change in queue order: the drain stops an account at its first failure, so every
// later change waits behind that one. `AccountManager.calendarWaitReason(accountId:)` reads it for a
// calendar tool's "queued" result. These cases pin the query against rows with fixed creation times:
// another account's head never answers, an in-flight head still answers, rows created at the same
// instant are all the head, and a stamped row behind an unstamped head does not answer.

@Suite("A calendar change's wait reason is its account's queue head's (#865)", .serialized, .processGlobalState)
struct CalendarWaitReasonQueryTests {

    /// A queued edit on `accountId`, created at `createdAt`, stamped with `reason` when given.
    private static func row(
        _ accountId: String, createdAt: Date, reason: CalendarWaitReason? = nil,
        status: PendingStatus = .queued
    ) -> PendingCalendarOperation {
        var op = PendingCalendarOperation(
            operationType: .edit, accountId: accountId, eventId: "ev-\(UUID().uuidString)", calendarId: "primary",
            arguments: ["title": .string("Planning (moved rooms)")], eventTitle: "Planning")
        op.createdAt = createdAt
        op.status = status.rawValue
        if let reason { op.setWaitReason(reason) }
        return op
    }

    /// Installs a fresh database holding `accounts` (the first through `CalendarQueueTestDatabase`),
    /// inserts `rows` in the order given, and returns each account's derived wait reason.
    private static func reasons(
        accounts: [String], rows: [PendingCalendarOperation]
    ) async throws -> [String: CalendarWaitReason?] {
        let db = try CalendarQueueTestDatabase(accountId: accounts[0])
        defer { db.finish() }
        try await db.pool.write { db in
            for id in accounts.dropFirst() {
                var acc = Account(emailAddress: "cal-\(id)@example.com", displayName: "Cal", provider: .gmail)
                acc.id = id
                try acc.insert(db)
            }
            for row in rows { try row.insert(db) }
        }
        var out: [String: CalendarWaitReason?] = [:]
        for id in accounts { out[id] = await AccountManager.shared.calendarWaitReason(accountId: id) }
        return out
    }

    /// Now, to the millisecond the database keeps, so equal instants stay equal once stored.
    private static let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000)

    @Test("another account's head waiting for space is not this account's reason")
    func anotherAccountsHeadDoesNotAnswer() async throws {
        let full = "wait-query-full", other = "wait-query-other"
        // The full account's head is the oldest row of all; the other account's change is newer.
        let r = try await Self.reasons(accounts: [full, other], rows: [
            Self.row(full, createdAt: Self.now.addingTimeInterval(-60), reason: .mailboxFull),
            Self.row(other, createdAt: Self.now),
        ])
        #expect(r[full] == .some(.mailboxFull), "fixture check: the full account's head does not answer: \(r)")
        #expect(r[other] == .some(nil), "the other account was told its change waits for a full mailbox: \(r)")
    }

    @Test("an in-flight head waiting for space is still the head of the changes queued behind it")
    func inFlightHeadAnswers() async throws {
        let account = "wait-query-in-flight"
        let r = try await Self.reasons(accounts: [account], rows: [
            Self.row(account, createdAt: Self.now.addingTimeInterval(-60), reason: .mailboxFull, status: .inFlight),
            Self.row(account, createdAt: Self.now),
        ])
        #expect(r[account] == .some(.mailboxFull), "a change behind an in-flight head was not told why it waits: \(r)")
    }

    @Test("rows created at the same instant are all the head: a stamp on either one answers", arguments: [0, 1])
    func tiedRowsAreAllTheHead(_ stamped: Int) async throws {
        let account = "wait-query-tie-\(stamped)"
        // Both orders of insertion, so whichever of the tied rows the query returns first, one case
        // has the stamp on the other.
        let tied = (0..<2).map { Self.row(account, createdAt: Self.now, reason: $0 == stamped ? .mailboxFull : nil) }
        let r = try await Self.reasons(accounts: [account], rows: tied + [
            Self.row(account, createdAt: Self.now.addingTimeInterval(60)),
        ])
        #expect(r[account] == .some(.mailboxFull), "a stamp on tied row \(stamped) of the head was not read: \(r)")
    }

    @Test("a stamp on a row behind an unstamped head is not the reason the queue waits")
    func stampBehindAnUnstampedHeadDoesNotAnswer() async throws {
        let account = "wait-query-behind"
        let r = try await Self.reasons(accounts: [account], rows: [
            Self.row(account, createdAt: Self.now.addingTimeInterval(60), reason: .mailboxFull),
            Self.row(account, createdAt: Self.now),
        ])
        #expect(r[account] == .some(nil), "a later row's stamp was read past an unstamped head: \(r)")
    }
}
