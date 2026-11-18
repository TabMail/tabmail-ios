/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Delta Sync

    /// Attempt a delta sync. Returns (succeeded, hadChanges).
    /// succeeded=false means full sync needed. hadChanges=true means data was written.
    /// - Parameter inboxOnly: a push or background pass. IMAP checks only the inbox
    ///   folder; a change reader skips the folder list, and a reader that reads
    ///   folder by folder reads only the inbox (ADR-IOS-111).
    /// - Parameter deadline: the caller's own deadline for the pass, or nil.
    func performDeltaSync(
        account: Account, provider: any EmailProvider, inboxOnly: Bool = false, deadline: Date? = nil
    ) async throws -> (succeeded: Bool, hadChanges: Bool) {
        let outcome = try await performChangePass(
            account: account, provider: provider, inboxOnly: inboxOnly, deadline: deadline)
        return (outcome.succeeded, outcome.hadChanges)
    }

    /// One change pass: the provider's change reader under the generic apply
    /// (ADR-IOS-111). A provider without a reader (Demo, test providers) reads
    /// nothing.
    /// - Parameter deadline: the caller's own deadline for the pass (its
    ///   timeout), or nil when it sets none. A reader's read budget ends early
    ///   enough for what it read to be applied before it (`changeReadEnd`).
    func performChangePass(
        account: Account, provider: any EmailProvider, inboxOnly: Bool = false, deadline: Date? = nil
    ) async throws -> ChangePassOutcome {
        await redriveArmedTurnovers(accountId: account.id)
        if let outcome = try await readAndApplyChanges(
            account: account, provider: provider, scope: inboxOnly ? .inboxOnly : .all, deadline: deadline) {
            return outcome
        }
        return ChangePassOutcome()
    }

    /// Publish downloading phase for a specific account.
    func publishDownloading(_ count: Int, forAccount accountId: String) {
        Task { @MainActor in
            AccountManagerState.shared.setSyncPhase(.downloading(count), forAccount: accountId)
        }
    }

    /// CONDSTORE (RFC 7162) flag-change signal for IMAP delta: does the server's
    /// current HIGHESTMODSEQ indicate a change since our cached cursor? True ONLY when
    /// both are present AND differ. A nil `server` (server doesn't advertise CONDSTORE)
    /// or nil `cached` (first observation / not yet recorded) yields false → the caller
    /// falls back to its uidNext+count comparison (exactly today's behavior). Pure +
    /// nonisolated for unit testing; the epoch (UIDVALIDITY) subtlety is handled safely
    /// upstream because this only gates FETCHING, never deletion.
    nonisolated static func modSeqIndicatesChange(server: Int?, cached: Int?) -> Bool {
        guard let server = knownModSeq(server), let cached = knownModSeq(cached) else { return false }
        return server != cached
    }

    /// A HIGHESTMODSEQ that tracks changes, or nil. RFC 7162 §3.1.2.2: a mailbox
    /// that does not keep mod-sequences (NOMODSEQ) reports 0 in STATUS, which is
    /// no value to compare, so 0 normalises to nil like an absent one.
    nonisolated static func knownModSeq(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// A UIDVALIDITY the server ACTUALLY reported, or nil for "unknown" — the
    /// shared choke point every epoch predicate and every epoch write below
    /// normalises through.
    ///
    /// RFC 3501 §2.3.1.1 types UIDVALIDITY as `nz-number` (a NON-ZERO unsigned
    /// 32-bit value), so `0` can only ever mean "not reported". The repo already
    /// settled that convention: `UIDExistenceResult.uidValidity` is documented
    /// *"0 = the server did not report a value (callers must treat as unknown and
    /// abort any deletion decision — never delete on uncertainty)"* and enforced at
    /// `SyncEngineDeletionReconcile.swift:144`. Normalising HERE — rather than at
    /// each call site — is what stops a future SELECT-sourced caller from
    /// introducing one: `Mailbox.Selection.uidValidity` is non-optional only
    /// because SwiftMail DEFAULTS it to `UIDValidity(0)`
    /// (`SwiftMail/IMAP/Models/Mailbox.swift:160`), which is not an RFC guarantee.
    /// Persisting that 0 would make every downstream epoch comparison `0 == 0`,
    /// i.e. vacuously true, silently disarming the guards built on it.
    ///
    /// REFERENCE (`v2final`): identical convention — `guard observed != 0 else
    /// { return }` at the head of the single persist API
    /// (`AccountManager.recordObservedUidValidity`), plus `known > 0` on every
    /// read of `Folder.lastKnownUidValidity` into its epoch ledger.
    nonisolated static func knownUidValidity(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// The value a SYNC path may persist into `Folder.lastKnownUidValidity`, or nil
    /// for "write nothing". **BOOTSTRAP-ONLY — this is a data-safety rule, not an
    /// optimisation.**
    ///
    /// That column is not a general-purpose "last epoch the server reported" field:
    /// it is the deletion-reconcile walk's ABORT GUARD (ADR-IOS-051, see
    /// `Folder.swift`), and its safety depends on it meaning *the epoch the LOCAL
    /// UIDs belong to*. The walk reads it from the DB
    /// (`SyncEngineDeletionReconcile.swift:373`) and aborts when the live SELECT
    /// disagrees (`:151-155`). Keeping the column synced to the live server epoch
    /// would make that comparison always equal — so on a real UIDVALIDITY turnover
    /// the walk would stop aborting and instead delete every local header as a
    /// "ghost", up to `expectedGhosts + SyncConfig.deletionReconcileCapSlack`. Hence:
    ///
    /// - observation unknown (nil, or the `0` sentinel) ⇒ write nothing;
    /// - column already holds a value ⇒ write nothing, whether it AGREES (no
    ///   redundant write — WAL etiquette) or DIFFERS (a turnover; the UID-remap /
    ///   resync machinery owns stamping a new epoch, only ever together with the
    ///   purge of the rows that belonged to the old one);
    /// - column empty + observation known ⇒ bootstrap it (the point of the item:
    ///   a folder the walk has never visited still ends up with a usable epoch).
    ///
    /// ⚠ **T4.S6b added a FOURTH branch, and it is NOT expressible here.** A folder
    /// that already HOLDS `messageHeader` rows may not be stamped by assertion — see
    /// `uidValidityBootstrapWrite(observed:stored:folderHoldsRows:)` below and the
    /// `NOT EXISTS` term in `bootstrapFolderUidValidity`. This two-argument form is
    /// pure and answers only the observed-vs-stored half of the decision; every
    /// caller must ALSO discharge the header-existence half, either through the
    /// three-argument overload (callers holding a `Database` and their own record)
    /// or by routing the write through `bootstrapFolderUidValidity` (which carries
    /// the term in the STATEMENT).
    ///
    /// REFERENCE (`v2final`): the identical three-branch contract, expressed as the
    /// single persist API `AccountManager.recordObservedUidValidity`
    /// (`AccountManager.swift:838`) — *"First observation … persist … Same value:
    /// no write (WAL etiquette) … CHANGED value: does NOT overwrite the stored value
    /// (a later stage's reaction owns stamping the new epoch, as part of the purge)
    /// … `observed == 0`: unreported, never recorded, never compared."*
    /// Pure + nonisolated for unit testing.
    nonisolated static func uidValidityBootstrapWrite(observed: Int?, stored: Int?) -> Int? {
        guard stored == nil else { return nil }
        return knownUidValidity(observed)
    }

    /// The T4.S6b form: the same decision, plus the header-existence term that makes
    /// an UNVERIFIED stamp impossible. For callers that hold a `Database` AND the
    /// `Folder` record they are about to `update`/`insert` inside that same write
    /// transaction — today the two folder-list upsert arms in `SyncEngine.fullSync`,
    /// which cannot route through `bootstrapFolderUidValidity` because they set the
    /// field on a record rather than issuing a statement.
    ///
    /// `folderHoldsRows` MUST be read from the SAME write transaction as the write
    /// it gates (no suspension in between), for the same TOCTOU reason the
    /// `lastKnownUidValidity IS NULL` predicate lives in the statement.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`.** Verified three ways, so the next agent
    /// does not re-derive them: (1) `v2final`'s single persist API
    /// `AccountManager.recordObservedUidValidity` stamps a nil row without ever
    /// asking whether headers exist; (2) `git grep` over
    /// `v2final -- 'TabMail/Services/Sync/*' 'TabMail/Services/Account/*'` finds no
    /// `localHeaders`, no `fetchCount(db)` near any epoch write, and no
    /// `prePopulated`/`unverified`/`verifyEpoch` term; (3) `v2final`'s
    /// `uidValidityWriteAllowed`/`uidValidityWalkWriteAllowed` are OBSERVED-VS-STORED
    /// comparisons that both fail OPEN on a nil stored side. The reference never
    /// named this hazard; v3's `Folder.lastKnownUidValidity` doc comment is where it
    /// was first named, and this is where it is closed.
    nonisolated static func uidValidityBootstrapWrite(
        observed: Int?, stored: Int?, folderHoldsRows: Bool
    ) -> Int? {
        guard !folderHoldsRows else { return nil }
        return uidValidityBootstrapWrite(observed: observed, stored: stored)
    }

    /// The bootstrap epoch write itself, as ONE conditional UPDATE, inside a
    /// transaction the caller already owns. Used by delta sync's unchanged and
    /// changed branches (STATUS-sourced), by `runSyncMessages` (SELECT-sourced,
    /// T1.2b) and by `SyncEngine.runBackfill`'s IMAP branch, through the gated
    /// wrapper `SyncEngine.bootstrapCrawledFolderUidValidity` (SELECT-sourced, the
    /// T1.3 anti-brick).
    ///
    /// ⚠ Round 7 described that backfill caller as "the ONLY writer that reaches a
    /// custom non-favourite folder, which no `syncableFolders` pass ever visits".
    /// RETRACTED (round 8): on-demand navigation reaches ANY folder via
    /// `AccountManager.syncFolders(_:connecting:)` → `SyncEngine.syncFolderMessages` →
    /// `runSyncMessages`, whose filter is `!folder.path.isEmpty` and nothing else.
    /// The crawl's bootstrap is still needed — backfill makes a folder's mail
    /// account-wide searchable long before the user ever opens it — but the window
    /// it closes is INDEFINITE, not permanent.
    ///
    /// ⚠ It is NOT the only writer of `Folder.lastKnownUidValidity`, and treating
    /// it as one would be dangerous — this column's safety property depends on
    /// knowing every writer (see the column's own doc comment on `Folder`). The
    /// complete set of BOOTSTRAP writers is THREE (a fourth writer, which ADVANCES
    /// rather than bootstraps, is enumerated after them):
    ///  1. this function — `runSyncMessages` and delta sync's changed branch call it
    ///     directly, delta sync's unchanged branch through the async wrapper of the
    ///     same name below, and `runBackfill`'s IMAP branch (in the FILE
    ///     `SyncEngineBackfillWalk.swift`, which is an `extension SyncEngine`; there
    ///     is no `SyncEngineBackfillWalk` type to cite) through
    ///     `bootstrapCrawledFolderUidValidity`, which adds a "the folder holds no
    ///     local UID yet" precondition on top of this one and must be the crawl's
    ///     only door to this function;
    ///  2. the folder-list upsert in `SyncEngine.fullSync` (`SyncEngineFullSync.swift`), which sets the
    ///     field on the `Folder` record it is already updating/inserting rather
    ///     than issuing a separate statement — it is safe without the in-statement
    ///     predicate because it reads `localFolders` INSIDE its own write
    ///     transaction, so its snapshot cannot be stale, and it routes its decision
    ///     through the same `uidValidityBootstrapWrite`;
    ///  3. `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch` (in the FILE
    ///     `SyncEngineEpochVerify.swift`) — the T4.S6b VERIFIED door, and the ONLY
    ///     path by which a folder that already holds rows may ever be stamped. It
    ///     does NOT come through this function: it writes through
    ///     `bootstrapVerifiedFolderUidValidity` below, which omits the `NOT EXISTS`
    ///     term and keeps `lastKnownUidValidity IS NULL`, because by the time it
    ///     runs it has PROVEN by FETCH that the folder's own rows still answer at
    ///     their own UIDs under the epoch it is about to stamp.
    /// Every one of the three is bootstrap-only and 0-filtered. Another bootstrap
    /// writer must be too, and must be added to this list.
    ///
    /// ⚠ **RETRACTED (T4.S6b): writer 3 used to be `persistFolderUidValidity` in
    /// `SyncEngineDeletionReconcile.swift`, the deletion-reconcile walk's own
    /// bootstrap — the ONLY writer that existed in `v1.6.38`. It is GONE.** The walk
    /// now REFUSES to run against a folder with no stored epoch
    /// (`runDeletionReconcileWalk`, abort reason `"epoch unverified"`) instead of
    /// adopting its first chunk's SELECT epoch and deleting on that authority, so
    /// there is nothing left for it to persist. That refusal, not the write, is what
    /// closes the shipped mass-deletion path: with the `NOT EXISTS` term below the
    /// write was already a no-op for a populated folder, while the in-memory
    /// adoption would have kept deleting — strictly worse than before.
    ///
    /// ⚠ **FOURTH WRITER — the only one that OVERWRITES a non-nil value (T4.S6):**
    /// `AccountManager.uidValidityResetStampFreshEpoch`, step 5 of the
    /// purge-and-resync reaction (`AccountManagerUidValidityReset.swift`). It does
    /// NOT carry the `lastKnownUidValidity IS NULL` predicate, on purpose — its job
    /// is precisely to advance the column across a turnover. What makes that safe is
    /// that it discharges the precondition the predicate stands in for: step 3 has
    /// already DELETED every `messageHeader` row of the folder in its own committed
    /// transaction, so there are no local UIDs left for the new stamp to
    /// misdescribe, and the walk's abort guard has nothing to be disarmed over. It
    /// is reachable only from inside a reaction that armed
    /// `Folder.uidValidityResetPendingAt` (it re-reads and requires that flag in its
    /// own write), and it clears the flag in the SAME statement batch. A fifth
    /// writer that advanced without both halves would reintroduce ADR-IOS-051.
    ///
    /// ⚠ One path CLEARS the column and writes no value:
    /// `SyncEngine.resetEmptyFolderCrawlEpoch` (in the FILE
    /// `SyncEngineBackfillWalk.swift`) sets it — and `backfillUidCursor` — back to
    /// NULL for a folder whose `MessageHeader` count is zero IN THE SAME
    /// TRANSACTION, so the stamp it drops describes an empty set and asserts
    /// nothing. It exists because bootstrap-only monotonicity, on its own, makes a
    /// stale stamp on an EMPTY folder a permanent crawl refusal (round-9 blocker
    /// 1). It never writes a value: the re-stamp is this function's, on the crawl's
    /// next iteration, under the same gate as any other first bootstrap. Keep it
    /// that way — a clearer that also stamped would be the fourth value-writer and
    /// would have to carry every rule above.
    ///
    /// The `lastKnownUidValidity IS NULL` predicate belongs in the STATEMENT, not in
    /// a Swift `if` over a `Folder` row read earlier: every sync caller reads its row
    /// BEFORE a network round trip (STATUS/SELECT) and writes AFTER it, and the
    /// deletion-reconcile walk writes this same column from its own task. Deciding on
    /// the pre-suspension snapshot is a TOCTOU that would let a live epoch land on top
    /// of the epoch the local UIDs belong to — the exact overwrite that disarms the
    /// walk's abort guard (ADR-IOS-051). SQLite evaluates the predicate at write time,
    /// inside the writer's serialized transaction, so the race cannot be lost.
    ///
    /// `knownUidValidity` is applied HERE as well as at the STATUS/SELECT
    /// boundaries, so a `0` cannot reach the column even through a caller that
    /// forgot to normalise. That is belt-and-braces on purpose: a stored `0`
    /// makes every later epoch comparison `0 == 0` and therefore vacuous.
    ///
    /// 🚨 **T4.S6b — the `NOT EXISTS (SELECT 1 FROM messageHeader …)` term is the
    /// point of this function now, and it belongs in the STATEMENT for exactly the
    /// same reason `lastKnownUidValidity IS NULL` does.** `nil` in that column means
    /// UNKNOWN, never "empty/fresh folder": a folder populated before migration
    /// `v63` added the column, or one whose row was deleted on a remote
    /// disappearance and re-created for the same deterministic `accountId:path` id
    /// (re-adopting its orphaned headers — migration `v2` dropped the
    /// `messageHeader.folderId` FK), holds OLD-epoch rows under a nil epoch. The
    /// three-branch rule above then let the first observation ASSERT that those rows
    /// belong to the epoch just observed — and if the numbering had in fact turned
    /// over, that assertion is what disarms the deletion-reconcile walk's abort
    /// guard and turns it into a mass deleter (ADR-IOS-051, the shipped defect this
    /// item closes). Making the write IMPOSSIBLE at the SQL level covers every blind
    /// caller at once, including ones added later.
    ///
    /// The precedent for the predicate is already in-tree:
    /// `bootstrapCrawledFolderUidValidity` (`SyncEngineBackfillWalk.swift`) has
    /// carried the identical `localHeaders == 0` gate since T1.3, for the identical
    /// reason. That Swift-side gate is now redundant with this one and is KEPT — it
    /// is evaluated inside the same write transaction, so the two cannot disagree,
    /// and it documents the crawl's own precondition at the crawl's own call site.
    ///
    /// A folder that already holds rows is NOT abandoned: `SyncEngine
    /// .verifyAndBootstrapPrePopulatedFolderEpoch` samples its own rows against the
    /// live mailbox and, on proof, stamps through
    /// `bootstrapVerifiedFolderUidValidity`. Until that runs the column stays nil,
    /// which is the `IOS-EPOCH-001` accepted window (gestures refused, the reconcile
    /// walk refuses, NO data touched) — not data loss.
    ///
    /// - Returns: whether the UPDATE actually stamped a row. Every term in the
    ///   statement can legitimately match nothing — an already-stamped folder, a
    ///   folder that holds headers, a folder row that vanished — and a caller that
    ///   reports "stamped" is making a claim about durable state, so the row count
    ///   is the only honest answer. `@discardableResult` because most callers are
    ///   fire-and-forget bootstraps that have no premise riding on it.
    @discardableResult
    nonisolated static func bootstrapFolderUidValidity(
        _ db: Database, folderId: String, observed: Int?
    ) throws -> Bool {
        guard let epoch = knownUidValidity(observed) else { return false }
        try db.execute(
            sql: """
                UPDATE folder SET lastKnownUidValidity = :epoch
                 WHERE id = :folderId
                   AND lastKnownUidValidity IS NULL
                   AND NOT EXISTS (SELECT 1 FROM messageHeader WHERE folderId = :folderId)
                """,
            arguments: ["epoch": epoch, "folderId": folderId]
        )
        return db.changesCount > 0
    }

    /// The VERIFIED bootstrap write — `bootstrapFolderUidValidity` minus ONLY the
    /// `NOT EXISTS` term, keeping `lastKnownUidValidity IS NULL`.
    ///
    /// ⚠ **Exactly ONE caller may ever exist**, and it is not a stylistic rule:
    /// `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`, which reaches here
    /// only after FETCHing a sample of the folder's OWN stored UIDs from the live
    /// mailbox and finding at least one whose normalized RFC-822 Message-ID still
    /// matches, with zero mismatches. That FETCH is what discharges the precondition
    /// the `NOT EXISTS` term stands in for — the same discipline
    /// `AccountManager.uidValidityResetStampFreshEpoch` follows when it advances a
    /// non-nil value (there the purge, here the proof). A second caller that skipped
    /// the proof would re-open the exact hazard the term exists to close.
    ///
    /// Still BOOTSTRAP-ONLY: `lastKnownUidValidity IS NULL` stays in the statement,
    /// so this can never overwrite an epoch the local UIDs already belong to, and a
    /// concurrent bootstrap that landed during the verification's network round trip
    /// wins (its value is by construction the one the rows are already judged
    /// against).
    nonisolated static func bootstrapVerifiedFolderUidValidity(
        _ db: Database, folderId: String, observed: Int?
    ) throws {
        guard let epoch = knownUidValidity(observed) else { return }
        _ = try Folder
            .filter(Column("id") == folderId && Column("lastKnownUidValidity") == nil)
            .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
    }

    /// `bootstrapFolderUidValidity(_:folderId:observed:)` in a transaction of its
    /// own, for callers that are not already inside one.
    func bootstrapFolderUidValidity(folderId: String, observed: Int?) async throws {
        guard Self.knownUidValidity(observed) != nil else { return }
        try await dbPool.write { db in
            // Explicit discard so the closure stays `Void`-returning now that the
            // static reports whether its UPDATE matched.
            _ = try Self.bootstrapFolderUidValidity(db, folderId: folderId, observed: observed)
        }
    }
}
