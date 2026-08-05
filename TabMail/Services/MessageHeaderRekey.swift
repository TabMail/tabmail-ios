/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The destination address the wire already gave us

/// One member's destination address, exactly as the server itself named it in
/// its answer to the move THIS operation issued.
///
/// THE ADDRESS PROBLEM, closed where it is created. A `PendingOperation` names
/// its members by their address in the SOURCE folder, and on IMAP an address is
/// `(folder, UID, UIDVALIDITY)`. **A move changes that address**, and the server
/// hands us the new one in `COPYUID` — which `IMAPProvider.copyProvenSourceUIDs`
/// reads only to VALIDATE and then discards. This type is that discarded half,
/// carried to the drain so the move can be finished LOCALLY instead of being
/// repaired later by sync on weaker (RFC 822) evidence.
///
/// 🚨 **PROVIDER-NEUTRAL, because the discard was never IMAP-specific.** The
/// identical sentence is true of Microsoft Graph: `POST /messages/{id}/move`
/// answers with the moved message **carrying its new `id`**, Graph ids churn on
/// every folder move by default (no `Prefer: IdType="ImmutableId"` is sent
/// anywhere in this app), and `ExchangeProvider.moveMessage` bound that response
/// to `_`. The two address spaces differ only in what an address IS — a UID
/// inside an epoch on IMAP, an opaque resource id with NO epoch space on Graph —
/// so the id is a `String` and the epoch is OPTIONAL. `KNOWN_ISSUES.md`
/// `IOS-GRAPH-002`, `MIS-IOS-003` instance 5, `MIS-006` instance 5.
///
/// ⚠ NOT an rfc822 Message-ID, and never derived from one. ADR-IOS-068 / D4
/// forbids the Message-ID as mutation authority and forbids a `SEARCH` result
/// from ever being a mutation target. The authority here is the wire's own
/// answer to the move THIS operation issued — attempt-correlated by
/// construction, and strictly stronger than any identity probe.
struct ProvenDestinationAddress: Sendable, Equatable {
    /// The provider id the operation named — the SOURCE UID as a string on
    /// IMAP, the source Graph resource id on Exchange.
    let sourceProviderId: String
    /// The provider id the server assigned to the copy it created in the
    /// destination — the destination UID as a string on IMAP, the `id` of the
    /// message resource Graph returned from `/move` on Exchange.
    let destinationProviderId: String
    /// The destination address space's epoch, when the provider HAS one: the
    /// destination mailbox's UIDVALIDITY, stamped on the same `COPYUID`.
    ///
    /// **`nil` means the provider has no epoch space at all** (Graph), NOT that
    /// an epoch was expected and went missing — `IMAPProvider.move` refuses
    /// before any wire mutation when a destination epoch is unreadable, so it
    /// never reaches this type unset. `finishMove`'s G2 leaves the row's stamp
    /// unread for a `nil` epoch, which is both the correct value and the safe
    /// one (see G2).
    let destinationUidValidity: UInt32?
}

/// What one provider move attempt DISPOSITIONED, and where the server said the
/// copies landed.
///
/// Top-level rather than nested in `IMAPProvider` because it has TWO producers:
/// `IMAPProvider.move(ids:from:to:admittedUidValidity:)` and
/// `ExchangeProvider.moveProvingDestinations(ids:from:to:)`. Both feed the same
/// consumer — `AccountManagerQueue.executeOperation`'s `.move` case — so one
/// type keeps the two arms from drifting.
struct MoveOutcome: Sendable {
    /// The subset of the requested ids this attempt DISPOSITIONED (per-member
    /// retirement, B-2).
    let provenIds: [String]
    /// Per-member destination addresses the server itself named. Never a
    /// superset of `provenIds`; frequently empty.
    let provenDestinations: [ProvenDestinationAddress]
}

/// One applied re-key. The local row that used to live at `oldHeaderId` now
/// lives at `newHeaderId` and carries `newProviderMessageId`.
///
/// Consumed OUTSIDE the GRDB write by the two stores that key by
/// `messageHeader.id` but do not live in that database: the FTS index
/// (`SearchIndex.rekeyHeaders`, a separate SQLite pool) and the in-memory undo
/// stack (`UndoService.applyRekeys`).
struct HeaderRekeyRecord: Sendable, Equatable {
    let oldHeaderId: String
    let newHeaderId: String
    let newProviderMessageId: String
}

// MARK: - The re-key itself

enum MessageHeaderRekey {

    /// Re-key ONE local header row to a new primary key, carrying every child
    /// row the delete would otherwise destroy.
    ///
    /// **EXTRACTED, NOT INVENTED.** This is the sequence
    /// `SyncEngine.runSyncMessages` has always run for a UID remap (the block
    /// that logs `[Sync] UID remap:`), lifted here so the drain can run the
    /// IDENTICAL re-key EARLIER, authorized by the server's own `COPYUID`
    /// rather than by an RFC 822 match. Both callers share this body, so the
    /// two paths cannot drift.
    ///
    /// **ORDERING IS LOAD-BEARING.** The body fetch, the user-label capture and
    /// BOTH deletes must precede EVERY exit — including the collision return —
    /// or the leg that skips the re-insert still leaves the orphan behind. The
    /// `messageBody` FK cascade that used to reclaim the body row is gone as of
    /// Stage D, so the delete is explicit.
    ///
    /// **THE TWO CHILD TABLES THAT CASCADE**, both declared
    /// `.references("messageHeader", onDelete: .cascade)` in `AppDatabase`, and
    /// both silently destroyed by the delete unless handled here:
    ///  - `messageReference` (threading references) is **REBUILT** from the
    ///    migrated header's own `References` / `In-Reply-To` content, so the
    ///    rebuild is exact — the header carries its own source of truth.
    ///  - `messageUserLabel` (user-assigned labels) has **NO rebuild source**;
    ///    nothing else in the database knows which labels the user applied. It
    ///    is therefore **CAPTURED before the delete and re-inserted under the
    ///    new id**, the same shape as the body. Losing it is silent loss of
    ///    user state, which is why this one is carry-forward and not rebuild.
    ///
    /// Still orphaned by id and deliberately out of scope (pre-existing, and
    /// unchanged by this helper): `bodyAsset`, `pendingRender`, `chatIdMapping`.
    /// None of them is FK-bound to `messageHeader`; each is swept by its own
    /// headerId-prefix maintenance path.
    ///
    /// - Returns: `true` when `migrated` was inserted. `false` when a row
    ///   already occupies the new id — in which case the old row is still gone,
    ///   which is the pre-existing behaviour of the sync path's `continue`
    ///   (the new id is the survivor and the old id's FTS entry is dropped by
    ///   the caller's ordinary stale handling rather than re-keyed).
    @discardableResult
    static func apply(from old: MessageHeader, to migrated: MessageHeader, db: Database) throws -> Bool {
        let oldId = old.id
        let newId = migrated.id
        // Everything the delete destroys is read FIRST — see "ORDERING IS
        // LOAD-BEARING" above. Both deletes then run unconditionally, so the
        // collision return below cannot leave a duplicate plus a leak.
        let oldBody = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId))
        let carriedLabels = try MessageUserLabel
            .filter(Column("messageId") == oldId)
            .fetchAll(db)
        try old.delete(db)
        _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
        // Defensive — if a concurrent path already inserted this id, skip
        // instead of throwing UNIQUE.
        guard try MessageHeader.fetchOne(db, key: newId) == nil else { return false }
        try migrated.insert(db)
        if var body = oldBody {
            body.id = ContentKey(rawValue: newId)
            try body.insert(db)
        }
        for label in carriedLabels {
            var carried = label
            carried.messageId = newId
            try carried.insert(db)
        }
        try ThreadUtils.insertMessageReferences(for: migrated, db: db)
        return true
    }

    /// FINISH THE MOVE LOCALLY: re-key each member this attempt's `COPYUID`
    /// named, from its source address to the destination address the server
    /// itself assigned.
    ///
    /// Called from inside the SAME write transaction that deletes the completed
    /// `PendingOperation`, so the crash window is no worse than today's: either
    /// the op is retired and the rows are re-keyed, or neither happened and the
    /// op re-executes (idempotently).
    ///
    /// WHY THIS EXISTS. `AccountManagerActions.optimisticMoveToFolder` moves the
    /// row's `folderId`/`folderPath` to the destination, NILS
    /// `observedUidValidity`, and leaves the primary key and `messageId` at
    /// their SOURCE values. Until something repairs that, the row is refused by
    /// `admittedOrdinaryActionTargets` (which requires a live epoch and a
    /// parseable UID), so **the user's next gesture on a just-moved message is
    /// a silent dead no-op** — swipe-archive, then swipe-delete from Archive,
    /// and nothing happens at all. Sync's UID-remap path repairs it eventually,
    /// but only if the remnant is selected as stale (which compares a SOURCE UID
    /// against the DESTINATION folder's UID floor — two different address
    /// spaces) AND its rfc822 Message-ID matches a new remote message. Either
    /// can fail permanently.
    ///
    /// **THE FOUR GUARDS**, each closing a specific hazard:
    ///
    /// **G1 — pairing** is enforced upstream in
    /// `IMAPProvider.copyProvenDestinations`, because it is a property of the
    /// whole `COPYUID` response rather than of one member.
    ///
    /// **G2 — the epoch stamp is the MIRROR-IMAGE guard.** The stamp is written
    /// only when the epoch the server reported EQUALS the destination
    /// `Folder.lastKnownUidValidity`; otherwise the row is re-keyed and the
    /// stamp is left NIL. `Folder.lastKnownUidValidity` is written only by sync
    /// paths, so a drain-time stamp can leave the row FRESHER than the folder
    /// row — and `AccountManagerActions.roleMoveRejectDispositions` treats a
    /// POSITIVE disagreement (`observed != nil && observed != liveEpoch`) as
    /// `.terminalStale`, its ONLY terminal arm. Stamping optimistically would
    /// therefore TERMINALLY DROP the user's next gesture: the exact inverse of
    /// the bug this function fixes. A nil stamp is `.retainedForRetry`, which is
    /// recoverable by the next sync of that folder.
    ///
    /// **A provider with NO epoch space takes the same nil arm, and for the same
    /// reason.** Graph has no UIDVALIDITY, so `destinationUidValidity` is `nil`
    /// and the stamp is left unread. That is not a degraded case: an invented
    /// stamp on an Exchange row would be a *positive* disagreement with the
    /// folder's own `nil`, i.e. the terminal arm again. Nil is both the true
    /// value and the safe one.
    ///
    /// **G3 — collision and TOCTOU.** The row must still be the one THIS
    /// operation moved (same account, same provider id, still sitting in this
    /// op's destination folder); a vanished or already-repaired row is a
    /// no-op, and a new id that is already occupied is skipped by
    /// `apply(from:to:db:)`. GRDB's single writer serializes this against a
    /// concurrent sync, so this is an ordering concern, never corruption.
    ///
    /// **G4 — unchanged behaviour when `COPYUID` does not name the member.**
    /// The decision is PER MEMBER, never per operation: a batch can be partly
    /// addressable, and an unnamed member simply keeps today's behaviour (the
    /// remnant survives until sync repairs it).
    ///
    /// - Parameter onCollidedRekey: called with the OLD header id of each member
    ///   whose re-key hit the collision return of `apply(from:to:db:)` — the old
    ///   row is gone and nothing was re-keyed to take its place. A caller that
    ///   mirrors this table into a store keyed by `messageHeader.id` MUST drop
    ///   that id there, or the store keeps an entry with no header behind it
    ///   (the *indexed but unfindable* class). The sync path already does this
    ///   via its own `staleIds` disposition; the drain does it through this
    ///   channel, so both callers converge on one outcome. Defaulted because it
    ///   is auxiliary: a caller that keeps no store outside this database has
    ///   nothing to compensate, and the applied records alone describe it.
    /// - Returns: the re-keys actually applied, for the callers that must
    ///   mirror them into stores outside this database.
    static func finishMove(
        _ op: PendingOperation,
        destinations: [ProvenDestinationAddress],
        db: Database,
        onCollidedRekey: (String) -> Void = { _ in }
    ) throws -> [HeaderRekeyRecord] {
        guard op.type == .move, !destinations.isEmpty,
              let destinationPath = op.destinationPath,
              destinationPath != op.folderPath
        else { return [] }

        let destinationFolderId = MessageIdentity.folderId(
            accountId: op.accountId, folderPath: destinationPath)
        // G2 — read the folder's OWN epoch; the stamp is admitted only if the
        // server's reported epoch agrees with it.
        let folderEpoch = try Folder.fetchOne(db, key: destinationFolderId)?.lastKnownUidValidity
        let memberIds = Set(op.messageIds)

        var applied: [HeaderRekeyRecord] = []
        for destination in destinations {
            // G4 — a destination this operation never named is not this
            // operation's business.
            guard memberIds.contains(destination.sourceProviderId) else { continue }
            let oldId = MessageIdentity.headerId(
                accountId: op.accountId, folderPath: op.folderPath,
                messageId: destination.sourceProviderId)
            let newMessageId = destination.destinationProviderId
            let newId = MessageIdentity.headerId(
                accountId: op.accountId, folderPath: destinationPath,
                messageId: newMessageId)
            guard newId != oldId else { continue }
            // G3 — only the exact row this operation optimistically moved. A
            // row that vanished, that a sync already canonicalized, or that a
            // later gesture moved elsewhere is left alone.
            guard let row = try MessageHeader.fetchOne(db, key: oldId),
                  row.accountId == op.accountId,
                  row.messageId == destination.sourceProviderId,
                  row.folderPath == destinationPath,
                  row.folderId == destinationFolderId
            else { continue }

            var migrated = row
            migrated.id = newId
            migrated.messageId = newMessageId
            // G2 — see the discussion above. Fresher-than-the-folder is worse
            // than unknown, because only the former is terminal. A provider
            // with no epoch space reports `nil` and takes the same arm.
            if let provenEpoch = destination.destinationUidValidity,
               folderEpoch == Int(provenEpoch) {
                migrated.observedUidValidity = Int(provenEpoch)
            } else {
                migrated.observedUidValidity = nil
            }

            guard try apply(from: row, to: migrated, db: db) else {
                // The new id was already occupied, so `apply` deleted the old
                // row and inserted nothing. `oldId` now names no header at all
                // — report it so the caller can drop it from the stores that
                // key by header id and live outside this database.
                onCollidedRekey(oldId)
                continue
            }
            applied.append(HeaderRekeyRecord(
                oldHeaderId: oldId, newHeaderId: newId,
                newProviderMessageId: newMessageId))
        }
        return applied
    }
}
