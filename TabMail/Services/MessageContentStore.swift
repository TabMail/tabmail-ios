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
/// Three sweeps decide what content is garbage by asking whether its key is still
/// a `messageHeader.id`:
///
/// - `SyncEngine.pruneFTSOrphans`
/// - `SyncEngine.backfillFolderIdsIfNeeded`
/// - `BodyAssetMaintenance.pruneOrphans`
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
/// ## ⚠ At Stage C the FK cascade still front-runs the body release
///
/// `AppDatabase`'s `messageBody.id` references `messageHeader(id)` `onDelete:
/// .cascade`, so deleting a header already removes its body row before this type
/// is consulted. That is correct **today** (keys are 1:1, so the cascade and
/// `releaseUnowned` always agree and the cascade simply gets there first) and
/// becomes a data-loss bug the day keys diverge: it would delete content still
/// owned by the other N−1 headers. Dropping that FK is **Stage D's** migration —
/// which is exactly why the ordering C → D → E1 cannot be shortcut.
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
    /// 1. An **index-backed SUPERSET** in SQL —
    ///    `folderId = ? AND (rfc822MessageId = ? OR messageId = ?)`. `folderId` is
    ///    the leading column of the `messageHeader_folderId*` composite indexes, and
    ///    the `OR` covers the tail under BOTH key spaces without the planner having
    ///    to reason about which one is live.
    /// 2. **Exact recomputation in Swift** — each candidate's key is re-minted
    ///    through `ContentKey.forHeader` and compared. The superset admits rows that
    ///    do NOT mint this key (e.g. a header whose `rfc822MessageId` equals the
    ///    tail while its content key is still provider-id-tailed), and admitting one
    ///    of those as an owner would leak content forever.
    ///
    /// A single clever SQL predicate was deliberately NOT written: it would either
    /// stop being index-backed or would encode the mint's rules a second time, where
    /// they could drift from `ContentKey.forHeader`.
    static func owners(of contentKey: ContentKey, scope: ContentKeyScope, db: Database) throws -> [String] {
        guard let tail = scope.tail(of: contentKey) else { return [] }
        let candidates = try Row.fetchAll(
            db,
            sql: """
                SELECT id, accountId, folderPath, messageId, rfc822MessageId
                FROM messageHeader
                WHERE folderId = ? AND (rfc822MessageId = ? OR messageId = ?)
                """,
            arguments: [scope.folderId, tail, tail]
        )
        return candidates.compactMap { row -> String? in
            let minted = ContentKey.forHeader(
                accountId: row["accountId"] as String,
                folderPath: row["folderPath"] as String,
                providerMessageId: row["messageId"] as String,
                rfc822MessageId: row["rfc822MessageId"] as String?,
                space: scope.space
            )
            return minted == contentKey ? (row["id"] as String) : nil
        }
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
    @discardableResult
    static func releaseUnowned(
        _ contentKeys: [ContentKey],
        stores: ContentStores,
        pool: PrioritizedDatabase = AppDatabase.dbPool
    ) async -> Int {
        guard !contentKeys.isEmpty else { return 0 }
        let roster = (try? await pool.read { db in try Self.roster(db) }) ?? []
        var released = 0
        for key in contentKeys {
            guard let scope = resolveScope(for: key, in: roster) else {
                await release(key, stores: stores, pool: pool)
                released += 1
                continue
            }
            if await releaseUnowned(key, scope: scope, stores: stores, pool: pool) {
                released += 1
            }
        }
        return released
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
        if stores.contains(.body) {
            do {
                try await pool.write { db in
                    try db.execute(
                        sql: "DELETE FROM messageBody WHERE id = ?", arguments: [contentKey])
                }
            } catch {
                print("[MessageContentStore] body release failed for \(contentKey): \(error)")
            }
        }
        if stores.contains(.searchIndex) {
            do {
                try await SearchIndex.shared.removeMessages(contentKeys: [contentKey])
            } catch {
                print("[MessageContentStore] search-index release failed for \(contentKey): \(error)")
            }
        }
        if stores.contains(.assets) {
            _ = BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
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
