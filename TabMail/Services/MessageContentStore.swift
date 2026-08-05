/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The single answer to **"does anything still own this content key?"**
///
/// ⚑ NO REFERENCE — INVENTED. Branch `v2final` has no `MessageContentStore`, no
/// `owners(of:)` and no `releaseUnowned` — and could not have had them. There,
/// `messageHeader.id` ITSELF was re-keyed, so one content row always corresponded
/// to exactly one header and the two key spaces could never diverge; the N:1
/// ownership question this type answers **could not arise**. `v3` keeps the header
/// PK provider-keyed on purpose (the durable action queue must be able to archive
/// *this* copy of a message without archiving *that* one — see `ContentKeySpace`),
/// so once the content key's tail becomes the RFC 822 Message-ID at Stage E1,
/// **N headers can share one content row** and "is this key still a
/// `messageHeader.id`?" stops being the same question as "is this content still
/// owned?".
///
/// ## Why this exists — the mass-deletion hazard
///
/// Four sweeps decide what content is garbage by asking whether its key is still
/// a `messageHeader.id`:
///
/// - `SyncEngine.pruneFTSOrphans`
/// - `SyncEngine.backfillFolderIdsIfNeeded`
/// - `BodyAssetMaintenance.pruneOrphans`
/// - `SyncEngine.runEvictStaleBodies` — the fourth, gated at Stage D. Stage C's
///   census named only the first three: this one is a TTL cache evictor whose
///   orphan branch was unreachable while the FK cascade front-ran it, and Stage D
///   is precisely what makes it live.
///
/// The instant a content key stops equalling `messageHeader.id`, **every** FTS row
/// and **every** asset row of a UID-addressed account reads as an orphan and is
/// swept. That is the single largest data-loss risk in the content-key refactor.
/// Each of those sweeps now asks this type instead, and a key it cannot prove dead
/// is KEPT.
///
/// ## 🚨 THE FAIL-SAFE DIRECTION — never symmetric, never traded for tidiness
///
/// On error, on ambiguity, on any inability to decide: **DO NOT DELETE.** A leaked
/// row is disk garbage that the very sweeps above reclaim on a later pass. An
/// over-eviction is a message silently missing from search with no signal to the
/// user and no path back except a full re-index. Every `catch` in this file
/// therefore resolves to "keep".
///
/// ## 🚨 THE ORDERING CONTRACT
///
/// Capture the content key **before or inside** the header-delete transaction;
/// call `releaseUnowned` **after that transaction commits**. Reversed, the header
/// still exists when owners are counted, the count is always ≥ 1, and the helper
/// never deletes anything — a permanent, silent no-op that every outcome-only test
/// would still pass. `ContentOwnershipSweepTests` pins the order directly, with two
/// tests: the contract in isolation, and the same contract through a routed production
/// caller asserting on the FTS row — a store the FK cascade does not reach.
///
/// ## The FK cascade is GONE as of Stage D — this type is the body's only reclaimer
///
/// `messageBody.id` used to reference `messageHeader(id)` `onDelete: .cascade`, so
/// deleting a header removed its body row before this type was ever consulted. That
/// was correct while keys were 1:1 (the cascade and `releaseUnowned` always agreed
/// and the cascade simply got there first) and would have become a data-loss bug the
/// day they diverge — it deletes content still owned by the other N−1 headers, below
/// the application layer where this type cannot veto it. Worse, with
/// `foreignKeysEnabled = true` the live FK would REJECT the body INSERT outright for
/// every rfc-tailed key. `v70_dropMessageBodyHeaderFK` removed it, which is why the
/// ordering C → D → E1 cannot be shortcut.
///
/// The consequence for every caller: **`.body` is no longer implicit.** A site that
/// deletes a header and wants its cached HTML reclaimed must either pass `.body`
/// here or delete the row itself in the same transaction. Anything missed degrades
/// to a bounded leak that `runEvictStaleBodies` reclaims — never to over-eviction.
enum MessageContentStore {

    // MARK: - Scope

    /// The `(account, folder)` pair a content key is resolved WITHIN, plus the
    /// identity space that account's content rows draw their key tail from.
    ///
    /// ⚑ Scope is a **PARAMETER**, never an inlined folder predicate. The owner has
    /// deferred — not rejected — dropping the `accountId:folderPath:` prefix and
    /// keying content purely by RFC 822 Message-ID. Keeping scope a parameter makes
    /// that a one-line change to this struct; inlining a folder predicate at each
    /// call site would make it a rewrite. For the same reason nothing here may
    /// assume a 1:1 row↔header relation.
    struct ContentKeyScope: Hashable, Sendable {
        let accountId: String
        /// The provider-canonical folder path — Gmail label name, Graph folder id,
        /// IMAP mailbox path. May legitimately contain `':'` (RFC 3501 permits any
        /// hierarchy delimiter), which is why every operation below prefix-matches
        /// rather than splitting.
        let folderPath: String
        let space: ContentKeySpace

        var folderId: String {
            MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        }

        var keyPrefix: String {
            MessageIdentity.headerIdPrefix(accountId: accountId, folderPath: folderPath)
        }

        /// Whether `contentKey` is minted inside this scope. Prefix match PLUS the
        /// no-deeper-colon guard, never a component split — see
        /// `MessageIdentity.headerIdBelongsToFolder` for why the split is wrong.
        func contains(_ contentKey: ContentKey) -> Bool {
            MessageIdentity.headerIdBelongsToFolder(
                contentKey.rawValue, accountId: accountId, folderPath: folderPath)
        }

        /// The key's TAIL inside this scope — the provider message id under
        /// `.stableProviderId`, or (from Stage E1) the RFC 822 Message-ID under
        /// `.uidAddressed`. `nil` when the key does not belong to this scope.
        func tail(of contentKey: ContentKey) -> String? {
            guard contains(contentKey) else { return nil }
            return String(contentKey.rawValue.dropFirst(keyPrefix.count))
        }

        /// The scope a live header's content rows are keyed in.
        static func forHeader(_ header: MessageHeader, space: ContentKeySpace) -> ContentKeyScope {
            ContentKeyScope(
                accountId: header.accountId, folderPath: header.folderPath, space: space)
        }
    }

    /// Every scope currently reachable in the database, one per `Folder` row.
    ///
    /// Used to resolve a BARE content key (one read back out of a content store,
    /// with no header beside it) to the scope it was minted in. A key that matches
    /// no scope is `undetermined`, never `unowned`.
    static func roster(_ db: Database) throws -> [ContentKeyScope] {
        let spaceByAccount: [String: ContentKeySpace] = try Account.fetchAll(db)
            .reduce(into: [:]) { $0[$1.id] = $1.provider.contentKeySpace }
        return try Folder.fetchAll(db).compactMap { folder in
            guard let space = spaceByAccount[folder.accountId] else { return nil }
            return ContentKeyScope(
                accountId: folder.accountId, folderPath: folder.path, space: space)
        }
    }

    /// The one scope in `roster` that `contentKey` belongs to, if any.
    ///
    /// At most one can match: `contains` pairs the folder prefix with the
    /// no-deeper-colon guard, so a key under a nested child folder
    /// (`acct:INBOX:Sub:42`) matches `INBOX:Sub` and is EXCLUDED from `INBOX`.
    static func resolveScope(for contentKey: ContentKey, in roster: [ContentKeyScope]) -> ContentKeyScope? {
        roster.first { $0.contains(contentKey) }
    }

    // MARK: - Ownership

    /// Whether anything still owns a content key.
    ///
    /// ⚠ `undetermined` is NOT `unowned`. It is the case where the question could
    /// not be answered — the scope did not resolve, or the read threw — and every
    /// deletion path must treat it as "keep".
    enum Ownership: Sendable, Equatable {
        /// At least one live `messageHeader` mints this content key. The payload is
        /// the owning `messageHeader.id`s.
        case owned([String])
        /// No live header mints this content key.
        case unowned
        /// Could not decide. NEVER delete on this verdict.
        case undetermined(reason: String)
    }

    /// The ownership superset statement `owners(of:scope:db:)` runs. Named — rather
    /// than inlined at its one call site — so the PLAN invariant can be asserted
    /// against the statement the production path actually executes, instead of
    /// against a copy in a test that would silently drift away from it. See
    /// `owners(of:scope:db:)` for why the shape is a hinted `UNION ALL`.
    static let ownersSQL = """
        SELECT id, accountId, folderPath, messageId, rfc822MessageId
        FROM messageHeader INDEXED BY messageHeader_folderId_messageId
        WHERE folderId = ? AND messageId = ?
        UNION ALL
        SELECT id, accountId, folderPath, messageId, rfc822MessageId
        FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
        WHERE rfc822MessageId = ? AND folderId = ?
        """

    /// The `messageHeader.id`s that currently mint `contentKey` inside `scope`.
    ///
    /// ⚑ **Returns a COLLECTION from day one**, even though today it is always 0 or
    /// 1 (the header PK is `accountId:folderPath:messageId`, so no two headers in
    /// one folder can share a provider message id). A `Bool` or an optional would
    /// have to be redesigned at Stage E1, where N headers in one folder genuinely
    /// share a single RFC-tailed content key.
    ///
    /// Two passes, deliberately:
    ///
    /// 1. An **index-anchored SUPERSET** in SQL — a `UNION ALL` of one arm per key
    ///    space, each pinned to the index that covers ITS tail column, so the tail
    ///    is always an equality probe.
    /// 2. **Exact recomputation in Swift** — each candidate's key is re-minted
    ///    through `ContentKey.forHeader` and compared. The superset admits rows that
    ///    do NOT mint this key (e.g. a header whose `rfc822MessageId` equals the
    ///    tail while its content key is still provider-id-tailed), and admitting one
    ///    of those as an owner would leak content forever.
    ///
    /// A single clever SQL predicate was deliberately NOT written: it would either
    /// stop being index-backed or would encode the mint's rules a second time, where
    /// they could drift from `ContentKey.forHeader`.
    ///
    /// 🚨 WHY `UNION ALL` AND NOT `folderId = ? AND (rfc822MessageId = ? OR
    /// messageId = ?)`, WHICH IS WHAT THIS USED TO BE. That predicate's plan depends
    /// on `sqlite_stat1`, and this probe runs in sweeps of hundreds of keys.
    /// Measured with `EXPLAIN QUERY PLAN` on the v83 schema at 300k headers /
    /// 100k per folder (SQLite 3.51.0):
    ///
    /// ```
    /// OR form, NO STAT ROW FOR A FULL INDEX (regimes A and B below — identical):
    ///   SEARCH messageHeader USING INDEX messageHeader_folderId_uidInt (folderId=?)
    /// OR form, post-ANALYZE on a populated table (regime C):
    ///   MULTI-INDEX OR
    ///     INDEX 1: SEARCH … USING INDEX messageHeader_rfc822MessageId (rfc822MessageId=?)
    ///     INDEX 2: SEARCH … USING INDEX messageHeader_folderId_messageId (folderId=? AND messageId=?)
    /// ```
    ///
    /// The stats-poor plan is a **walk of the whole folder, per key**, and it is the
    /// ordinary state of a fresh install. Independently measured at 500 missing-key
    /// probes in **11.9 s** in that regime vs **<0.001 s** after a populated
    /// `ANALYZE`, and ~16 ms vs ~0.2 ms per call at 100k rows (Mac numbers, system
    /// SQLite — the ratio is the finding, not the absolutes).
    ///
    /// ⚠️ THE REGIME IS "NO STAT ROW FOR A **FULL** INDEX", NOT "EMPTY
    /// `sqlite_stat1`" — this doc said the latter until 2026-08-05 and it is false.
    /// `ANALYZE` against an empty `messageHeader` does NOT leave `sqlite_stat1`
    /// empty: it creates the table and writes one row per **partial** index
    /// (measured at SQLite 3.51.0 over `messageHeader`'s own index set — 5 rows,
    /// `…_headerIncomplete`, `…_aiIncomplete`, `…_embeddingIncomplete`,
    /// `…_unreadSweep`, `…_reminderLookup`, each `0 0`; other tables' partial
    /// indexes add their own), and NO row for any full index. A partial
    /// index's row does not give the planner the table's row estimate, which is why
    /// all three of these plan the OR form identically to a database that has never
    /// been analysed at all:
    ///
    /// ```
    /// A. no sqlite_stat1 at all           → messageHeader_folderId_uidInt (folderId=?)
    /// B. ANALYZE on an EMPTY table        → messageHeader_folderId_uidInt (folderId=?)   ← fresh install
    /// C. ANALYZE on 300k rows             → MULTI-INDEX OR (two seeks)
    /// ```
    ///
    /// A "is `sqlite_stat1` empty?" check would therefore report *healthy* on a
    /// fresh install and be wrong. The rows are there; the useful ones are not.
    ///
    /// Nor is it still true that `ANALYZE` runs only inside migration bodies: as of
    /// the 2026-08-05 amendment to ADR-IOS-029 the background WAL maintenance pass
    /// runs a whole-database `ANALYZE` once per schema change
    /// (`SyncEngine.runRefreshPlannerStatisticsIfStale`). That pass is what moves a
    /// real device from regime B to regime C — but it is background and deferred, so
    /// this statement must not depend on having run. Both arms below plan
    /// identically in ALL THREE regimes:
    ///
    /// ```
    /// COMPOUND QUERY
    ///   LEFT-MOST SUBQUERY: SEARCH … USING INDEX messageHeader_folderId_messageId (folderId=? AND messageId=?)
    ///   UNION ALL:          SEARCH … USING INDEX messageHeader_rfc822MessageId (rfc822MessageId=?)
    /// ```
    ///
    /// ⚠️ THE TWO INDEX NAMES ARE LOAD-BEARING, AND THE `INDEXED BY` HINTS ARE NOT
    /// DECORATION: without the hint on the second arm SQLite picks
    /// `messageHeader_folderId_uidInt (folderId=?)` in regimes A and B and walks the
    /// folder anyway — the hint is what removes the stats dependency, not the
    /// `UNION ALL` by itself. A migration that renames or drops either index makes
    /// this statement throw, which `ownership(of:scope:db:)` turns into
    /// `.undetermined` — so every deletion path KEEPS its content. That is loud and
    /// fail-safe, never a wrong delete.
    static func owners(of contentKey: ContentKey, scope: ContentKeyScope, db: Database) throws -> [String] {
        guard let tail = scope.tail(of: contentKey) else { return [] }
        let candidates = try Row.fetchAll(
            db, sql: ownersSQL,
            arguments: [scope.folderId, tail, tail, scope.folderId]
        )
        // `UNION ALL`, not `UNION`: a plain `UNION` dedupes by sorting the whole
        // compound result, which is exactly the cost this rewrite removes. The one
        // row that can appear on both arms is a header whose provider message id AND
        // whose RFC 822 Message-ID are both the tail, so dedupe by id here.
        var seen = Set<String>()
        var owners: [String] = []
        for row in candidates {
            let id = row["id"] as String
            guard seen.insert(id).inserted else { continue }
            let minted = ContentKey.forHeader(
                accountId: row["accountId"] as String,
                folderPath: row["folderPath"] as String,
                providerMessageId: row["messageId"] as String,
                rfc822MessageId: row["rfc822MessageId"] as String?,
                space: scope.space
            )
            if minted == contentKey { owners.append(id) }
        }
        return owners
    }

    /// `owners`, wrapped in the verdict the deletion paths actually consume.
    static func ownership(of contentKey: ContentKey, scope: ContentKeyScope, db: Database) -> Ownership {
        do {
            let owners = try owners(of: contentKey, scope: scope, db: db)
            return owners.isEmpty ? .unowned : .owned(owners)
        } catch {
            return .undetermined(reason: "owner read failed: \(error)")
        }
    }

    // MARK: - Tail extraction WITHOUT a component split

    /// The key's TAIL after the `"<folderId>:"` prefix, or `nil` when the key does
    /// not belong to that folder.
    ///
    /// ⚑ THIS IS THE #43 FIX, STATED AS AN INVARIANT: **a `headerId`/`ContentKey`
    /// composite is never parsed by splitting it on `':'`.** `folderPath` may
    /// legitimately contain a `':'` — RFC 3501 permits any hierarchy delimiter, and
    /// a Gmail/Outlook label name can contain one too — so a four-component key is
    /// perfectly valid and a `components(separatedBy: ":").count == 3` guard
    /// silently rejects it. Where that guard sat in front of a recovery leg, the
    /// consequence was that the row got **deleted instead of re-keyed**, losing its
    /// indexed body and its `messages_vec` embedding, for exactly the users with
    /// unusual folder names.
    ///
    /// The fix is never "raise the part count" or "`maxSplits: 2`" — the tail is the
    /// LAST component, so a split-based parse would have to count from the end, and
    /// it reintroduces a fragile parse where this codebase deliberately
    /// prefix-matches everywhere else (`MessageIdentity.headerIdBelongsToFolder`,
    /// `headerIdLikeNoDeeperColonSQLFragment`). Callers carry the `accountId` and the
    /// folder id ALONGSIDE the key instead.
    static func tail(of contentKey: ContentKey, folderId: String) -> String? {
        guard !folderId.isEmpty else { return nil }
        let prefix = folderId + ":"
        guard contentKey.rawValue.hasPrefix(prefix) else { return nil }
        let tail = contentKey.rawValue.dropFirst(prefix.count)
        // Same no-deeper-colon guard as `headerIdBelongsToFolder`: a residual ':'
        // means the key belongs to a NESTED folder, not this one.
        guard !tail.contains(":") else { return nil }
        return String(tail)
    }

    // MARK: - Drift recovery

    /// Resolve an orphaned content key to the key its message is stored under NOW,
    /// if the message merely moved folders. `nil` means "not recoverable" — the
    /// caller must then apply its own liveness probe, never assume "dead".
    ///
    /// Only `.stableProviderId` providers (Gmail, Microsoft Graph) are recoverable
    /// by `(accountId, providerMessageId)`: their message id is globally unique AND
    /// survives a folder move. An IMAP UID changes on move and repeats across
    /// folders, so the same lookup there would bind the content to a DIFFERENT
    /// message — the gate stays.
    ///
    /// Because the gate admits only `.stableProviderId`, the key's tail IS the
    /// provider message id in every case this leg can reach, in both key spaces —
    /// `MessageIdentity.contentKey` only moves the tail under `.uidAddressed`.
    ///
    /// `providerMessageId` is supplied by the caller from data carried BESIDE the
    /// key (the FTS row's `folderId`, or the folder roster) — never from splitting
    /// the key. See `tail(of:folderId:)`.
    static func recoverMovedContentKey(
        orphan: ContentKey, accountId: String, providerMessageId: String, db: Database
    ) throws -> ContentKey? {
        guard !accountId.isEmpty, !providerMessageId.isEmpty else { return nil }
        guard let provider = try Account.fetchOne(db, key: accountId)?.provider,
              provider == .gmail || provider == .outlook else { return nil }
        let matches = try MessageHeader
            .filter(Column("accountId") == accountId && Column("messageId") == providerMessageId)
            .fetchAll(db)
        guard !matches.isEmpty else { return nil }
        // The same message can live in several folders; any current copy works (the
        // body rides along in the re-key). Prefer a non-trash/spam copy.
        let preferred = matches.first {
            !$0.folderPath.contains("TRASH") && !$0.folderPath.contains("SPAM")
        } ?? matches[0]
        let newKey = ContentKey.forHeader(
            accountId: preferred.accountId,
            folderPath: preferred.folderPath,
            providerMessageId: preferred.messageId,
            rfc822MessageId: preferred.rfc822MessageId,
            space: provider.contentKeySpace
        )
        return newKey == orphan ? nil : newKey
    }

    // MARK: - Quarantine

    /// Whether `scope`'s folder is mid-`UIDVALIDITY`-reset.
    ///
    /// ⚑ The guard is the **quarantine FLAG**, not a timing heuristic. While
    /// `Folder.uidValidityResetPendingAt` is armed the folder's rows are being
    /// purged and re-synced, so the relationship between its content keys and its
    /// header ids is mid-flight by definition — the exact window in which a sweep
    /// would read every one of its keys as an orphan. The reference for keying the
    /// decision on this column is `v2final`'s
    /// `DisplayedAttachmentIdentity.settledUidEpoch(_:)`, which refuses a bare-UID
    /// identity under precisely `folder.uidValidityResetPendingAt == nil`.
    ///
    /// A folder with no row is NOT treated as quarantined here: `roster` only
    /// produces scopes for folders that exist, so an absent row means the folder was
    /// deleted between the roster read and this one.
    static func isQuarantined(_ scope: ContentKeyScope, db: Database) throws -> Bool {
        try Folder.fetchOne(db, key: scope.folderId)?.uidValidityResetPendingAt != nil
    }

    // MARK: - The sweep gate

    /// The subset of `contentKeys` that a sweep **must not delete**.
    ///
    /// A key is protected when ANY of these holds:
    ///
    /// - a live header still mints it (`owned`);
    /// - its folder is under a `UIDVALIDITY` quarantine;
    /// - the ownership read threw (`undetermined`).
    ///
    /// A key whose scope does NOT resolve — no folder claims its prefix — is
    /// deliberately NOT protected here, and this is not a hole. The caller ANDs this
    /// gate with its own "is it still a `messageHeader.id`?" probe, which protects
    /// every live header unconditionally, including one whose `Folder` row has gone
    /// missing. Protecting unresolvable keys here instead would make a removed
    /// account's or a deleted folder's assets **permanently** unreclaimable — a
    /// forever-leak, not the "reclaimed on a later pass" kind the fail-safe rule
    /// trades for.
    ///
    /// Callers combine this with whatever liveness probe they already had; the
    /// result is a strict NARROWING of what gets deleted, never a widening. At
    /// Stage C — where a content key IS a `messageHeader.id` — `owned` and "exists
    /// as a header id" coincide exactly, so the only behaviour this changes today is
    /// the quarantine skip.
    ///
    /// Throws only if the folder/account roster itself cannot be read; the caller
    /// must treat a throw as "protect the whole page".
    static func protectedKeys(among contentKeys: [ContentKey], db: Database) throws -> Set<ContentKey> {
        guard !contentKeys.isEmpty else { return [] }
        let scopes = try roster(db)
        var quarantineCache: [String: Bool] = [:]
        var protected = Set<ContentKey>()
        for key in contentKeys {
            guard let scope = resolveScope(for: key, in: scopes) else {
                // Undetermined: no folder claims this key's prefix. The caller's own
                // probe decides — this gate adds no permission to delete.
                continue
            }
            let quarantined: Bool
            if let cached = quarantineCache[scope.folderId] {
                quarantined = cached
            } else {
                quarantined = (try? isQuarantined(scope, db: db)) ?? true
                quarantineCache[scope.folderId] = quarantined
            }
            if quarantined {
                protected.insert(key)
                continue
            }
            switch ownership(of: key, scope: scope, db: db) {
            case .owned, .undetermined:
                protected.insert(key)
            case .unowned:
                break
            }
        }
        return protected
    }

    // MARK: - Release

    /// Which content stores a release touches. Each routed caller passes exactly
    /// what it deleted before this type existed, so Stage C stays behaviourally 1:1.
    struct ContentStores: OptionSet, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        /// The `messageBody` cached-HTML row in the main database.
        static let body = ContentStores(rawValue: 1 << 0)
        /// The FTS `message_ids` / `message_meta` rows and the `messages_vec`
        /// embedding that rides on the same rowid.
        static let searchIndex = ContentStores(rawValue: 1 << 1)
        /// The `bodyAsset` manifest rows and their files on disk.
        static let assets = ContentStores(rawValue: 1 << 2)

        static let all: ContentStores = [.body, .searchIndex, .assets]
    }

    /// Deletes `stores` for `contentKey` **only when nothing owns it**.
    ///
    /// Returns `true` when the content was released. `false` covers both "still
    /// owned" and "could not decide" — the caller must not read a `false` as
    /// permission to delete by another route.
    ///
    /// 🚨 **Call this AFTER the header-delete transaction commits.** See the type's
    /// ordering contract.
    @discardableResult
    static func releaseUnowned(
        _ contentKey: ContentKey,
        scope: ContentKeyScope,
        stores: ContentStores = .all,
        pool: PrioritizedDatabase = AppDatabase.dbPool
    ) async -> Bool {
        let verdict: Ownership
        do {
            verdict = try await pool.read { db in ownership(of: contentKey, scope: scope, db: db) }
        } catch {
            log("releaseUnowned: read failed for \(contentKey) — KEEPING content: \(error)")
            return false
        }
        switch verdict {
        case .owned(let owners):
            log("releaseUnowned: \(contentKey) still owned by \(owners.count) header(s) — keeping")
            return false
        case .undetermined(let reason):
            log("releaseUnowned: \(contentKey) undetermined (\(reason)) — KEEPING content")
            return false
        case .unowned:
            await release(contentKey, stores: stores, pool: pool)
            return true
        }
    }

    /// A content key captured together with the scope needed to answer ownership
    /// for it.
    ///
    /// 🚨 This is the value the ordering contract is about: take it **before or
    /// inside** the header-delete transaction (`capture`), consume it **after that
    /// transaction commits** (`releaseUnowned`). Once the header is gone its
    /// `folderPath`, provider and RFC id are gone with it, so a site that tries to
    /// build the scope afterwards has already lost the information.
    struct CapturedContent: Sendable {
        let contentKey: ContentKey
        let scope: ContentKeyScope
    }

    /// Mint `header`'s content key and its scope, reading the account's key space.
    /// `nil` when the account row is missing — the caller must then keep whatever
    /// unconditional behaviour it had, never invent an owner.
    static func capture(_ header: MessageHeader, db: Database) throws -> CapturedContent? {
        guard let space = try Account.fetchOne(db, key: header.accountId)?.provider.contentKeySpace
        else { return nil }
        return CapturedContent(
            contentKey: ContentKey.forHeader(
                accountId: header.accountId,
                folderPath: header.folderPath,
                providerMessageId: header.messageId,
                rfc822MessageId: header.rfc822MessageId,
                space: space
            ),
            scope: ContentKeyScope.forHeader(header, space: space)
        )
    }

    /// Batch release for sites that hold only content keys, the headers they were
    /// minted from having ALREADY been deleted. Returns how many were released.
    ///
    /// Each key's scope is resolved from the live folder roster. A key no folder
    /// claims keeps the caller's pre-existing unconditional release: no header can
    /// mint a key outside every folder's prefix, so there is no ownership question
    /// to ask, and refusing there would instead strand a search hit that renders
    /// without subject/sender and cannot be opened.
    ///
    /// 🚨 ONE READ, ONE BODY-DELETE TRANSACTION, ONE FTS TRANSACTION — this used to
    /// be N+1 in the worst way. It looped the keys and called the single-key
    /// overload, which does THREE round trips each: a `pool.read` ownership probe, a
    /// `pool.write` body delete, and a one-key `SearchIndex.removeMessages`
    /// transaction. Callers hand it whole pages (`SyncConfig.deletionReconcileChunkSize`
    /// is 500, and `removeHeadersFromFTS` passes a full delta), so that was up to
    /// 1,500 serialized transactions per page on the MAIN pool — and the shipped
    /// implementation did ONE batched FTS transaction, letting `ON DELETE CASCADE`
    /// reclaim the body (`v70` removed that cascade, which is why the body delete is
    /// explicit here now).
    ///
    /// ⚠️ THE OWNERSHIP GUARD IS UNCHANGED AND STAYS PER KEY. Batching decides
    /// nothing collectively: each key still gets its own `ownership` verdict, and
    /// only `.unowned` releases. `.owned` and `.undetermined` KEEP — a batch
    /// containing one still-owned key releases the others and keeps that one. The
    /// mirror-image failure this must never become is a batch-wide verdict in either
    /// direction.
    ///
    /// ⚠️ A FAILED READ NOW KEEPS EVERYTHING, WHICH IS A DELIBERATE CHANGE. The
    /// previous line was `(try? await pool.read { try Self.roster(db) }) ?? []`, and
    /// an empty roster makes every key resolve to "no folder claims it" — i.e. a
    /// thrown read (a suspended or unreadable database) fell through to an
    /// UNCONDITIONAL release of the whole page. That conflates *"nothing owns it"*
    /// with *"we could not ask"*, which is the exact distinction `Ownership` exists
    /// to keep. Keeping is recoverable: the sweeps re-run and reclaim the content on
    /// a later pass.
    @discardableResult
    static func releaseUnowned(
        _ contentKeys: [ContentKey],
        stores: ContentStores,
        pool: PrioritizedDatabase = AppDatabase.dbPool
    ) async -> Int {
        guard !contentKeys.isEmpty else { return 0 }
        let releasable: [ContentKey]
        do {
            releasable = try await pool.read { db -> [ContentKey] in
                let roster = try Self.roster(db)
                return contentKeys.filter { key in
                    guard let scope = resolveScope(for: key, in: roster) else { return true }
                    switch ownership(of: key, scope: scope, db: db) {
                    case .unowned: return true
                    case .owned, .undetermined: return false
                    }
                }
            }
        } catch {
            log("releaseUnowned: batch read failed — KEEPING all \(contentKeys.count) key(s): \(error)")
            return 0
        }
        guard !releasable.isEmpty else { return 0 }
        await release(releasable, stores: stores, pool: pool)
        return releasable.count
    }

    /// The unconditional delete, in ONE place so no caller hand-rolls a second one.
    ///
    /// Only two callers may use it directly: a site whose scope genuinely cannot be
    /// resolved and which therefore must preserve its pre-existing unconditional
    /// behaviour, and the sweeps, which have already made the ownership decision for
    /// a whole page.
    static func release(
        _ contentKey: ContentKey,
        stores: ContentStores,
        pool: PrioritizedDatabase = AppDatabase.dbPool
    ) async {
        await release([contentKey], stores: stores, pool: pool)
    }

    /// The batched form of the unconditional delete. The single-key overload routes
    /// here so the two can never drift: one write transaction for the bodies (chunked
    /// under SQLite's bound-variable limit), one `SearchIndex.removeMessages` — which
    /// is already a single transaction over the whole array — and the per-key asset
    /// sweep, which is file I/O with no transaction to batch.
    ///
    /// Each store is independently `do`/`catch`ed exactly as before: a failure in one
    /// must not skip the others, and none of them is a user intention that could be
    /// dropped — the content is derived and re-fetchable.
    static func release(
        _ contentKeys: [ContentKey],
        stores: ContentStores,
        pool: PrioritizedDatabase = AppDatabase.dbPool
    ) async {
        guard !contentKeys.isEmpty else { return }
        if stores.contains(.body) {
            do {
                try await pool.write(label: "MessageContentStore.releaseBodies") { db in
                    for chunk in contentKeys.chunked(into: SyncConfig.sqlChunkSize) {
                        let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                        try db.execute(
                            sql: "DELETE FROM messageBody WHERE id IN (\(placeholders))",
                            arguments: StatementArguments(chunk))
                    }
                }
            } catch {
                print("[MessageContentStore] body release failed for \(contentKeys.count) key(s): \(error)")
            }
        }
        if stores.contains(.searchIndex) {
            do {
                try await SearchIndex.shared.removeMessages(contentKeys: contentKeys)
            } catch {
                print("[MessageContentStore] search-index release failed for \(contentKeys.count) key(s): \(error)")
            }
        }
        if stores.contains(.assets) {
            for contentKey in contentKeys {
                _ = BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
            }
        }
    }

    // MARK: - Diagnostics

    /// Debug-gated. Ownership decisions are per-key and run inside sweeps over the
    /// whole index, so this must be a no-op in production builds.
    private static func log(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[MessageContentStore] \(message)")
    }
}
