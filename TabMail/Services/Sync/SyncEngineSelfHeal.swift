/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - Self-Healing: Detect and Repair Missing Messages

    /// Lightweight UID gap detector that runs after full sync for IMAP accounts.
    /// Compares IMAP UIDs (via SEARCH) with local GRDB messageIds for recent messages
    /// and fetches any that are missing. Catches messages silently dropped by:
    ///   - IMAP FETCH returning fewer results than requested
    ///   - Backfill date-window boundary misses
    ///   - Connection drops mid-batch
    ///
    /// Rate-limited to once per hour per account (lightweight SEARCH is ~50ms,
    /// but we don't want to hammer the server on every 60s poll).
    func selfHealRecentMessages(account: Account, forceSingleFolder: Folder? = nil) async {
        guard account.provider == .imap,
              let provider = providers[account.id] as? IMAPProvider else { return }

        // Rate limit: once per hour (bypassed for single-folder forced heal)
        if forceSingleFolder == nil {
            let key = "selfHeal_lastRun_\(account.id)"
            let lastRun = UserDefaults.standard.double(forKey: key)
            let hourAgo = Date().timeIntervalSince1970 - 3600
            guard lastRun < hourAgo else {
                print("[SelfHeal] Skipping — last run \(Int(Date().timeIntervalSince1970 - lastRun))s ago")
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        }

        let syncableFolders: [Folder]
        if let single = forceSingleFolder {
            syncableFolders = [single]
        } else {
            let folders: [Folder]
            do {
                folders = try await dbPool.read { db in
                    try Folder.filter(Column("accountId") == account.id && Column("path") != "").fetchAll(db)
                }
            } catch {
                print("[SelfHeal] Failed to load folders: \(error)")
                return
            }
            syncableFolders = folders.filter { folder in
                primaryRoles.contains(folder.role) ||
                secondaryRoles.contains(folder.role) ||
                folder.isFavorite
            }
        }
        print("[SelfHeal] Starting for \(account.emailAddress): \(syncableFolders.count) folders")

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let since = utcCal.date(byAdding: .day, value: -90, to: now) ?? now

        var totalRepaired = 0

        for folder in syncableFolders {
            do {
                let repaired = try await selfHealFolder(
                    folder: folder,
                    account: account,
                    provider: provider,
                    since: since
                )
                totalRepaired += repaired
            } catch {
                // Don't abort other folders if one fails
                print("[SelfHeal] Error for \(folder.name): \(error)")
            }
        }

        if totalRepaired > 0 {
            print("[SelfHeal] Repaired \(totalRepaired) missing messages for \(account.emailAddress)")
        }
    }

    /// Compare IMAP UIDs vs GRDB for a single folder in the given date range.
    /// Returns the number of messages repaired (fetched and inserted).
    ///
    /// 🚨 **ROUND 13, BLOCKER 2 — THIS PASS IS EPOCH-GUARDED, AND IT HAS TO BE.**
    /// Its whole method is *diff a live UID list against the local `messageId`
    /// column and fetch the difference*. A `messageId` in an IMAP folder IS a
    /// UID, so that diff is only meaningful while the live mailbox and the local
    /// rows share one UIDVALIDITY. After a turnover the two sides are different
    /// numberings: nearly every live UID looks "missing", and self-heal would
    /// mass-insert a whole new numbering into a folder still stamped with the
    /// old one. Because `AccountManager.newGestureRefusedForUnknownEpoch` tests
    /// only `lastKnownUidValidity == nil`, that non-nil-but-wrong stamp ADMITS
    /// every bare-UID gesture on all of those rows, and `MessageHeader.stableId`
    /// falls back to the bare UID whenever a header has no `rfc822MessageId` —
    /// which native IMAP actions address directly in the live mailbox. That is
    /// constraint C3, the one hard invariant, reached here by a
    /// pass that is UNBOUNDED in size: the diff inserts as many headers as the
    /// window returns, so one mis-epoched run mis-stamps an arbitrarily large
    /// slice of the folder in a single pass.
    ///
    /// THREE terms, each closing a window the others cannot:
    ///  1. **The admission gate** (`crawlEpochGate`, before the SEARCH) — the
    ///     epoch this heal observes must agree with the epoch the folder's rows
    ///     are stamped with, or the diff below is comparing two UID spaces. It is
    ///     an EARLY-OUT, not the load-bearing guard: without it the pass would
    ///     still be safe (term 2 refuses), but it would SEARCH and FETCH
    ///     thousands of headers every hour only to discard them.
    ///  2. **The fetch-bound check** (`fetchEpoch == healEpoch`, after the FETCH)
    ///     — LOAD-BEARING. The mailbox can turn over between the gate and the
    ///     fetch, and neither term 1 nor term 3 can see that: term 1 is stale by
    ///     then, and term 3 compares the folder's STAMP, which a turnover does
    ///     not touch. `fetchEpoch` comes from the SELECTs that SERVED these
    ///     headers (`fetchMessageHeadersWithObservedEpoch`), never from the
    ///     provider's shared epoch mirror — see that function for why the mirror
    ///     is unsound in this direction and why `v2final`'s mirror read does not
    ///     transfer.
    ///  3. **The in-transaction CAS** (`epochPremise`) — the stamp must still be
    ///     the one term 1 gated on when the insert actually runs. A sibling pass
    ///     stamping the folder mid-heal is invisible to terms 1 and 2, because no
    ///     term in either reads the folder row.
    ///
    /// Every refusal returns 0, and nothing is ever reported repaired that was
    /// not repaired. Terms 1 and 2 additionally write NOTHING — they refuse
    /// before the insert — so their missing UIDs stay missing locally and the
    /// next hourly run re-derives them from scratch. Term 3 is the one that is
    /// NOT all-or-nothing: `insertBackfillBatch` writes in chunks and continues
    /// past a refused one, so a refusal there can follow chunks that already
    /// landed under the premise that still held for them. Those rows are sound
    /// (each chunk's CAS ran inside its own transaction); they are merely
    /// unindexed and un-enqueued until the existing recovery passes pick them up
    /// — see the `.refused` leg for the exact mechanism.
    ///
    /// ⚑ R0 — `v2final`'s counterpart passes
    /// `observedEpoch: provider.lastObservedUidValidity(folderPath:)` into
    /// `insertBackfillBatch` and has none of terms 1–3 otherwise. That does NOT
    /// transfer, on two independent grounds: (i) its `observedEpoch` is consumed
    /// by `uidValidityWriteAllowed`, which compares observed-vs-stored and is
    /// backstopped by the Stage-2 provider refusal
    /// (`selectMailboxTracked` there throws `ProviderError.uidValidityChanged`),
    /// and v3's `selectMailboxTracked` does NOT — ⚠️ CORRECTED 2026-08-05: this said
    /// "v3 has deleted that term entirely (`rg -n 'uidValidityChanged' TabMail/`
    /// finds no declaration and no throw site — every hit is prose, including this
    /// one)". That became false at `065a827ca` (2026-08-02), inside the release
    /// range: the case is DECLARED in `ProviderError` (`EmailProvider.swift`) and
    /// THROWN by `IMAPProvider.requireUidValidity`. The ground above survives
    /// intact, because what it needs is that the SELECT helper provides no
    /// backstop — and it still provides none; the throw is on the action path;
    /// (ii) v3's guard is a CAS against the
    /// caller's PREMISE about the stamp, not a comparison against an observed
    /// epoch, so a mirror read is not even the right KIND of value to hand it.
    /// "`v2final` does it" is therefore not an argument here.
    private func selfHealFolder(
        folder: Folder,
        account: Account,
        provider: IMAPProvider,
        since: Date
    ) async throws -> Int {
        let folderId = folder.id

        // Step 0 — THE ADMISSION GATE (term 1). The stamp is re-read here rather
        // than taken from `folder`: that object was loaded once, before a loop
        // that does network I/O per folder, so by now it can be minutes stale.
        // A folder whose row has gone away is not healable at all.
        guard let currentFolder = try await dbPool.read({ db in
            try Folder.fetchOne(db, key: folderId)
        }) else { return 0 }
        let storedEpoch = Self.knownUidValidity(currentFolder.lastKnownUidValidity)
            .flatMap { UInt32(exactly: $0) }
        // BOUND to its own SELECT (`getUidNextWithEpoch` returns the epoch that
        // SELECT reported), never sampled from the provider's shared mirror.
        let healEpoch = try await provider.getUidNextWithEpoch(folder: folder.path).observedEpoch
        switch Self.crawlEpochGate(stored: storedEpoch, walk: healEpoch) {
        case .proceed:
            break
        case .refuseUnobservedEpoch:
            // The folder HAS a stamp, so an epoch exists for it, and this SELECT
            // did not report one. RFC 3501 §6.3.1 lists UIDVALIDITY among
            // SELECT's REQUIRED untagged OK responses, so a server omitting it is
            // declaring it has no unique identifiers — an account whose every
            // UID-addressed action is unsafe. PERMANENT while the server keeps
            // omitting it (this pass mutates nothing, so the state re-creates
            // itself on every call); TRANSIENT when the omission was one failed
            // round trip. Fail-closed either way, and identical to the crawl's
            // own decision for the same state.
            if DebugModeManager.isLoggingEnabled() {
                print("[SelfHeal] \(folder.name) skipped: rows are stamped UIDVALIDITY \(String(describing: storedEpoch)) but this pass observed none")
            }
            return 0
        case .refuseEpochMismatch:
            // The mailbox was re-created since these rows were written. There is
            // no correct repair to run HERE — only the purge-and-resync reaction —
            // so the folder stays refused. Healing here means mixing two numberings
            // under one stamp (C3).
            //
            // UPDATE (T4.S6): the reaction now exists
            // (`AccountManager.runUidValidityResetReaction`), which makes this
            // refusal TRANSIENT rather than permanent — full sync's own
            // in-transaction epoch guard fires the reaction for the same folder, and
            // its per-folder loop re-drives an interrupted one. Self-heal
            // deliberately does NOT fire it itself: it runs on a connection it is
            // about to keep using, and the reaction disconnects the provider before
            // stamping. Refuse here, let the sync path react.
            if DebugModeManager.isLoggingEnabled() {
                print("[SelfHeal] \(folder.name) skipped: rows belong to UIDVALIDITY \(String(describing: storedEpoch)), server is at \(String(describing: healEpoch))")
            }
            return 0
        }

        // Step 1: SEARCH — get all UIDs in the date range from IMAP
        let remoteUIDs: [UInt32]
        do {
            remoteUIDs = try await provider.searchBackfillUIDs(
                folder: folder.path, since: since, before: Date()
            )
        } catch {
            let desc = "\(error)"
            if desc.contains("PayloadTooLargeError") {
                // Too many UIDs to compare — skip this folder (backfill handles it)
                return 0
            }
            throw error
        }
        guard !remoteUIDs.isEmpty else { return 0 }

        // Step 2: Find which UIDs we're missing locally
        let missingUIDs: [UInt32] = try await dbPool.read { db in
            let sqlChunkSize = SyncConfig.sqlChunkSize
            var existingIds = Set<String>()
            for start in stride(from: 0, to: remoteUIDs.count, by: sqlChunkSize) {
                let end = min(start + sqlChunkSize, remoteUIDs.count)
                let chunk = remoteUIDs[start..<end].map { "\($0)" }
                let found = try String.fetchSet(db,
                    MessageHeader
                        .select(Column("messageId"))
                        .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                )
                existingIds.formUnion(found)
            }
            return remoteUIDs.filter { !existingIds.contains(String($0)) }
        }

        guard !missingUIDs.isEmpty else { return 0 }
        print("[SelfHeal] \(folder.name): found \(missingUIDs.count) missing UIDs out of \(remoteUIDs.count) remote (last 90 days). Missing: \(missingUIDs.sorted().prefix(20))")

        // Step 3: Fetch missing headers from IMAP, together with the epoch the
        // SELECTs that served them reported (term 2's left-hand side).
        let profile = await getBackfillProfile()
        let (headers, fetchEpoch) = try await provider.fetchMessageHeadersWithObservedEpoch(
            folder: folder.path,
            uids: missingUIDs,
            batchSize: profile.imapFetchBatchSize,
            interBatchDelay: profile.imapInterBatchDelay
        )

        if headers.count < missingUIDs.count {
            let fetched = Set(headers.map(\.messageId))
            let stillMissing = missingUIDs.filter { !fetched.contains(String($0)) }
            print("[SelfHeal] \(folder.name): IMAP FETCH returned \(headers.count)/\(missingUIDs.count). Permanently missing UIDs: \(stillMissing.sorted().prefix(20))")
        }

        guard !headers.isEmpty else { return 0 }

        // TERM 2 — LOAD-BEARING. These headers may only enter a folder whose rows
        // share their numbering, and the only evidence of their numbering is the
        // SELECT that served them. Equality (not `crawlEpochGate`) on purpose:
        // `healEpoch` already agreed with the stamp, so requiring the fetch to
        // agree with `healEpoch` transitively binds the batch to the stamp, and
        // any disagreement — including the "batches spanned two epochs / one
        // batch reported none" nil that `fetchMessageHeadersWithObservedEpoch`
        // returns — refuses. Both nil is admitted, and only reachable when term 1
        // saw `stored == nil` as well: THIS FOLDER is unstamped, so every gesture
        // on its rows is refused by `newGestureRefusedForUnknownEpoch`
        // (IOS-EPOCH-001). A folder stamped from STATUS on a server that omits
        // UIDVALIDITY on SELECT is not that case — term 1 already refused it.
        // TRANSIENT: the next hourly run re-derives the whole diff.
        guard fetchEpoch == healEpoch else {
            if DebugModeManager.isLoggingEnabled() {
                print("[SelfHeal] \(folder.name): discarding \(headers.count) fetched headers — served under UIDVALIDITY \(String(describing: fetchEpoch)), this pass gated on \(String(describing: healEpoch))")
            }
            return 0
        }

        // Step 4: Insert into GRDB (reuse backfill insert which handles dedup).
        // TERM 3 — the in-transaction CAS. `storedEpoch` is the stamp term 1
        // gated on; a sibling moving it while this pass was on the network makes
        // this pass's whole premise stale, and the insert refuses.
        switch await insertBackfillBatch(
            headers,
            folderId: folderId,
            accountId: account.id,
            folderPath: folder.path,
            folderRole: folder.role,
            isInInbox: folder.role == .inbox,
            epochPremise: .init(storedEpoch),
            observedEpoch: fetchEpoch
        ) {
        case .refused:
            // TRANSIENT — the next hourly run reads whatever premise now holds.
            //
            // Precisely what "refused" means here: `insertBackfillBatch` writes
            // in CHUNKS and does not stop at the first refusal, so a refusal says
            // *at least one chunk was refused*, not *nothing landed*. UIDs in a
            // refused chunk are still absent locally and the next run's
            // SEARCH-vs-local diff finds them again. UIDs in a chunk that landed
            // BEFORE the stamp moved are already in GRDB — correctly, under the
            // premise that still held when their transaction ran — and this leg
            // skips their FTS indexing and body enqueue. Neither is dropped: they
            // carry `headerComplete = 0`, which `SyncEngine.recoverIncompleteHeaders`
            // (run at sync startup by `SyncScheduler`) re-indexes, and
            // `bodyComplete = 0`, which `BackfillBodyQueue.repopulateFromDatabase`
            // re-enqueues. Returning 0 under-reports those rows in the repaired
            // count; under-reporting a repair is the safe direction.
            if DebugModeManager.isLoggingEnabled() {
                print("[SelfHeal] \(folder.name): insert refused — the folder no longer holds the UIDVALIDITY this pass premised (\(String(describing: storedEpoch))), \(headers.count) headers discarded")
            }
            return 0
        case .landed(let inserted, let ftsRecords, _):
            if inserted > 0 {
                print("[SelfHeal] \(folder.name): repaired \(inserted) messages")
                if !ftsRecords.isEmpty {
                    await indexHeadersForFTS(ftsRecords)
                    await BackfillBodyQueue.shared.enqueueItems(
                        ftsRecords: ftsRecords, accountId: account.id,
                        folderPath: folder.path, isInInbox: folder.role == .inbox
                    )
                }
            }
            return inserted
        }
    }
}
