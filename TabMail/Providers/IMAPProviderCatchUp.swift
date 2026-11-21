/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// IMAP's opaque per-folder catch-up state (ADR-IOS-107), stored as JSON in
/// `Folder.catchUpState`. Only `IMAPProvider` decodes it; the engine writes only
/// the provider-neutral keys `CatchUpLapse.countKey`, `CatchUpWindowFloor.key` and
/// `CatchUpSkippedLoads.key` into the JSON object.
struct IMAPCatchUpState: Codable, Equatable, Sendable {
    /// The UIDVALIDITY every UID and stamp below belongs to. A folder whose known
    /// epoch differs discards the whole state and lists again from UID 1.
    var epoch: UInt32
    /// HIGHESTMODSEQ as it stood BEFORE THE FIRST RANGE of the last completed
    /// listing — the stamp the cheap check compares. Never the last range's: a
    /// change landing in an already-listed range while the listing is still running
    /// moves the server's counter past this value, so the folder is listed again.
    var completionStamp: Int?
    /// When the last listing completed. Drives the full-check interval.
    var lastCompletedAt: Date?
    /// The listing in progress, if any.
    var listing: Listing?
    /// When the catch-up last tried a listing for the folder, whether or not it
    /// succeeded. Drives the order: a folder that keeps failing goes to the back,
    /// so it cannot hold the others' catch-up past its bound.
    var lastAttemptAt: Date?
    /// How many change-bookmark lapses the folder's state has seen. Written only
    /// by `SyncEngine.markCatchUpLapse` / `lapseDeltaCursor`, inside this JSON
    /// under `CatchUpLapse.countKey` (the property name must stay equal to it);
    /// the catch-up carries it forward unchanged.
    var lapseCount: Int?
    /// The engine dropped loads from the listing in progress
    /// (`CatchUpSkippedLoads.key`; the property name must stay equal to it), so its
    /// completion is unclean. Cleared when the listing completes (#1062).
    var skippedLoads: Bool?
    /// `lapseCount` as it stood when the last COMPLETED listing started.
    var listedLapseCount: Int?

    /// A lapse came after the last completed listing started.
    var lapsedSinceLastListing: Bool { (lapseCount ?? 0) > (listedLapseCount ?? 0) }

    struct Listing: Codable, Equatable, Sendable {
        /// HIGHESTMODSEQ taken when this listing started, before its first range.
        /// Becomes `completionStamp` when the listing completes.
        var firstStamp: Int?
        /// The next listing range starts here (or at the range's lower bound, if
        /// that is higher): a range is cut on UIDs, never on local rows (#1062).
        /// *Superseded:* "The next listing range starts at the first local UID `>=` this."
        var nextUid: Int
        /// `IMAPCatchUpState.lapseCount` when this listing started.
        var lapseCountAtStart: Int?
        /// When a missing UID the server still holds first failed to load in
        /// this listing. The listing waits on it at most
        /// `SyncConfig.backfillPageHoldMinutes`, then moves on. The hold belongs
        /// to the UID at `nextUid`: it is kept while that UID stays the earliest
        /// unresolved one, and starts again only once it resolves or that UID
        /// advances (#1062).
        var loadHeldSince: Date?
        /// A missing UID was counted done by that bound in this listing, so its
        /// completion is not clean.
        var passedOver: Bool?
        /// The width in UIDs of this listing's next range (#1062): set after
        /// every range from that range's own count, and halved when a range
        /// times out, so the next call goes on from the same place with the
        /// smaller width. Absent (a listing written before it existed, or a new
        /// one): sized from the folder's EXISTS and UIDNEXT.
        var rangeWidth: Int?
        /// The widest range this listing may ask (#1062): a range that times
        /// out sets it to its width divided by
        /// `SyncConfig.catchUpWidthCapShrinkFactor`; each range that answers
        /// multiplies it by `SyncConfig.catchUpWidthCapGrowthFactor`, and at
        /// `SyncConfig.catchUpListingMaxRangeSpan` it is dropped. So once the
        /// server recovers, the width is back within a few ranges, wherever the
        /// timeouts happened. Absent: no cap.
        var widthCap: Int?
        /// The highest UID this listing lists (#1062): the last UIDNEXT - 1 its
        /// SELECTs reported (at least the last local UID). Every call bounds its
        /// ranges by it (each range is cut at it), so a listing never asks above
        /// the server's top. A listing's first call, with none stored, asks the
        /// folder's UIDNEXT before its first range. When that read reports none,
        /// no top is stored and the call lists only up to the last local UID
        /// (`topUnknown`). A later range SELECT without UIDNEXT keeps the top
        /// already learned. A change of it is progress.
        /// It lives in this state, so it is never used under another UIDVALIDITY
        /// (the state's `epoch`). Unused while a change bookmark bounds the
        /// listing (`bookmarkUpper`).
        var top: Int?
        /// A UIDNEXT read of this listing reported none (#1062): the listing
        /// may complete, but never clean, so an owed folder stays owed and is
        /// listed again at the daily check; nothing settles on an unknown top.
        var topUnknown: Bool?
        /// A range this listing asked and could not finish in the call that
        /// asked it (#1062): the budget ran out before its membership proof or
        /// before its loads. The next call goes on with it before it asks
        /// anything new, so no call throws away a request it already paid for.
        /// It lives in this state, so it is dropped with it: under another
        /// UIDVALIDITY (the state's `epoch`) or with a re-created folder row
        /// (whose state starts empty).
        var carried: CarriedRange?

        /// This listing with the width cap left out: what counts as the listing
        /// moving (`madeProgress`).
        var withoutWidthCap: Listing {
            var copy = self
            copy.widthCap = nil
            return copy
        }
    }

    /// A listed range a later call finishes (`Listing.carried`). UIDs only, no
    /// message content (ADR-004), at most `SyncConfig.catchUpCarriedUidCap`.
    struct CarriedRange: Codable, Equatable, Sendable {
        var lo: Int
        var hi: Int
        /// Local rows the listing FETCH did not answer; empty once proven.
        var candidates: [UInt32]
        /// Listed, not `\Deleted`, no local row, in the load range: to load.
        var missing: [UInt32]
        /// Listed as `\Deleted` in the load range (no local row): the proof
        /// counts them as answered by the FETCH.
        var deletedListed: [UInt32]
        /// The membership proof ran: what is left is loads only.
        var proven: Bool
        /// The lowest UID the proof found on the server but missing from the
        /// FETCH (held, as `omitted` is).
        var heldFloor: UInt32?
        /// The load floor the range was listed under (nil: none, so nothing in
        /// it was collected as missing). A resume loads only at or above both
        /// this and the floor then in force.
        var loadsFrom: Int?
        /// Unanswered UIDs whose SEARCH the range still owes.
        var unanswered: [UInt32]?
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil for no state or an unreadable one. Either way the folder starts over,
    /// which can only cost a re-listing.
    static func decode(_ raw: String?) -> IMAPCatchUpState? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IMAPCatchUpState.self, from: data)
    }
}

extension IMAPProvider {

    /// What a folder needs this pass. Pure, so the decision is testable on its own.
    enum CatchUpPlan: Equatable {
        /// Nothing: MODSEQ unchanged and the full check not due, or the network is
        /// expensive and nothing signals a change.
        case none
        /// List the folder by UID ranges, starting at or continuing `listing`.
        case list(IMAPCatchUpState.Listing)
    }

    /// The per-folder decision.
    /// - `freshModSeq` is the HIGHESTMODSEQ the folder's last proven listing
    ///   stored (`Folder.lastKnownHighestModSeq`, written only by
    ///   `SyncEngine.writeListingCounters`; STATUS is a trigger and never writes
    ///   it), nil on a server or session without CONDSTORE.
    /// - The decision is the same on every network, battery level and power mode:
    ///   a scan is cheap and always runs; only downloads wait (#1063).
    /// - `isTracked`: the folder's change bookmark covers it (ADR-IOS-111). Its
    ///   changes arrive through the change read, so neither the MODSEQ check nor
    ///   the daily full check lists it; its first listing, a listing in progress
    ///   and a lapse of its bookmark still do (the Gmail rule, ADR-IOS-107).
    /// - `rawLapseCount`: the lapse count in the folder's raw state
    ///   (`CatchUpLapse.read`), the new listing's start count when `state` is
    ///   absent (a floor-only state, another epoch), so a mark made on such a
    ///   state is settled by the first listing that starts after it (#1062).
    nonisolated static func catchUpPlan(
        state: IMAPCatchUpState?, freshModSeq: Int?, now: Date, isTracked: Bool = false,
        rawLapseCount: Int? = nil
    ) -> CatchUpPlan {
        let modSeqChanged: Bool = {
            guard !isTracked, let stamp = state?.completionStamp, let freshModSeq else { return false }
            return freshModSeq != stamp
        }()
        let fullCheckDue = isTracked
            ? (state?.lastCompletedAt == nil || state?.lapsedSinceLastListing == true)
            : CatchUpSchedule.fullCheckDue(
                lastCompletedAt: state?.lastCompletedAt, now: now, interval: SyncConfig.catchUpFullCheckIntervalSeconds)
                || state?.lapsedSinceLastListing == true
        if let listing = state?.listing { return .list(listing) }
        if modSeqChanged || fullCheckDue {
            return .list(IMAPCatchUpState.Listing(
                firstStamp: freshModSeq, nextUid: 1, lapseCountAtStart: state?.lapseCount ?? rawLapseCount))
        }
        return .none
    }

    /// `EmailProvider.catchUp` for IMAP (ADR-IOS-107). For each folder whose epoch is
    /// known: the cheap check (the latest STATUS HIGHESTMODSEQ against the stored
    /// completion stamp, no request), and when that or the full-check interval
    /// calls for it, a flags-only listing by UID ranges that resumes across passes.
    /// Least recently attempted folder first. Every request is preceded by a budget check
    /// and bounded by `SyncConfig.catchUpRequestTimeoutSeconds`; a timeout or any
    /// failure ends the folder's work for the pass, keeping what was proven.
    func catchUp(
        folders: [Folder], localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> [CatchUpFolderResult] {
        // Least recently tried first: never-tried folders, then by the last try
        // (a completion is a try). A folder whose requests keep failing
        // therefore goes behind the others. The sort is stable on the caller's order
        // for ties.
        let ordered = CatchUpSchedule.leastRecentlyAttemptedFirst(folders) {
            IMAPCatchUpState.decode($0.catchUpState)?.lastAttemptAt
        }

        var results: [CatchUpFolderResult] = []
        for folder in ordered {
            guard context.hasBudget() else { break }
            if let result = await catchUpFolder(folder, localRows: localRows, context: context) {
                results.append(result)
            }
        }
        return results
    }

    /// One folder's catch-up. Nil when the folder needs nothing, or is not eligible:
    /// an empty path, a quarantined folder, or an UNKNOWN epoch (C3 — nothing is
    /// ever decided about a UID whose numbering is unproven).
    private func catchUpFolder(
        _ folder: Folder, localRows: any CatchUpLocalRowReader, context: CatchUpContext
    ) async -> CatchUpFolderResult? {
        guard !folder.path.isEmpty, folder.uidValidityResetPendingAt == nil,
              let stored = folder.lastKnownUidValidity, stored > 0,
              let epoch = UInt32(exactly: stored) else { return nil }

        // A state from another epoch describes UIDs that no longer exist: drop it.
        let state = IMAPCatchUpState.decode(folder.catchUpState).flatMap { $0.epoch == epoch ? $0 : nil }
        let bookmark = IMAPChangeCursor.decode(folder.changeCursor)
        let plan = Self.catchUpPlan(
            state: state, freshModSeq: folder.lastKnownHighestModSeq,
            now: context.clock(),
            // Tracked: a bookmark held AND not owed a check. An owed folder can
            // regain a bookmark from a change pass, and a tracked folder gets no
            // daily check, so an owed folder whose listing completed unclean would
            // never be listed again (#1062). Not `FolderChangeState.tracking`: that
            // flag is off for a bookmarked folder before its baseline commits and
            // can be left on with no bookmark (ADR-IOS-111 decision 4).
            isTracked: bookmark != nil && !FolderChangeState(raw: folder.changeState).selfHealDue,
            rawLapseCount: CatchUpLapse.read(folder.catchUpState))
        guard case .list(var listing) = plan else { return nil }

        var result = CatchUpFolderResult(folderId: folder.id, epoch: epoch)
        // The width of the next range: the first sized from the folder's stored
        // EXISTS and UIDNEXT, each later one from the previous range's own count,
        // so a bunched folder never puts most of itself in one range (#1062).
        var span = listing.rangeWidth ?? Self.listingRangeSpan(
            messages: context.listingRangeMessages, exists: folder.totalCount, uidNext: folder.lastKnownUidNext)
        let timeout = context.requestTimeoutSeconds
        let path = folder.path
        var completed = false

        // The UID range listed (#1062). Its lower bound is where the range the
        // device holds the folder in starts (the older-mail walk's, as the change
        // reader takes it); under a storage limit, loads start at the higher of
        // that and the first local UID, so pruned mail is not loaded again (the
        // prune deletes lowest UIDs first, so the first local UID is where kept
        // mail ends, ADR-IOS-006) and rows infinite scroll cached below the walk's
        // cursor never pull the floor down. A server
        // UID in the range that no local row holds is MISSING and is loaded, from
        // `loadsFrom` up. Before the walk has started, loads start at the lowest
        // UID a window listing of the folder reached (`CatchUpWindowFloor`; under
        // a storage limit, the higher of that and the first local UID): new mail
        // beyond the window is a scan's to load, and a scan never waits for the
        // walk's download gates (#1063), while older mail is the walk's, which
        // waits for them. Rows infinite scroll wrote far below the window never
        // pull that floor down. With no floor recorded yet, nothing is loaded
        // until a window listing records one.
        // *Superseded (#1062):* "before the walk has started, below the window is
        // the walk's to load" — nothing loaded until the walk could run; then
        // "before the walk has started, the first local UID is the floor too",
        // which let infinite-scroll rows pull the floor down over old mail. Its upper
        // bound is the larger of the last local UID and, with a change bookmark,
        // the bookmark's UIDNEXT - 1 (the change reader owns everything at or
        // above it), else the top the listing last learned from its own SELECTs
        // (`Listing.top`). By the bookmark,
        // not by tracking, so the bound holds whichever pass ran first.
        let heldFrom = Self.heldRangeStart(olderMailComplete: folder.backfillComplete, olderMailCursor: folder.backfillUidCursor)
        let firstLocal: Int?
        let lastLocal: Int?
        do {
            firstLocal = try await localRows.firstNumericId(folderId: folder.id, atLeast: 1)
            lastLocal = try await localRows.lastNumericId(folderId: folder.id)
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(path): local row read failed (\(error)) — stopping this folder for the pass")
            }
            return attempted(folder, state: state, listing: listing, epoch: epoch, context: context)
        }
        let loadsFrom: Int?
        if let heldFrom {
            // Under a storage limit the higher of the walk's start and the first
            // local UID: rows infinite scroll cached below the cursor never pull
            // the floor down, and nothing the prune removed loads again (#1062).
            loadsFrom = context.storageLimitInForce ? max(heldFrom, firstLocal ?? heldFrom) : heldFrom
        } else if let windowFloor = CatchUpWindowFloor.read(folder.catchUpState) {
            loadsFrom = context.storageLimitInForce ? max(windowFloor, firstLocal ?? windowFloor) : windowFloor
        } else {
            loadsFrom = nil
        }
        // The scan floor is the earlier of the first local row and the load floor:
        // cached rows below an unfinished walk's cursor (infinite scroll writes them
        // without moving it) still get their flags and expunges reconciled.
        // `loadsFrom` stays only the boundary below which nothing is loaded.
        let lower = [loadsFrom, firstLocal].compactMap { $0 }.min()
        let bookmarkUpper = bookmark.flatMap { $0.uidValidity == epoch ? Int($0.uidNext) - 1 : nil }
        var upper: Int? = (bookmarkUpper ?? listing.top).map { max($0, lastLocal ?? 0) }
        let holdSeconds = SyncConfig.backfillPageHoldMinutes * 60
        // The cap before this call first raised it: restored if the call makes
        // no progress, so a call that moves nothing never widens the next try.
        var capBeforeGrowth: Int?

        rangeLoop: while true {
            // The range this turn works: a carried one first (`Listing.carried`),
            // else the next range, listed now.
            let lo: Int
            let hi: Int
            var candidates: [UInt32] = []
            var missing: [UInt32] = []
            var deletedListed: [UInt32] = []
            var localUids = Set<UInt32>()
            var proven = false
            var heldFloor: UInt32?
            var listedUids = Set<UInt32>()
            var owedSearch: [UInt32] = []
            // The load floor for this range: the current one for a range listed
            // now; for a carried one, only where both the floor it was listed
            // under and the current one allow loads (a rising floor, after a walk
            // reset or a prune, never loads below it; a range listed with no
            // floor collected nothing as missing).
            var rangeFloor = loadsFrom
            if let carried = listing.carried {
                listing.carried = nil
                lo = carried.lo
                hi = carried.hi
                // A carried UID may be stale: loaded by another path since (now a
                // local row: not loaded again), or expunged (the load finds
                // nothing and writes nothing). A candidate whose row went is no
                // longer one.
                let local: [CatchUpLocalRow]
                do {
                    local = try await localRows.rows(folderId: folder.id, numericIdsFrom: lo, through: hi)
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path): local row read failed (\(error)) — stopping this folder for the pass")
                    }
                    listing.carried = carried
                    break rangeLoop
                }
                localUids = Set(local.compactMap { UInt32($0.messageId) })
                rangeFloor = carried.loadsFrom.flatMap { listedUnder in loadsFrom.map { max($0, listedUnder) } }
                // Immutable copies: a local function capturing the mutable
                // vars is rejected by region isolation.
                let heldLocally = localUids, loadFloor = rangeFloor
                func loadable(_ uid: UInt32) -> Bool {
                    !heldLocally.contains(uid) && loadFloor.map { Int(uid) >= $0 } == true
                }
                candidates = carried.candidates.filter(localUids.contains)
                missing = carried.missing.filter(loadable)
                deletedListed = carried.deletedListed.filter(loadable)
                owedSearch = (carried.unanswered ?? []).filter(loadable)
                proven = carried.proven
                heldFloor = carried.heldFloor.flatMap { loadable($0) ? $0 : nil }
                listedUids = Set(carried.missing + carried.deletedListed + (carried.unanswered ?? []))
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): goes on with the carried range (\(missing.count) to load, \(proven ? "proven" : "proof owed"))")
                }
            } else {
                guard let lower else {
                    completed = true
                    break rangeLoop
                }
                var from = max(listing.nextUid, lower)
                if loadsFrom.map({ from < $0 }) ?? true {
                    // Below where loads start, a listing only checks local rows, so a
                    // stretch with none is skipped, as before missing loads existed.
                    let nextLocal: Int?
                    do {
                        nextLocal = try await localRows.firstNumericId(folderId: folder.id, atLeast: from)
                    } catch {
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path): local row read failed (\(error)) — stopping this folder for the pass")
                        }
                        break rangeLoop
                    }
                    guard let next = [nextLocal, loadsFrom].compactMap({ $0 }).min() else {
                        completed = true
                        break rangeLoop
                    }
                    from = max(from, next)
                }
                lo = from
                if upper == nil {
                    // The listing's first call, with no top stored: the folder's
                    // UIDNEXT first, one request, so no range is asked blind (#1062).
                    guard context.hasBudget(cost: 1) else {
                        if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[CatchUp] \(path): budget spent before the folder's UIDNEXT") }
                        break rangeLoop
                    }
                    let status: (uidNext: Int?, observedEpoch: UInt32?)
                    do {
                        status = try await withTimeout(seconds: timeout) {
                            try await self.getUidNextWithEpoch(folder: path)
                        }
                    } catch {
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path): UIDNEXT read failed (\(error)) — stopping this folder for the pass")
                        }
                        break rangeLoop
                    }
                    guard status.observedEpoch == epoch else {
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path): SELECT reported UIDVALIDITY \(status.observedEpoch.map(String.init) ?? "none"), folder holds \(epoch) — applying nothing")
                        }
                        return CatchUpFolderResult(folderId: folder.id, epoch: status.observedEpoch)
                    }
                    // A SELECT without UIDNEXT did not say where the folder ends
                    // (MIS-IOS-004): no top is stored, this call lists only up to
                    // the last local UID (flags and removals as before; an empty
                    // folder completes at once), and the listing can complete
                    // only as not clean, so nothing settles on it (#1062).
                    if let knownNext = status.uidNext {
                        let learned = max(lastLocal ?? 0, knownNext - 1)
                        upper = learned
                        listing.top = learned
                    } else {
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path): SELECT reported no UIDNEXT — top unknown, listing up to the last local UID, not clean")
                        }
                        upper = lastLocal ?? 0
                        listing.topUnknown = true
                    }
                }
                if let upper, lo > upper {
                    completed = true
                    break rangeLoop
                }
                let width = min(span, listing.widthCap ?? Int.max)
                hi = min(lo + width - 1, upper ?? Int(UInt32.max), Int(UInt32.max))
                guard lo <= Int(UInt32.max) else {
                    completed = true
                    break rangeLoop
                }
                guard context.hasBudget(cost: 1) else {
                    if DebugModeManager.isLoggingEnabled() { BackgroundSyncLogger.logDebug("[CatchUp] \(path): budget spent before \(lo):\(hi)") }
                    break rangeLoop
                }

                let listed: (flags: [UInt32: (isRead: Bool, isFlagged: Bool, isDeleted: Bool)], uidValidity: UInt32, uidNext: UInt32?, exists: Int)
                let local: [CatchUpLocalRow]
                do {
                    local = try await localRows.rows(folderId: folder.id, numericIdsFrom: lo, through: hi)
                    listed = try await withTimeout(seconds: timeout) {
                        try await self.listFlagsInUIDRange(folder: path, from: lo, to: hi)
                    }
                } catch {
                    // A range too slow or too large to answer is cut by the walk's
                    // own rule (`UIDWalkCursor.halves`) to the half next to where the
                    // listing stands in its direction of travel (upward: the lower
                    // half). Its width is stored and the folder stops for this call:
                    // the timed-out request still holds the folder's connection until
                    // its late answer, so no retry in the same call could work. The
                    // listing keeps its place, and the next call asks from there with
                    // the smaller width. A range of one UID that fails stays
                    // unconfirmed: the listing never moves past it, and the next call
                    // asks it again.
                    if UIDWalkCursor.failureCallsForSmallerRange(error) {
                        let halves = UIDWalkCursor.halves(from: lo, to: hi)
                        let halved = halves.map { $0.lower.to - $0.lower.from + 1 } ?? 1
                        listing.rangeWidth = halved
                        listing.widthCap = max(1, (hi - lo + 1) / SyncConfig.catchUpWidthCapShrinkFactor)
                        capBeforeGrowth = nil
                        if DebugModeManager.isLoggingEnabled() {
                            BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): listing failed (\(error)) — next call asks \(listing.rangeWidth ?? 1) UID(s) from here")
                        }
                        break rangeLoop
                    }
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): listing failed (\(error)) — stopping this folder for the pass")
                    }
                    break rangeLoop
                }
                guard listed.uidValidity == epoch else {
                    // The server is serving another numbering (or none): nothing listed
                    // here may be applied. Report what was observed so the apply can
                    // run the turnover reaction; the state is left as it was.
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path): SELECT reported UIDVALIDITY \(listed.uidValidity), folder holds \(epoch) — applying nothing")
                    }
                    return CatchUpFolderResult(folderId: folder.id, epoch: listed.uidValidity == 0 ? nil : listed.uidValidity)
                }
                if bookmarkUpper == nil, let next = listed.uidNext {
                    // The top this listing last learned (`Listing.top`).
                    let learned = max(lastLocal ?? 0, upper ?? 0, Int(next) - 1)
                    upper = learned
                    listing.top = learned
                }
                // Only records inside the range asked for: a FETCH response for
                // another UID (an unsolicited flag change elsewhere in the folder) is
                // not part of this listing (#1062, the #755 rule).
                let flags = listed.flags.filter { lo <= Int($0.key) && Int($0.key) <= hi }
                // Re-sized from this range's own count; the cap, while it holds,
                // is applied where the next range is cut (`Listing.widthCap`).
                span = Self.nextListingRangeSpan(
                    messages: context.listingRangeMessages, width: hi - lo + 1, held: flags.count)
                listing.rangeWidth = span
                // A range that answers raises the cap again (`Listing.widthCap`),
                // kept only if the call makes progress (see below).
                if let cap = listing.widthCap {
                    if capBeforeGrowth == nil { capBeforeGrowth = cap }
                    let raised = cap * SyncConfig.catchUpWidthCapGrowthFactor
                    listing.widthCap = raised >= SyncConfig.catchUpListingMaxRangeSpan ? nil : raised
                }

                for row in local {
                    guard let uid = UInt32(row.messageId) else { continue }
                    localUids.insert(uid)
                    if let server = flags[uid] {
                        // A `\Deleted` message is not shown: no flag update for it.
                        if !server.isDeleted, server.isRead != row.isRead || server.isFlagged != row.isFlagged {
                            result.flagUpdates.append(CatchUpFlagUpdate(
                                messageId: row.messageId, isRead: server.isRead, isFlagged: server.isFlagged))
                        }
                    } else {
                        candidates.append(uid)
                    }
                }
                // Missing: listed, not `\Deleted`, no local row, in the load range.
                for (uid, server) in flags where !localUids.contains(uid) {
                    guard let loadsFrom, Int(uid) >= loadsFrom else { continue }
                    listedUids.insert(uid)
                    if server.isDeleted { deletedListed.append(uid) } else { missing.append(uid) }
                }
                missing.sort()
                deletedListed.sort()
                candidates.sort()
            }

            // The part of the range where missing UIDs are loaded. A short FETCH can
            // omit a UID there that no local row holds, so its membership is proven
            // by SEARCH too, never read from the FETCH alone (#1062): one SEARCH
            // per range, asked as the range itself, whose answer lists only the
            // messages it holds.
            // *Superseded (#1062):* the SEARCH named every UID of the load range,
            // and only when one had neither a FETCH record nor a local row.
            let loadRange: ClosedRange<Int>? = rangeFloor.flatMap { start in
                let first = max(lo, start)
                return first <= hi ? first...hi : nil
            }
            // In the load range: on the server by SEARCH, absent from the FETCH,
            // no local row. Its flags (`\Deleted` included) are unknown, so it is
            // not loaded; it stays unresolved under the hold bound, and a listing
            // that passes it over is not clean.
            var omitted: [UInt32] = heldFloor.map { [$0] } ?? []
            // A failed membership SEARCH: nothing in the range is decided or
            // loaded, and the range is unresolved from `lo`, under the same
            // bounded hold as an unloaded UID (#1062). The range is carried
            // unproven meanwhile, so a retry asks only the SEARCH.
            var proofStopped = false
            if !proven, !candidates.isEmpty || loadRange != nil {
                // A UID missing from the FETCH is only a candidate: a short FETCH is a
                // real server shape. The walk's own absence proof decides, under the
                // same epoch.
                if !context.hasBudget(cost: 1) {
                    // The budget ran out after the listing: the range is carried,
                    // so the next call proves it without listing it again (#1062).
                    // *Superseded (#1062):* "budget spent before the membership
                    // proof — unresolved", held from `lo` and listed again by the
                    // next call, which a slice that fits only the listing and the
                    // proof never got past.
                    let carry = Self.carry(lo: lo, hi: hi, candidates: candidates, missing: missing,
                                           deletedListed: deletedListed, proven: false, heldFloor: nil,
                                           loadsFrom: rangeFloor, unanswered: owedSearch)
                    listing.carried = carry
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): budget spent before the membership proof — carried through \(carry.hi)")
                    }
                    break rangeLoop
                }
                var confirmed: UIDExistenceResult?
                do {
                    let toConfirm = candidates
                    confirmed = try await withTimeout(seconds: timeout) {
                        try await self.searchMembership(folder: path, uids: toConfirm, range: loadRange)
                    }
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): membership proof failed (\(error)) — unresolved")
                    }
                    proofStopped = true
                }
                if let confirmed {
                    guard confirmed.uidValidity == epoch else {
                        return CatchUpFolderResult(folderId: folder.id, epoch: confirmed.uidValidity == 0 ? nil : confirmed.uidValidity)
                    }
                    result.removedIds += candidates.filter { !confirmed.found.contains($0) }.map(String.init)
                    omitted = confirmed.found.filter { !listedUids.contains($0) && !localUids.contains($0) && loadRange?.contains(Int($0)) == true }.sorted()
                    if !omitted.isEmpty, DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): \(omitted.count) UID(s) on the server were missing from the FETCH — unresolved")
                    }
                }
            }

            let load = proofStopped
                ? MissingLoad(stoppedAt: UInt32(lo))
                : await loadMissing(missing, owedSearch: owedSearch, path: path, epoch: epoch, context: context)
            if let observed = load.otherEpoch {
                return CatchUpFolderResult(folderId: folder.id, epoch: observed == 0 ? nil : observed)
            }
            result.loaded += load.loaded
            // A UID the server holds that did not load; one omitted from the FETCH
            // counts as held.
            let held = [load.held, omitted.first].compactMap({ $0 }).min()
            // What a stop (the budget, or a failed request) leaves of this range,
            // carried so no request already paid is asked again (#1062).
            let floorOfRange = rangeFloor
            func leftOver(heldFloor: UInt32?) -> IMAPCatchUpState.CarriedRange {
                proofStopped
                    ? Self.carry(lo: lo, hi: hi, candidates: candidates, missing: missing,
                                 deletedListed: deletedListed, proven: false, heldFloor: nil,
                                 loadsFrom: floorOfRange, unanswered: owedSearch)
                    : Self.carry(lo: lo, hi: hi, candidates: [], missing: load.notAsked,
                                 deletedListed: [], proven: true, heldFloor: heldFloor,
                                 loadsFrom: floorOfRange, unanswered: load.owedSearch)
            }
            if let stop = load.budgetStoppedAt {
                // The budget ran out before a load batch or an unanswered UID's
                // SEARCH: the rest is carried, so the next call goes on with it
                // before it lists anything. A held UID keeps its first hold (on
                // the same UID); past the bound it is passed over and the carried
                // work goes on.
                var heldUid = held
                if let uid = heldUid {
                    let runningHold = listing.nextUid == Int(uid) ? listing.loadHeldSince : nil
                    let since = runningHold ?? context.clock()
                    if context.clock().timeIntervalSince(since) < holdSeconds {
                        listing.loadHeldSince = since
                        listing.nextUid = Int(uid)
                    } else {
                        listing.passedOver = true
                        listing.loadHeldSince = nil
                        listing.nextUid = Int(stop)
                        heldUid = nil
                    }
                } else {
                    listing.nextUid = Int(stop)
                }
                let carry = leftOver(heldFloor: heldUid)
                listing.carried = carry
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path) \(lo):\(hi): budget spent before the work from \(stop) — carried through \(carry.hi)")
                }
                break rangeLoop
            }
            // The earliest UID this range left unresolved: one the server still
            // holds that did not load (`held`), or the first a failed request left
            // unasked (`stoppedAt`). The listing resumes there, so
            // an earlier unresolved UID is never skipped by a later stop.
            if let unresolved = [held, load.stoppedAt].compactMap({ $0 }).min() {
                // What a failed request left is carried while the range waits,
                // so the retry pays only for what failed (#1062).
                let left = load.stoppedAt.map { _ in leftOver(heldFloor: held) }
                // The hold already running on this same earliest unresolved UID
                // (the saved cursor names it) keeps its start: loads of later
                // UIDs never restart it (#1062). It restarts only once that UID
                // resolves or the earliest unresolved UID advances.
                let runningHold = listing.nextUid == Int(unresolved) ? listing.loadHeldSince : nil
                if held == nil, !load.loaded.isEmpty, runningHold == nil {
                    // The loads moved and stopped on a failed request: not held,
                    // and the hold clock starts again at the next hold (the Gmail
                    // page rule, `CatchUpDirectLoad.pageVerdict`).
                    listing.loadHeldSince = nil
                    listing.nextUid = Int(unresolved)
                    listing.carried = left
                    break rangeLoop
                }
                // A held UID, a failed request with nothing loaded, a failed
                // membership proof (unresolved from `lo`), or a stop on the UID
                // already held: held for a bounded time. Past it, the held and
                // unasked UIDs count as done, the range moves on, and the listing
                // completes as not clean.
                let since = runningHold ?? context.clock()
                if context.clock().timeIntervalSince(since) < holdSeconds {
                    listing.loadHeldSince = since
                    listing.nextUid = Int(unresolved)
                    listing.carried = left
                    break rangeLoop
                }
                listing.passedOver = true
            }
            listing.loadHeldSince = nil
            listing.nextUid = hi + 1
        }

        // Progress: the listing moved or completed, or something applies. A range
        // whose request failed before anything moved is no progress, so the
        // worker does not list it again at once. The width cap a timeout sets
        // is no progress either: it only narrows the next try (#1062).
        let madeProgress = completed || listing.withoutWidthCap != state?.listing?.withoutWidthCap
            || !result.flagUpdates.isEmpty || !result.removedIds.isEmpty || !result.loaded.isEmpty
        // No growth of the cap on a call that moved nothing (#1062).
        if !madeProgress, let capBeforeGrowth { listing.widthCap = capBeforeGrowth }
        var newState = state ?? IMAPCatchUpState(epoch: epoch)
        newState.lastAttemptAt = context.clock()
        if completed {
            newState.completionStamp = listing.firstStamp
            newState.lastCompletedAt = context.clock()
            newState.listedLapseCount = listing.lapseCountAtStart
            newState.listing = nil
            newState.skippedLoads = nil
        } else {
            newState.listing = listing
        }
        result.newState = newState.encoded()
        if completed {
            result.completedListing = CatchUpCompletedListing(
                lapseCountAtStart: listing.lapseCountAtStart ?? 0, clean: listing.passedOver != true && listing.topUnknown != true && state?.skippedLoads != true)
        }
        result.madeProgress = madeProgress
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CatchUp] \(path): flags=\(result.flagUpdates.count) removed=\(result.removedIds.count) loaded=\(result.loaded.count) \(completed ? "listing complete" : "resumes at UID \(listing.nextUid)")")
        }
        return result
    }

    /// A folder whose local rows could not be read: only the attempt is
    /// recorded, so it goes behind the others; the listing keeps its place.
    private func attempted(
        _ folder: Folder, state: IMAPCatchUpState?, listing: IMAPCatchUpState.Listing, epoch: UInt32, context: CatchUpContext
    ) -> CatchUpFolderResult {
        var result = CatchUpFolderResult(folderId: folder.id, epoch: epoch)
        var newState = state ?? IMAPCatchUpState(epoch: epoch)
        newState.lastAttemptAt = context.clock()
        newState.listing = listing
        result.newState = newState.encoded()
        return result
    }

    /// What loading one range's missing UIDs did.
    struct MissingLoad {
        /// Headers that loaded (no body: the insert tail queues it).
        var loaded: [BackfillResult] = []
        /// The first missing UID not loaded or classified when the budget or a
        /// failed request stopped the loads.
        var stoppedAt: UInt32?
        /// The lowest UID that did not load though the server still lists it.
        var held: UInt32?
        /// A request was served under another UIDVALIDITY (0: none reported).
        var otherEpoch: UInt32?
        /// The lowest UID left when the budget ran out (no request failed): the
        /// caller carries `notAsked` and `owedSearch`.
        var budgetStoppedAt: UInt32?
        /// Missing UIDs whose header FETCH was not sent (a stop).
        var notAsked: [UInt32] = []
        /// Unanswered UIDs whose SEARCH was not asked or failed (a stop).
        var owedSearch: [UInt32] = []
    }

    /// The carried part of a range (`Listing.carried`): every UID it names,
    /// capped at `SyncConfig.catchUpCarriedUidCap`. Past the cap the range is cut
    /// at the UID that reaches it (the rest is listed again later), so the
    /// carry always holds the range's lowest UIDs and the listing still moves.
    nonisolated static func carry(
        lo: Int, hi: Int, candidates: [UInt32], missing: [UInt32], deletedListed: [UInt32],
        proven: Bool, heldFloor: UInt32?, loadsFrom: Int?, unanswered: [UInt32] = []
    ) -> IMAPCatchUpState.CarriedRange {
        let cap = SyncConfig.catchUpCarriedUidCap
        let named = (candidates + missing + deletedListed + unanswered).sorted()
        let end = named.count > cap ? Int(named[cap - 1]) : hi
        func upTo(_ uids: [UInt32]) -> [UInt32] { uids.filter { Int($0) <= end } }
        return IMAPCatchUpState.CarriedRange(
            lo: lo, hi: end, candidates: upTo(candidates), missing: upTo(missing),
            deletedListed: upTo(deletedListed), proven: proven,
            heldFloor: heldFloor.flatMap { Int($0) <= end ? $0 : nil },
            loadsFrom: loadsFrom, unanswered: upTo(unanswered))
    }

    /// The width in UIDs of a folder's first listing range, to hold about
    /// `messages` messages, from its EXISTS and UIDNEXT (#1062): the folder's
    /// mean UIDs per message times `messages`, within
    /// `SyncConfig.catchUpListingMinRangeSpan...catchUpListingMaxRangeSpan`.
    /// So a listing costs about EXISTS / `messages` ranges however sparse the UID
    /// space is. With no UIDNEXT, or no message count (zero is read as unknown:
    /// a STATUS without MESSAGES stores it), the minimum width.
    /// *Superseded (#1062):* an empty folder (EXISTS 0) was one range to UIDNEXT,
    /// so a stored count of 0 made one range of a large folder.
    nonisolated static func listingRangeSpan(messages: Int, exists: Int?, uidNext: Int?) -> Int {
        let minimum = SyncConfig.catchUpListingMinRangeSpan
        guard let uidNext, uidNext > 1, let exists, exists > 0 else { return minimum }
        let perMessage = Double(uidNext - 1) / Double(exists)
        return clampedListingRangeSpan(perMessage * Double(max(1, messages)))
    }

    /// The width of the next listing range from the one just listed (#1062): a
    /// range `width` UIDs wide that held `held` messages is scaled to hold about
    /// `messages`, within the configured minimum and maximum widths. A range that
    /// held none gives the maximum. So a bunched stretch shrinks the next range
    /// and a sparse one widens it, whatever the folder's mean density.
    nonisolated static func nextListingRangeSpan(messages: Int, width: Int, held: Int) -> Int {
        guard held > 0 else { return SyncConfig.catchUpListingMaxRangeSpan }
        return clampedListingRangeSpan(Double(width) * Double(max(1, messages)) / Double(held))
    }

    private nonisolated static func clampedListingRangeSpan(_ width: Double) -> Int {
        let minimum = SyncConfig.catchUpListingMinRangeSpan, maximum = SyncConfig.catchUpListingMaxRangeSpan
        guard width.isFinite else { return maximum }
        return min(maximum, max(minimum, Int(width.rounded(.up))))
    }

    /// Load `missing` (ascending) by header, in batches of
    /// `SyncConfig.catchUpLoadBatchSize`, each charged one request before it is
    /// sent. A UID the FETCH does not answer is checked by `UID SEARCH`: gone is
    /// done, still there is held. A record the client cannot read is that
    /// record's failure only: it stays missing, is held the same way and logged,
    /// and the rest of the batch loads. `owedSearch`: unanswered UIDs a carried
    /// range still owes that SEARCH; it is asked first. A stop (the budget, or a
    /// failed request) reports what was not asked yet (`notAsked`, `owedSearch`),
    /// so the caller carries it and no request is paid twice (#1062). No split
    /// and no retry within the slice.
    private func loadMissing(
        _ missing: [UInt32], owedSearch: [UInt32] = [], path: String, epoch: UInt32, context: CatchUpContext
    ) async -> MissingLoad {
        var load = MissingLoad()
        let timeout = context.requestTimeoutSeconds
        let size = SyncConfig.catchUpLoadBatchSize
        // A stop: the budget ran out (`budgetStoppedAt`) or a request failed
        // (`stoppedAt`); `owed` still needs its SEARCH, `rest` was not fetched.
        func stopped(budget: Bool, owed: [UInt32], rest: [UInt32]) -> MissingLoad {
            var stop = load
            let first = (owed + rest).min()
            if budget { stop.budgetStoppedAt = first } else { stop.stoppedAt = first }
            stop.owedSearch = owed
            stop.notAsked = rest
            return stop
        }
        // The SEARCH that decides unanswered UIDs: gone is done, still there is
        // held. Nil when it was not asked (budget) or failed; `failed` tells which.
        func searchUnanswered(_ unanswered: [UInt32]) async -> (present: UIDExistenceResult?, failed: Bool) {
            guard context.hasBudget(cost: 1) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path): budget spent before the SEARCH for \(unanswered.count) unanswered UID(s) — carried")
                }
                return (nil, false)
            }
            do {
                return (try await withTimeout(seconds: timeout) {
                    try await self.searchExistingUIDs(folder: path, uids: unanswered)
                }, false)
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path): SEARCH for \(unanswered.count) unanswered UID(s) failed (\(error)) — resuming at \(unanswered[0])")
                }
                return (nil, true)
            }
        }
        if !owedSearch.isEmpty {
            let asked = await searchUnanswered(owedSearch)
            guard let present = asked.present else { return stopped(budget: !asked.failed, owed: owedSearch, rest: missing) }
            guard present.uidValidity == epoch else {
                load.otherEpoch = present.uidValidity
                return load
            }
            if let first = owedSearch.first(where: present.found.contains) { load.held = first }
        }
        for start in stride(from: 0, to: missing.count, by: size) {
            let batch = Array(missing[start..<min(start + size, missing.count)])
            let after = Array(missing[min(start + size, missing.count)...])
            guard context.hasBudget(cost: 1) else {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path): budget spent before the load of \(batch.count) missing UID(s) — carried from \(batch[0])")
                }
                return stopped(budget: true, owed: [], rest: batch + after)
            }
            let fetched: (decoded: [MessageHeaderInfo], undecoded: [UInt32], observedEpoch: UInt32?)
            do {
                fetched = try await withTimeout(seconds: timeout) {
                    try await self.fetchCatchUpHeaders(folder: path, uids: batch, expectedEpoch: epoch)
                }
            } catch {
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CatchUp] \(path): load of \(batch.count) missing UID(s) failed (\(error)) — resuming at \(batch[0])")
                }
                return stopped(budget: false, owed: [], rest: batch + after)
            }
            guard fetched.observedEpoch == epoch else {
                load.otherEpoch = fetched.observedEpoch ?? 0
                return load
            }
            let requested = Set(batch)
            let answered = fetched.decoded.filter { UInt32($0.messageId).map(requested.contains) ?? false }
            load.loaded += answered.map {
                BackfillResult(id: $0.messageId, header: $0, htmlBody: nil, textBody: nil, error: nil)
            }
            let undecoded = fetched.undecoded.filter(requested.contains)
            if !undecoded.isEmpty, DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CatchUp] \(path): \(undecoded.count) header record(s) could not be read (UIDs \(undecoded.prefix(20))) — left missing, held like an unanswered UID")
            }
            // A record the client could not read is that UID's failure alone: it
            // is not loaded, the rest of the batch is, and it is held like an
            // unanswered UID (proved by SEARCH, bounded, then passed over, so the
            // listing completes as not clean).
            let answeredUids = Set(answered.compactMap { UInt32($0.messageId) })
            let unanswered = batch.filter { !answeredUids.contains($0) }
            guard !unanswered.isEmpty else { continue }
            let asked = await searchUnanswered(unanswered)
            guard let present = asked.present else { return stopped(budget: !asked.failed, owed: unanswered, rest: after) }
            guard present.uidValidity == epoch else {
                load.otherEpoch = present.uidValidity
                return load
            }
            if let first = unanswered.first(where: present.found.contains) {
                load.held = min(load.held ?? first, first)
            }
        }
        return load
    }
}
