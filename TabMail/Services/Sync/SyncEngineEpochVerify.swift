/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// T4.S6b — the VERIFIED epoch bootstrap for a folder that already holds rows.
///
/// This file is an `extension SyncEngine`; there is no `SyncEngineEpochVerify`
/// TYPE to cite.
///
/// ## The residual this closes
///
/// `Folder.lastKnownUidValidity` nil means UNKNOWN — it is NOT proof of an
/// empty/fresh folder. Two production lifecycles manufacture "populated, yet
/// nil-epoch":
///  (a) a folder populated before migration `v63` added the column, or by any path
///      that never recorded an epoch;
///  (b) a folder row deleted on a remote disappearance and RE-CREATED for the same
///      path — migration `v2` dropped the `messageHeader.folderId` FK, so its
///      headers survive orphaned and the deterministic `"\(accountId):\(path)"` id
///      re-adopts them under a brand-new, nil-epoch row.
///
/// Until T4.S6b the first observation simply ASSERTED those rows belonged to the
/// epoch just observed. If the numbering had in fact turned over, that assertion
/// is what makes the deletion-reconcile walk's stored-vs-live comparison equal —
/// disarming its abort guard and turning it into a mass deleter (ADR-IOS-051) —
/// and what admits a bare-UID durable op against a numbering nobody checked (C3).
///
/// T4.S6b makes the unverified stamp IMPOSSIBLE (`bootstrapFolderUidValidity`'s
/// `NOT EXISTS` term; the same term on both `fullSync` folder-list upsert arms)
/// and makes the reconcile walk REFUSE rather than adopt. This function is the
/// only remaining way such a folder gets an epoch, and it earns it by PROOF.
///
/// ## Why it is a separate async step and not a term in an existing writer
///
/// Every current stamp site sits inside a GRDB write closure, and `await` is not
/// expressible in any of them: `PrioritizedDatabase.write`'s closure is
/// NON-async, so a network round trip inside one is not merely risky — the
/// compiler forbids it. `fullSync`'s folder-list upsert is worse for naive
/// placement: it is ONE `pool.write` spanning every folder of the account.
/// Verification therefore has to be its own step, strictly outside every write.
///
/// ## ⚑ R0 — NO REFERENCE in `v2final`. VERIFIED, not inherited.
///
/// Three checks, recorded so the next agent does not re-derive them:
///  1. the reference's reaction has the IDENTICAL refusal — it will not start on a
///     folder whose stored epoch is nil and which is not already quarantined — so
///     it does not detect this entry path either;
///  2. the reference's single persist API,
///     `AccountManager.recordObservedUidValidity`, stamps a nil row WITHOUT ever
///     asking whether headers exist (`git show
///     v2final:TabMail/Services/Account/AccountManager.swift`, the
///     `folder.lastKnownUidValidity = Int(observed)` branch);
///  3. a disproof sweep over `v2final -- 'TabMail/Services/Sync/*'
///     'TabMail/Services/Account/*' 'TabMail/Models/Folder.swift'` finds no
///     `prePopulated`, no `verifyEpoch`/`unverified`, no `localHeaders`, and no
///     `fetchCount(db)` near any epoch write; its `uidValidityWriteAllowed` /
///     `uidValidityWalkWriteAllowed` are OBSERVED-VS-STORED comparisons that both
///     fail OPEN on a nil stored side.
/// **"The reference does X" is unavailable for anything in this file.** Every
/// decision below stands on its own stated merits.
extension SyncEngine {

    // MARK: - Sampling

    /// One sampled row: a local UID and the RFC-822 Message-ID stored against it,
    /// NORMALIZED at read time (see `classifyEpochVerificationSample`).
    struct EpochVerificationSample: Sendable, Equatable {
        let uid: UInt32
        let normalizedRfc822: String
    }

    /// What one verification pass concluded. Returned for logging and for tests
    /// that want the classification; the INVARIANTS are asserted on the database
    /// end state, never on this value.
    enum EpochVerificationOutcome: Sendable, Equatable {
        /// Nothing to do: the folder is stamped already, is in quarantine, holds no
        /// rows (the blind bootstrap path owns that case), or has vanished.
        case notApplicable
        /// The SELECT that served the sample reported NO UIDVALIDITY, or the sample
        /// could not be taken/fetched at all. **DO NOTHING** — see the anti-brick
        /// rule on `verifyAndBootstrapPrePopulatedFolderEpoch`.
        case unobservable
        /// Proof obtained: at least `SyncConfig.uidValidityVerifyMinAgreements`
        /// RFC-822 agreements and zero mismatches. The epoch is stamped.
        case verified(epoch: UInt32)
        /// Proof NOT obtained (a mismatch, or zero agreements). The folder is
        /// quarantined and handed to the purge-and-resync reaction.
        case handedToReaction(agreements: Int, mismatches: Int)
    }

    /// Sample the folder's own rows: the highest-UID half and the lowest-UID half,
    /// de-duplicated.
    ///
    /// **A SPREAD, not the top N — and that is a correctness decision, not a
    /// performance one.** After a UIDVALIDITY change the server re-assigns `1…M`:
    ///  - a LOW local UID usually EXISTS under the new numbering and addresses a
    ///    DIFFERENT message ⇒ a positive MISMATCH, the strongest signal obtainable;
    ///  - a HIGH local UID (near the old UIDNEXT, above `M`) usually does NOT exist
    ///    ⇒ no evidence.
    /// A high-only sample therefore reaches the zero-agreements leg BY DEFAULT on a
    /// genuine renumber — still fail-closed, but the purge would then be triggered
    /// by ABSENCE OF EVIDENCE rather than by PROOF, which is exactly the shape that
    /// misfires on a benign top-of-folder deletion burst.
    ///
    /// Both halves ride the `v66` expression index
    /// `messageHeader_folderId_uidInt ON messageHeader(folderId, CAST(messageId AS
    /// INTEGER))` as a folderId seek plus an ordered range scan. The
    /// `rfc822MessageId` predicate is not in the index, so it filters as the scan
    /// walks — bounded by the LIMIT in the common case.
    ///
    /// Rows with no stored RFC-822 Message-ID are excluded IN THE STATEMENT: they
    /// can only ever produce "no evidence", so spending the sample budget on them
    /// weakens the verification for nothing.
    nonisolated static func sampleUidsForEpochVerification(
        _ db: Database, folderId: String, highCount: Int, lowCount: Int
    ) throws -> [EpochVerificationSample] {
        func half(descending: Bool, limit: Int) throws -> [EpochVerificationSample] {
            guard limit > 0 else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT messageId, rfc822MessageId FROM messageHeader
                 WHERE folderId = ? AND rfc822MessageId IS NOT NULL AND rfc822MessageId != ''
                 ORDER BY CAST(messageId AS INTEGER) \(descending ? "DESC" : "ASC")
                 LIMIT ?
                """, arguments: [folderId, limit])
            return rows.compactMap { row in
                guard let rawId: String = row["messageId"], let uid = UInt32(rawId) else { return nil }
                guard let rawRfc: String = row["rfc822MessageId"] else { return nil }
                let normalized = EmailFilter.normalizeMessageId(rawRfc)
                guard !normalized.isEmpty else { return nil }
                return EpochVerificationSample(uid: uid, normalizedRfc822: normalized)
            }
        }
        // De-duplicate: a folder with fewer than high+low qualifying rows returns
        // OVERLAPPING rows from the two halves, and a duplicated agreement would
        // inflate the evidence count.
        var seen = Set<UInt32>()
        var result: [EpochVerificationSample] = []
        for sample in try half(descending: true, limit: highCount) + half(descending: false, limit: lowCount)
        where seen.insert(sample.uid).inserted {
            result.append(sample)
        }
        return result
    }

    // MARK: - Classification (pure — the whole correctness of the item lives here)

    /// Classify the server's answer against the sampled rows.
    ///
    /// | observation | classification |
    /// |---|---|
    /// | server returns UID u ∈ S, normalized rfc822 EQUAL | **AGREE** |
    /// | server returns UID u ∈ S, normalized rfc822 DIFFERS | **MISMATCH** |
    /// | server returns UID u ∈ S with NO rfc822 | no evidence |
    /// | UID u ∈ S NOT RETURNED | **no evidence — NEVER a mismatch** |
    ///
    /// **"Not returned" must never count as DISAGREEMENT.** A locally-known UID can
    /// be absent because another client deleted the message — routine on a perfectly
    /// intact mailbox. Counting it as a mismatch would purge healthy folders.
    /// `IMAPProvider.mapMessageInfo` also DROPS rows outright (it returns nil when
    /// both `internalDate` and the envelope `Date:` fail to parse), so a sampled UID
    /// can vanish from the result without being absent from the server; this rule is
    /// what makes that safe, and it is a deliberate classification rather than an
    /// accident.
    ///
    /// **"Not returned" must never count as AGREEMENT either**, which is why the
    /// caller fails closed on zero agreements: after a renumber the new numbering
    /// typically restarts low, so every HIGH local UID is simply absent. "All
    /// missing" is the renumber's NORMAL shape and must not be read as consent.
    ///
    /// **Both sides are normalized HERE, explicitly.** The exemplar this paragraph
    /// used to cite — `AccountManager.expandWithSiblingsByRfc822`, which compared a
    /// stored value against the column with no re-normalization — **no longer
    /// exists**: it was REMOVED by `065a827ca` as a deliberate D4 subtract, because
    /// selecting mutation targets by RFC 822 Message-ID is exactly what ADR-IOS-068
    /// clause 2 bans (the fan-out defect `IOS-IMAP-002`). It is named here only to
    /// keep the reasoning legible, and must NOT be read as a live call site.
    ///
    /// The ARGUMENT it illustrated is unchanged and is why this comparison
    /// normalizes both sides itself: relying on every write path to normalize is an
    /// invariant held by DISCIPLINE, not construction. In that now-removed site a
    /// `<a@x>` vs `a@x` skew merely cost a missed sibling flip. HERE the same skew
    /// would produce a FALSE MISMATCH on
    /// every sampled row of every folder, which drives the reaction, which PURGES
    /// AND RE-DOWNLOADS the entire mailbox. This design promotes that bug class from
    /// cosmetic to destructive, so the comparison must not inherit any other path's
    /// write discipline. `EmailFilter.normalizeMessageId` is idempotent (trim, strip
    /// one leading `<`, strip one trailing `>`), so re-applying it to an
    /// already-bare stored value costs nothing.
    nonisolated static func classifyEpochVerificationSample(
        sampled: [EpochVerificationSample],
        serverMessages: [MessageHeaderInfo]
    ) -> (agreements: [EpochVerificationSample], mismatches: [EpochVerificationSample]) {
        var serverByUid: [UInt32: String] = [:]
        for info in serverMessages {
            guard let uid = UInt32(info.messageId) else { continue }
            guard let raw = info.rfc822MessageId else { continue }
            let normalized = EmailFilter.normalizeMessageId(raw)
            guard !normalized.isEmpty else { continue }
            serverByUid[uid] = normalized
        }
        var agreements: [EpochVerificationSample] = []
        var mismatches: [EpochVerificationSample] = []
        for sample in sampled {
            // NOT RETURNED (or returned without an rfc822) ⇒ no evidence. Never a
            // mismatch, never an agreement.
            guard let serverKey = serverByUid[sample.uid] else { continue }
            if serverKey == sample.normalizedRfc822 {
                agreements.append(sample)
            } else {
                mismatches.append(sample)
            }
        }
        return (agreements, mismatches)
    }

    /// The stamp decision over a classified sample. Pure, so the fail-closed
    /// direction is unit-testable without a network or a database.
    nonisolated static func epochVerificationStampAllowed(
        agreements: Int, mismatches: Int, minAgreements: Int
    ) -> Bool {
        mismatches == 0 && agreements >= minAgreements
    }

    // MARK: - The verified door

    /// The ONLY way a folder that already holds rows gets `lastKnownUidValidity`
    /// stamped. Called at exactly two places, both `async`, neither inside a write:
    /// the head of `runSyncMessages` (before its own fetch), and the head of full
    /// sync's deletion-reconcile loop (which visits EVERY syncable folder, including
    /// the CONDSTORE-quiet ones the per-folder loop skips — without that second site
    /// a quiet Archive stays stamped-by-nothing indefinitely).
    ///
    /// Steps, all outside any write transaction except the last:
    ///  1. cheap early-out + sample, in ONE read;
    ///  2. sample FETCH (network);
    ///  3. **`observedEpoch == nil` ⇒ RETURN, DO NOTHING** (the anti-brick, below);
    ///  4. any MISMATCH, or ZERO agreements ⇒ arm the quarantine and hand the folder
    ///     to the purge-and-resync reaction;
    ///  5. otherwise re-read the agreeing rows INSIDE the write transaction and
    ///     stamp through `bootstrapVerifiedFolderUidValidity`.
    ///
    /// 🚨 **THE ANTI-BRICK (step 3) — this is the mirror-image hazard of the fix,
    /// and it must stay exactly as written.** If the folder's SELECT reports no
    /// UIDVALIDITY at all, arming the reaction is a PERMANENT BRICK: the reaction
    /// purges the folder (step 3 of the reaction), then its step-5
    /// `observeFreshUidValidity` returns nil, aborts, and LEAVES
    /// `uidValidityResetPendingAt` SET **by design** (every abort leg does, so the
    /// folder is re-drivable). The folder is then permanently quarantined — every
    /// sync pass skipped, every gesture refused, every re-drive re-aborting — WITH
    /// ITS MAIL ALREADY DELETED. Doing nothing instead leaves the column nil, which
    /// is exactly today's `IOS-EPOCH-001` accepted window: gestures refused, the
    /// reconcile walk refuses, NO data touched, and self-healing the moment one
    /// SELECT reports an epoch.
    ///
    /// The asymmetry that makes every OTHER fail-closed leg safe: in the
    /// "unverifiable" and "mismatch" legs the server DID report an epoch, so the
    /// reaction's step 5 can always stamp and the reaction terminates.
    ///
    /// **Why arm-then-spawn rather than awaiting the reaction inline:**
    /// `runUidValidityResetReaction` calls `try? await provider.disconnect()`,
    /// tearing down the connection `runSyncMessages` is about to use —
    /// `SyncEngineDeletionReconcile` already documents that hazard ("Fired AFTER the
    /// walk has fully returned"). Arming is a pure DB write, and the spawn matches
    /// `AccountManager.defaultUidValidityChangeHandler`'s established shape. By the
    /// time the caller's own in-transaction guards run, the folder is either stamped
    /// (guard (b) proceeds normally) or quarantined (guard (a) skips the pass and
    /// the reaction owns it).
    ///
    /// **Why entry is via the ARM and not `fireUidValidityChangeHandler`:** that
    /// trigger channel takes a NON-OPTIONAL `storedValue: UInt32`, and the
    /// reaction's own trigger validation REFUSES to start when
    /// `lastKnownUidValidity == nil` and the folder is not quarantined. Arming first
    /// makes `uidValidityResetPendingAt != nil` true, which short-circuits that
    /// refusal. `uidValidityResetArmFlag` is REUSED rather than duplicated —
    /// single-writer discipline for that column.
    ///
    /// **No reentrancy, no loop.** The reaction's step-6 resync re-enters
    /// `syncFolderMessages` → `runSyncMessages`, but its step 5 has already stamped
    /// a non-nil epoch, so step 1 here returns immediately.
    /// `SyncEngine.resetEmptyFolderCrawlEpoch` can clear the column back to nil, but
    /// only for a ZERO-HEADER folder, which step 1 also returns on (the blind
    /// bootstrap path owns it).
    @discardableResult
    nonisolated static func verifyAndBootstrapPrePopulatedFolderEpoch(
        folderId: String,
        folderPath: String,
        accountId: String,
        provider: any EmailProvider,
        dbPool: PrioritizedDatabase
    ) async -> EpochVerificationOutcome {
        // ── Step 1: cheap early-out + sample, in ONE read.
        let sampled: [EpochVerificationSample]
        do {
            guard let candidates = try await dbPool.read({ db -> [EpochVerificationSample]? in
                guard let folder = try Folder.fetchOne(db, key: folderId) else { return nil }
                // `== nil` and not `knownUidValidity(...) == nil`, deliberately: this
                // must agree EXACTLY with the `lastKnownUidValidity IS NULL` predicate
                // the stamp in step 5 carries, or a (structurally impossible) stored 0
                // would send us through a whole verification whose write can never land.
                guard folder.lastKnownUidValidity == nil else { return nil }
                // A quarantined folder is the reaction's, not ours.
                guard folder.uidValidityResetPendingAt == nil else { return nil }
                // ZERO headers is a genuine first sync — the blind bootstrap path (A)
                // stamps it, and issuing a verification FETCH here would be pure waste.
                guard try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db) > 0
                else { return nil }
                return try sampleUidsForEpochVerification(
                    db, folderId: folderId,
                    highCount: SyncConfig.uidValidityVerifySampleHighCount,
                    lowCount: SyncConfig.uidValidityVerifySampleLowCount)
            }) else { return .notApplicable }
            sampled = candidates
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[EpochVerify] \(folderId): sample read failed: \(error) — doing nothing this pass")
            }
            return .unobservable
        }

        guard !sampled.isEmpty else {
            // Pathological: the folder holds rows but NONE carries an RFC-822
            // Message-ID, so no verification is possible. We DO NOTHING rather than
            // hand the folder to the reaction, because at this point no FETCH has
            // been issued and therefore nothing proves the server reports UIDVALIDITY
            // at all — reacting here could hit the permanent brick described above.
            // The cost of doing nothing is the `IOS-EPOCH-001` accepted window, and
            // it self-heals the moment any row gains an rfc822.
            if DebugModeManager.isLoggingEnabled() {
                print("[EpochVerify] \(folderId): populated but no row carries an rfc822 Message-ID — cannot verify, leaving the epoch unknown")
            }
            return .unobservable
        }

        // ── Step 2: the sample FETCH (network).
        let fetched: (messages: [MessageHeaderInfo], observedEpoch: UInt32?)
        do {
            fetched = try await provider.sampleHeadersForEpochVerification(
                folder: folderPath, uids: sampled.map(\.uid))
        } catch {
            // A network/protocol failure is not evidence of anything. Do nothing.
            if DebugModeManager.isLoggingEnabled() {
                print("[EpochVerify] \(folderId): verification fetch failed: \(error) — doing nothing this pass")
            }
            return .unobservable
        }

        // ── Step 3: THE ANTI-BRICK. No reported epoch ⇒ no arm, no react, no stamp.
        guard let observedEpoch = fetched.observedEpoch, observedEpoch != 0 else {
            if DebugModeManager.isLoggingEnabled() {
                print("[EpochVerify] \(folderId): the SELECT that served the sample reported no UIDVALIDITY — leaving the epoch unknown (never quarantine on this leg)")
            }
            return .unobservable
        }

        // ── Step 4: classify.
        let classified = classifyEpochVerificationSample(
            sampled: sampled, serverMessages: fetched.messages)
        guard epochVerificationStampAllowed(
            agreements: classified.agreements.count,
            mismatches: classified.mismatches.count,
            minAgreements: SyncConfig.uidValidityVerifyMinAgreements
        ) else {
            // Ungated, per CLAUDE.md rule 12 exception (b) — production observability
            // needs the turnover itself, matching `runSyncMessages`'s own turnover
            // line. This is the ONLY place a purge of a nil-epoch folder originates.
            BackgroundSyncLogger.log("[EpochVerify] \(folderId): local UIDs do NOT belong to observed epoch \(observedEpoch) (agreements=\(classified.agreements.count) mismatches=\(classified.mismatches.count) sampled=\(sampled.count)) — quarantining for the purge-and-resync reaction")
            guard await AccountManager.shared.uidValidityResetArmFlag(folderId: folderId) else {
                return .handedToReaction(
                    agreements: classified.agreements.count,
                    mismatches: classified.mismatches.count)
            }
            Task {
                await AccountManager.shared.runUidValidityResetReaction(
                    accountId: accountId, folderPath: folderPath)
            }
            return .handedToReaction(
                agreements: classified.agreements.count,
                mismatches: classified.mismatches.count)
        }

        // ── Step 5: stamp, re-proving the agreeing rows INSIDE the transaction.
        // The sample was read BEFORE a network round trip, so it is a stale snapshot:
        // a merge, a purge or the NSE bridge can have deleted or re-keyed those rows
        // in between, and a stamp resting on a row that no longer says what it said
        // rests on nothing. Same `folderInTxn` discipline `runSyncMessages` uses.
        let agreeing = classified.agreements
        do {
            let stamped = try await dbPool.write(label: "epoch-verify-stamp") { db -> Bool in
                guard let folder = try Folder.fetchOne(db, key: folderId),
                      folder.lastKnownUidValidity == nil,
                      folder.uidValidityResetPendingAt == nil else { return false }
                for sample in agreeing {
                    let stored = try MessageHeader
                        .filter(Column("folderId") == folderId
                                && Column("messageId") == String(sample.uid))
                        .fetchOne(db)?
                        .rfc822MessageId
                    guard let stored,
                          EmailFilter.normalizeMessageId(stored) == sample.normalizedRfc822
                    else { return false }
                }
                try bootstrapVerifiedFolderUidValidity(
                    db, folderId: folderId, observed: Int(observedEpoch))
                return true
            }
            guard stamped else { return .notApplicable }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[EpochVerify] \(folderId): stamp write failed: \(error) — the epoch stays unknown; the next pass re-verifies")
            }
            return .unobservable
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[EpochVerify] \(folderId): verified epoch \(observedEpoch) (agreements=\(agreeing.count) of \(sampled.count) sampled)")
        }
        return .verified(epoch: observedEpoch)
    }
}
