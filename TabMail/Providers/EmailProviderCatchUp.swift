/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Catch-up of older mail (ADR-IOS-107)
//
// The provider-blind seam through which a full-sync pass learns about server-side
// changes to mail no other sync path looks at again: a read or flag change, or a
// removal, on a message older than every sync window. The full sync calls
// `EmailProvider.catchUp` ONCE per pass with all of the pass's syncable folders and
// applies whatever comes back through its existing paths. Everything provider-specific
// (whether a folder needs a listing, how a listing resumes, what proves a removal)
// lives below this seam, encoded in an opaque per-folder state string only the
// provider reads.

/// One local row as `CatchUpLocalRowReader` returns it: the provider id and the two
/// flags the catch-up compares. Never message content (ADR-004).
struct CatchUpLocalRow: Sendable, Equatable {
    /// `MessageHeader.messageId` — the UID as a string for IMAP, the provider's own
    /// message id elsewhere.
    let messageId: String
    let isRead: Bool
    let isFlagged: Bool
}

/// Read access to a folder's local rows, by range, so a provider can compare a
/// listing against them a slice at a time instead of loading a whole folder.
protocol CatchUpLocalRowReader: Sendable {
    /// Rows whose id, read as an integer, lies in `lower...upper`, ascending by
    /// that integer (IMAP: a UID range).
    func rows(folderId: String, numericIdsFrom lower: Int, through upper: Int) async throws -> [CatchUpLocalRow]
    /// The smallest id, read as an integer, that is `>= lower`, or nil when none is.
    func firstNumericId(folderId: String, atLeast lower: Int) async throws -> Int?
    /// Rows for exactly these provider ids. Ids with no local row are absent.
    func rows(folderId: String, ids: [String]) async throws -> [CatchUpLocalRow]
    /// Up to `limit` rows in ascending provider-id order, after `afterId`
    /// (nil starts at the beginning) — an ordered scan of the whole folder.
    func rows(folderId: String, after afterId: String?, limit: Int) async throws -> [CatchUpLocalRow]
}

/// What one catch-up call may spend and on what kind of network. A value snapshot
/// taken by the caller at the start of the operation (root rule: snapshot settings
/// at operation start); the provider never re-reads the network state itself.
struct CatchUpContext: Sendable {
    /// `NetworkMonitor.checkExpensive()` as it stood when the pass began.
    let isExpensiveNetwork: Bool
    /// No request may START at or after this instant.
    let deadline: Date
    /// The clock the budget is measured on. Injectable so a test can spend the
    /// budget deterministically; production passes `Date.init`.
    let clock: @Sendable () -> Date

    /// The production snapshot: the budget starts now.
    static func forPass(isExpensiveNetwork: Bool) -> CatchUpContext {
        let now = Date()
        return CatchUpContext(
            isExpensiveNetwork: isExpensiveNetwork,
            deadline: now.addingTimeInterval(SyncConfig.catchUpPassBudgetSeconds),
            clock: { Date() })
    }

    /// Checked before EVERY request: false once the pass budget is spent.
    func hasBudget() -> Bool { clock() < deadline }
}

/// A read/flag state the server reported for one existing message.
struct CatchUpFlagUpdate: Sendable, Equatable {
    let messageId: String
    let isRead: Bool
    let isFlagged: Bool
}

/// The provider-blind result for one folder. The full sync applies it in one write
/// transaction together with `newState`.
struct CatchUpFolderResult: Sendable {
    let folderId: String
    /// The id epoch every id below belongs to (IMAP: the UIDVALIDITY of the SELECTs
    /// that produced them), or nil for a provider whose ids carry no epoch. The full
    /// sync applies nothing unless this equals the folder's stored known epoch; a
    /// result whose epoch DIFFERS from a known stored one reports a turnover.
    let epoch: UInt32?
    /// Changes to rows the device already holds. There is no field for a message
    /// without a local row: the catch-up never inserts (ADR-IOS-107).
    var flagUpdates: [CatchUpFlagUpdate] = []
    /// Provider ids the server has PROVEN absent. They go through the one removal
    /// path (`SyncEngine.deleteConfirmedGhostHeaders`).
    var removedIds: [String] = []
    /// The folder's new opaque state, written in the same transaction as the
    /// results. Nil clears it.
    var newState: String?
}

extension EmailProvider {
    /// Default: no catch-up. A provider without support (Gmail, Exchange and Demo
    /// until their own catch-up lands) returns nothing, and the full sync then
    /// writes nothing.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        []
    }
}
