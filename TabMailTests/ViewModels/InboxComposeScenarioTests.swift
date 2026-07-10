/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// MARK: - Deterministic PRNG (SplitMix64)

/// Deterministic PRNG for the seeded fuzz mode — NEVER
/// `SystemRandomNumberGenerator` or `Date()`-derived entropy in test logic
/// (repo testing rule: fixed seeds only, reproducible failures).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform-ish pick in `0..<bound` (modulo bias is irrelevant for test
    /// sequence generation; determinism is what matters).
    mutating func pick(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }
}

// MARK: - Pure identity mirror (shared with InboxListReaderIntegrationTests)

/// A durable header row as the identity mirror sees it — the minimal value
/// shape of a `messageHeader` row that `DurableIdentityLookup.find`'s SQL
/// consults. Internal (not private) so the §5A.3 contract-parity test in
/// `InboxListReaderIntegrationTests` can diff this mirror against the real
/// SQL helper over a shared fixture set.
struct SimDurableRow: Equatable, Sendable {
    let id: String
    let accountId: String
    let messageId: String
    let rfc822MessageId: String?
    let folderId: String
    let folderPath: String
    let isInInbox: Bool
}

/// PURE reimplementation of `DurableIdentityLookup.find`'s three-step lookup
/// order (G3 audit) — (1) exact-folder `(accountId, folderPath, messageId)`,
/// then (2) folder-blind `(accountId, messageId)` REJECTED when both sides
/// carry a non-nil, non-empty, DISAGREEING `rfc822MessageId` (a provable
/// cross-folder UID collision — IMAP UIDs are per-folder, ADR-IOS-042), then
/// (3) `(accountId, rfc822MessageId)` fallback ONLY when non-nil/non-empty.
/// The §5A.3 parity test asserts this mirror agrees with the SQL helper; the
/// scenario World uses it to derive `stagedResolutions` the same way the
/// shell would.
enum SimIdentityMirror {
    static func find(
        rows: [SimDurableRow], accountId: String, folderPath: String, messageId: String, rfc822MessageId: String?
    ) -> DurableIdentityLookup.DurableHeaderRef? {
        // Step 1: exact-folder match.
        if let hit = rows.first(where: {
            $0.accountId == accountId && $0.folderPath == folderPath && $0.messageId == messageId
        }) {
            return DurableIdentityLookup.DurableHeaderRef(
                id: hit.id, folderId: hit.folderId, folderPath: hit.folderPath,
                isInInbox: hit.isInInbox, rfc822MessageId: hit.rfc822MessageId
            )
        }
        // Step 2: folder-blind match, with rfc822-mismatch rejection.
        if let hit = rows.first(where: { $0.accountId == accountId && $0.messageId == messageId }) {
            let provablyDifferent: Bool = {
                guard let candidateRfc822 = hit.rfc822MessageId, !candidateRfc822.isEmpty,
                      let rfc822MessageId, !rfc822MessageId.isEmpty else { return false }
                return candidateRfc822 != rfc822MessageId
            }()
            if !provablyDifferent {
                return DurableIdentityLookup.DurableHeaderRef(
                    id: hit.id, folderId: hit.folderId, folderPath: hit.folderPath,
                    isInInbox: hit.isInInbox, rfc822MessageId: hit.rfc822MessageId
                )
            }
        }
        // Step 3: rfc822 fallback.
        if let rfc = rfc822MessageId, !rfc.isEmpty,
           let hit = rows.first(where: { $0.accountId == accountId && $0.rfc822MessageId == rfc }) {
            return DurableIdentityLookup.DurableHeaderRef(
                id: hit.id, folderId: hit.folderId, folderPath: hit.folderPath,
                isInInbox: hit.isInInbox, rfc822MessageId: hit.rfc822MessageId
            )
        }
        return nil
    }
}

// MARK: - Simulation world (PLAN_INBOX_UNIFIED_READ.md §5A.1)

/// Immutable spec of one simulated message — identity, date, and the AI
/// fields its push/phase-2 carries.
struct SimMessageSpec {
    let key: String
    let accountId: String
    /// The UID the PUSH captured. Staging steps ALWAYS use this (a stale
    /// re-stage carries push-time truth); only `uidRemap` gives the durable
    /// row a different messageId.
    let pushMessageId: String
    let rfc822: String
    let date: Date
    let actionTag: String?
    let summaryBlurb: String?
    let isReadAtPush: Bool
}

/// One durable `messageHeader` row in the sim (stands in for GRDB).
struct SimHeader {
    var id: String
    var accountId: String
    var messageId: String
    var rfc822MessageId: String?
    var folderId: String
    var folderPath: String
    var isInInbox: Bool
    var isRead: Bool
    var headerComplete: Bool
    var actionTag: String?
    var summaryBlurb: String?
    var date: Date
    /// Real user labels attached to this durable row. Default `[]` — zero
    /// churn to every existing scenario, which never cares about labels.
    /// Threaded into `toSnapshot()` so BOTH the D step and the P step (which
    /// reuses this same method — `SimWorld.inputs(query:)`) carry real
    /// labels through, matching `InboxListReader.gather`'s batch
    /// `UserLabelStore.loadLabels` call covering D AND P rows alike.
    var userLabels: [UserLabel] = []

    var tagSortOrder: Int {
        actionTag.flatMap(ActionTag.init(rawValue:))?.sortOrder ?? 99
    }

    /// GRDB-shaped snapshot, exactly how the shell's D/P steps would
    /// materialize this row. `h.id` is overridden AFTER init because sim
    /// moves are UPDATEs-in-place (folderPath changes, primary key doesn't)
    /// while `MessageHeader.init` recomputes id from folderPath.
    func toSnapshot() -> MessageSnapshot {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender",
            fromAddress: "s@example.com", to: "me@example.com", date: date, snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: isInInbox
        )
        h.id = id
        h.rfc822MessageId = rfc822MessageId
        h.isRead = isRead
        h.actionTag = actionTag.flatMap(ActionTag.init(rawValue:))
        h.tagSortOrder = h.actionTag?.sortOrder ?? 99
        h.summaryBlurb = summaryBlurb
        h.headerComplete = headerComplete
        return MessageSnapshot(from: h, userLabels: userLabels)
    }

    var asSimDurableRow: SimDurableRow {
        SimDurableRow(
            id: id, accountId: accountId, messageId: messageId, rfc822MessageId: rfc822MessageId,
            folderId: folderId, folderPath: folderPath, isInInbox: isInInbox
        )
    }
}

/// Value-type state machine standing in for the whole pipeline
/// (NSE staging → merge phases → sync → user actions → overlay drain).
/// Each `Step` mirrors EXACTLY one real-world event (§5A.1); `inputs(query:)`
/// derives `ComposeInputs` the same way `InboxListReader.gather` would, so
/// `compose` can be driven through every lifecycle interleaving without a
/// database.
struct SimWorld {

    // MARK: Steps (§5A.1 — all 16)

    enum Step: String, CaseIterable {
        case stagePush              // NSE stages + merge publishes S (pre-write)
        case silentStateChangePush  // §0A: state-change push re-stages an ACTED-ON message
        case pushRedelivery         // §0A: at-least-once duplicate of any prior push
        case phase1Commit           // durable header appears, AI-less, headerComplete=FALSE
        case ftsFlushCommit         // headerComplete flips true → row visible to D (§2.1a)
        case phase2Commit           // body + AI fields land durably
        case drainStaging           // staging row deleted → S shrinks
        case userMove               // overlay folderId registered (archive)
        case userRead               // non-removing overlay mutation
        case optimisticWrite        // the action's durable GRDB write lands
        case overlayDrain           // pending op completes → overlay entry removed
        case undo                   // overlay folderId back-to-displayed (restore write deferred)
        case undoRestoreWrite       // the deferred DB restore commits
        case staleDelete            // sync transiently deletes the durable row
        case uidRemap               // IMAP MOVE re-keys durable identity (rfc822 link only)
        case reStage                // NSE re-stages an old message (boot_logs 3 driver)
    }

    struct MessageState {
        var everStaged = false
        var phase2Done = false
        var movedAwayByUser = false
        var undoActive = false
        /// Whether the CURRENT overlay entry's durable write has landed
        /// (gates `overlayDrain` — the real overlay only drains after its
        /// PendingOperation's DB write commits).
        var writeApplied = false
    }

    // MARK: Fixed topology

    let accountId = "acc1"
    let inboxPath = "INBOX"
    let archivePath = "Archive"
    var inboxFolderId: String { MessageIdentity.folderId(accountId: accountId, folderPath: inboxPath) }
    var archiveFolderId: String { MessageIdentity.folderId(accountId: accountId, folderPath: archivePath) }
    var displayedFolderIds: Set<String> { [inboxFolderId] }

    // MARK: State

    private(set) var specs: [String: SimMessageSpec] = [:]
    private(set) var states: [String: MessageState] = [:]
    private(set) var durableRows: [SimHeader] = []
    private(set) var stagedSnapshot: [StagedInboxRow] = []
    private(set) var overlay: [String: AccountManager.PendingMutation] = [:]

    /// Sorted for deterministic fuzz enumeration.
    var messageKeys: [String] { specs.keys.sorted() }

    /// Fixed base date, far from any staleness horizon; offsets are
    /// deterministic. Allowed under the no-hardcoded-dates rule's exception:
    /// nothing time-of-day- or now-relative is under test here — the composer
    /// only compares dates to EACH OTHER, so a frozen epoch keeps the fuzz
    /// reproducible byte-for-byte across runs and years.
    static let baseDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    static func spec(
        _ key: String,
        uid: String,
        minutesAgo: Int,
        tag: String? = nil,
        blurb: String? = nil,
        readAtPush: Bool = false
    ) -> SimMessageSpec {
        SimMessageSpec(
            key: key, accountId: "acc1", pushMessageId: uid,
            rfc822: "rfc-\(key)@example.com",
            date: baseDate.addingTimeInterval(-60 * Double(minutesAgo)),
            actionTag: tag, summaryBlurb: blurb, isReadAtPush: readAtPush
        )
    }

    static func standard(messages: [SimMessageSpec]) -> SimWorld {
        var world = SimWorld()
        for spec in messages {
            world.specs[spec.key] = spec
            world.states[spec.key] = MessageState()
        }
        return world
    }

    static var defaultQuery: InboxListQuery {
        InboxListQuery(
            displayedFolderIds: [MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX")],
            filterUnread: false, filterLabelIds: [], mode: .normal,
            targetCount: 50, beforeDate: nil
        )
    }

    // MARK: Lookups

    func durableRow(forKey key: String) -> SimHeader? {
        guard let spec = specs[key] else { return nil }
        return durableRows.first { $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822 }
    }

    func stagedRows(forKey key: String) -> [StagedInboxRow] {
        guard let spec = specs[key] else { return [] }
        return stagedSnapshot.filter { $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822 }
    }

    /// The id the user's action targets: the durable header's id when one
    /// exists (that's the on-screen row's id post-merge), else the staged
    /// headerId (pre-durability rows render under it).
    func currentId(forKey key: String) -> String {
        if let d = durableRow(forKey: key) { return d.id }
        let spec = specs[key]!
        return MessageIdentity.headerId(
            accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId
        )
    }

    /// All ids an overlay entry for this identity could be keyed under
    /// (durable id + staged headerId — they diverge after a uidRemap).
    func candidateOverlayIds(forKey key: String) -> [String] {
        guard let spec = specs[key] else { return [] }
        var ids = [MessageIdentity.headerId(
            accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId
        )]
        if let d = durableRow(forKey: key), !ids.contains(d.id) { ids.append(d.id) }
        return ids
    }

    func identity(of key: String) -> String {
        let spec = specs[key]!
        return "\(spec.accountId)|rfc|\(spec.rfc822)"
    }

    // MARK: Legality (only steps that make sense in the current lifecycle)

    func isLegal(_ step: Step, _ key: String) -> Bool {
        guard specs[key] != nil, let state = states[key] else { return false }
        let durable = durableRow(forKey: key)
        let stagedPresent = !stagedRows(forKey: key).isEmpty
        let overlayEntry = overlay[currentId(forKey: key)]
        let anyOverlay = candidateOverlayIds(forKey: key).contains { overlay[$0] != nil }
        switch step {
        case .stagePush:
            return !state.everStaged
        case .silentStateChangePush, .pushRedelivery, .reStage:
            return state.everStaged
        case .phase1Commit:
            return stagedPresent && durable == nil
        case .ftsFlushCommit:
            return durable != nil && durable?.headerComplete == false
        case .phase2Commit:
            return durable != nil && durable?.headerComplete == true && !state.phase2Done
        case .drainStaging:
            return stagedPresent && state.phase2Done
        case .userMove:
            // Only rows the user can see: staged in a displayed folder, or a
            // durable row currently in the displayed set.
            let durableVisible = durable.map {
                displayedFolderIds.contains($0.folderId) && $0.isInInbox
            } ?? false
            return !state.movedAwayByUser && (stagedPresent || durableVisible)
        case .userRead:
            return !state.movedAwayByUser && (stagedPresent || durable != nil)
        case .optimisticWrite:
            return overlayEntry != nil && durable != nil && !state.writeApplied
        case .overlayDrain:
            return overlayEntry != nil && state.writeApplied
        case .undo:
            return state.movedAwayByUser
        case .undoRestoreWrite:
            return state.undoActive && durable != nil && !state.writeApplied
        case .staleDelete:
            // The DB-layer 120s stale-delete protection + recentlyCompleted
            // TTL shield rows with in-flight user actions — model that by
            // only allowing stale deletes on action-free rows.
            return durable != nil && !anyOverlay && !state.movedAwayByUser && !state.undoActive
        case .uidRemap:
            // The plan notes post-remap undo-id staleness is out of scope
            // (§6, "Undo-id staleness"), so a remap never races an overlay.
            return durable != nil && !anyOverlay && !state.undoActive
        }
    }

    // MARK: Step application

    mutating func apply(_ step: Step, _ key: String) {
        guard let spec = specs[key], var state = states[key] else { return }
        switch step {
        case .stagePush, .silentStateChangePush, .pushRedelivery, .reStage:
            stage(spec)
            state.everStaged = true
        case .phase1Commit:
            durableRows.append(SimHeader(
                id: MessageIdentity.headerId(
                    accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId
                ),
                accountId: spec.accountId, messageId: spec.pushMessageId,
                rfc822MessageId: spec.rfc822,
                folderId: inboxFolderId, folderPath: inboxPath,
                isInInbox: true, isRead: spec.isReadAtPush,
                headerComplete: false,
                actionTag: nil, summaryBlurb: nil,  // phase-1 is AI-less (§2.1a)
                date: spec.date
            ))
        case .ftsFlushCommit:
            mutateDurable(forKey: key) { $0.headerComplete = true }
        case .phase2Commit:
            mutateDurable(forKey: key) {
                $0.actionTag = spec.actionTag
                $0.summaryBlurb = spec.summaryBlurb
            }
            state.phase2Done = true
        case .drainStaging:
            stagedSnapshot.removeAll { $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822 }
        case .userMove:
            registerMutation(id: currentId(forKey: key), AccountManager.PendingMutation(
                folderId: archiveFolderId, folderPath: archivePath, isInInbox: false
            ))
            state.movedAwayByUser = true
            state.undoActive = false
            state.writeApplied = false
        case .userRead:
            registerMutation(id: currentId(forKey: key), AccountManager.PendingMutation(isRead: true))
        case .optimisticWrite:
            let mutation = overlay[currentId(forKey: key)]
            mutateDurable(forKey: key) { row in
                if let v = mutation?.folderId { row.folderId = v }
                if let v = mutation?.folderPath { row.folderPath = v }
                if let v = mutation?.isInInbox { row.isInInbox = v }
                if let v = mutation?.isRead { row.isRead = v }
            }
            state.writeApplied = true
        case .overlayDrain:
            overlay.removeValue(forKey: currentId(forKey: key))
            state.writeApplied = false
        case .undo:
            // Mirrors UndoService.undo()'s .move case: fresh overlay entry
            // pointing back into the displayed set, DB restore deferred.
            registerMutation(id: currentId(forKey: key), AccountManager.PendingMutation(
                folderId: inboxFolderId, folderPath: inboxPath, isInInbox: true
            ))
            state.movedAwayByUser = false
            state.undoActive = true
            state.writeApplied = false
        case .undoRestoreWrite:
            let restoreFolderId = inboxFolderId
            let restoreFolderPath = inboxPath
            mutateDurable(forKey: key) { row in
                row.folderId = restoreFolderId
                row.folderPath = restoreFolderPath
                row.isInInbox = true
            }
            state.writeApplied = true
        case .staleDelete:
            durableRows.removeAll { $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822 }
            state.phase2Done = false
            state.writeApplied = false
        case .uidRemap:
            // Server-side IMAP MOVE to Archive: new UID, new headerId, new
            // folder — only the rfc822 link ties it back to the staged copy
            // (the 485a4d1 shape).
            let newUid = "9\(spec.pushMessageId)"
            let remapFolderId = archiveFolderId
            let remapFolderPath = archivePath
            mutateDurable(forKey: key) { row in
                row.messageId = newUid
                row.folderId = remapFolderId
                row.folderPath = remapFolderPath
                row.isInInbox = false
                row.id = MessageIdentity.headerId(
                    accountId: spec.accountId, folderPath: remapFolderPath, messageId: newUid
                )
            }
        }
        states[key] = state
    }

    private mutating func stage(_ spec: SimMessageSpec) {
        let row = StagedInboxRow(
            accountId: spec.accountId, folderPath: inboxPath, messageId: spec.pushMessageId,
            rfc822MessageId: spec.rfc822, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(spec.key)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: spec.date,
            isRead: spec.isReadAtPush, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false,
            actionTag: spec.actionTag, summaryBlurb: spec.summaryBlurb
        )
        // Replace-all semantics per headerId (mirrors the merge's snapshot
        // publish — one entry per staged row; redelivery replaces).
        stagedSnapshot.removeAll { $0.headerId == row.headerId }
        stagedSnapshot.append(row)
    }

    private mutating func mutateDurable(forKey key: String, _ body: (inout SimHeader) -> Void) {
        guard let spec = specs[key],
              let idx = durableRows.firstIndex(where: {
                  $0.accountId == spec.accountId && $0.rfc822MessageId == spec.rfc822
              }) else { return }
        body(&durableRows[idx])
    }

    /// Mirrors `AccountManager.registerMutation`'s field-merge behavior.
    private mutating func registerMutation(id: String, _ mutation: AccountManager.PendingMutation) {
        var existing = overlay[id] ?? AccountManager.PendingMutation()
        if let v = mutation.isRead { existing.isRead = v }
        if let v = mutation.folderId { existing.folderId = v }
        if let v = mutation.folderPath { existing.folderPath = v }
        if let v = mutation.isInInbox { existing.isInInbox = v }
        if let v = mutation.isFlagged { existing.isFlagged = v }
        if let v = mutation.actionTag { existing.actionTag = v }
        overlay[id] = existing
    }

    // MARK: Input derivation (mirrors InboxListReader.gather, §2.1/§2.1b)

    func inputs(query: InboxListQuery) -> ComposeInputs {
        // D — per-folder, headerComplete-only, SQL-shaped filters, sorted,
        // limited. Exactly the shell's D step over the sim's "table".
        var durableSnaps: [MessageSnapshot] = []
        for folderId in query.displayedFolderIds.sorted() {
            var rows = durableRows.filter { $0.folderId == folderId && $0.headerComplete }
            if query.filterUnread { rows = rows.filter { !$0.isRead } }
            if let cutoff = query.beforeDate { rows = rows.filter { $0.date < cutoff } }
            switch query.mode {
            case .triage:
                rows.sort { a, b in
                    if a.tagSortOrder != b.tagSortOrder { return a.tagSortOrder < b.tagSortOrder }
                    return a.date > b.date
                }
            case .normal:
                rows.sort { $0.date > $1.date }
            }
            durableSnaps.append(contentsOf: rows.prefix(query.targetCount).map { $0.toSnapshot() })
        }

        // P — overlay entries whose folderId points INTO the displayed set,
        // id not already in D, durable row fetched by id with overlay folder
        // fields applied (insertUndoneMessages' logic; the shell's P step).
        let dIds = Set(durableSnaps.map(\.id))
        var pinned: [MessageSnapshot] = []
        for (id, mutation) in overlay {
            guard let newFolderId = mutation.folderId,
                  query.displayedFolderIds.contains(newFolderId),
                  !dIds.contains(id),
                  var row = durableRows.first(where: { $0.id == id }) else { continue }
            row.folderId = newFolderId
            if let v = mutation.folderPath { row.folderPath = v }
            if let v = mutation.isInInbox { row.isInInbox = v }
            if let v = mutation.isRead { row.isRead = v }
            if query.filterUnread && row.isRead { continue }
            pinned.append(row.toSnapshot())
        }

        // Resolutions — the pure identity mirror over the sim's "table".
        let simRows = durableRows.map(\.asSimDurableRow)
        var resolutions: [String: StagedIdentityResolution] = [:]
        for row in stagedSnapshot {
            let ref = SimIdentityMirror.find(
                rows: simRows, accountId: row.accountId, folderPath: row.folderPath,
                messageId: row.messageId, rfc822MessageId: row.rfc822MessageId
            )
            resolutions[row.headerId] = StagedIdentityResolution(stagedHeaderId: row.headerId, durable: ref)
        }

        return ComposeInputs(
            durable: durableSnaps, pinned: pinned, staged: stagedSnapshot,
            stagedResolutions: resolutions, overlay: overlay, query: query
        )
    }
}

// MARK: - AI monotonicity tracker (I3)

struct AITracker {
    var tagSeen: Set<String> = []
    var blurbSeen: Set<String> = []
}

// MARK: - Suite

/// PLAN_INBOX_UNIFIED_READ.md §5A — the scenario harness that would have
/// caught every 2026-07-09 inbox bug. Pure tests: NO database, NO mocks —
/// `InboxListComposer.compose` is driven over value `World` states through
/// lifecycle transitions, with invariants I1–I7 (§5A.2) asserted after EVERY
/// step of every scenario, plus commutable-pair permutations and a seeded
/// SplitMix64 fuzz over random legal step sequences.
@Suite("InboxListComposer scenarios (PLAN_INBOX_UNIFIED_READ §5A)")
struct InboxComposeScenarioTests {

    // MARK: Invariants (§5A.2 — each one IS a 2026-07 bug class)

    private func identityKey(accountId: String, messageId: String, rfc822: String?) -> String {
        if let rfc = rfc822, !rfc.isEmpty { return "\(accountId)|rfc|\(rfc)" }
        return "\(accountId)|mid|\(messageId)"
    }

    /// Runs all seven invariants against one composed list. `context` must
    /// carry scenario name/seed + step index/name; the composed ids are
    /// appended here — debuggability is part of the deliverable.
    private func assertInvariants(
        _ world: SimWorld,
        composed: [MessageSnapshot],
        query: InboxListQuery,
        ai: inout AITracker,
        context: String
    ) {
        let composedIdentityList = composed.map {
            identityKey(accountId: $0.accountId, messageId: $0.messageId, rfc822: $0.rfc822MessageId)
        }
        let composedIdentities = Set(composedIdentityList)
        let detail = "\(context) composedIds=[\(composed.map(\.id).joined(separator: ", "))]"

        // Presence invariants only make sense on an unfiltered full-range
        // window with room: an active filter, a pagination cutoff, or a full
        // window legitimately excludes rows (window trim can displace the
        // oldest row — §4.3).
        let presenceApplies = query.filterLabelIds.isEmpty && !query.filterUnread
            && query.beforeDate == nil && composed.count < query.targetCount

        for key in world.messageKeys {
            guard let state = world.states[key] else { continue }
            let identity = world.identity(of: key)
            let durable = world.durableRow(forKey: key)
            let staged = world.stagedRows(forKey: key).first
            let overlayIntoDisplayed = world.candidateOverlayIds(forKey: key).contains { id in
                guard let f = world.overlay[id]?.folderId else { return false }
                return query.displayedFolderIds.contains(f)
            }
            let overlayOutOfDisplayed = world.candidateOverlayIds(forKey: key).contains { id in
                guard let f = world.overlay[id]?.folderId else { return false }
                return !query.displayedFolderIds.contains(f)
            }

            // I1 no-resurrection: identity durably present with folder ∉
            // displayed (or isInInbox=false) ⟹ NOT composed — unless an
            // overlay entry moves it back INTO the displayed set (undo).
            if let d = durable,
               !query.displayedFolderIds.contains(d.folderId) || !d.isInInbox,
               !overlayIntoDisplayed {
                #expect(
                    !composedIdentities.contains(identity),
                    "I1 no-resurrection VIOLATED for \(key): durable copy is in \(d.folderPath) (isInInbox=\(d.isInInbox)) yet the identity composed — \(detail)"
                )
            }

            // I6 move-hides: from userMove(out) onward, identity in NO list
            // (undo clears movedAwayByUser, so it stops applying there).
            if state.movedAwayByUser {
                #expect(
                    !composedIdentities.contains(identity),
                    "I6 move-hides VIOLATED for \(key): user moved it out but it composed — \(detail)"
                )
            }

            if presenceApplies {
                // I2 no-vanish (staged limb): a staged row for a displayed
                // folder, not user-moved-away, whose durable copy hasn't
                // moved elsewhere, is in EVERY composed list.
                if let s = staged,
                   query.displayedFolderIds.contains(s.folderId),
                   !state.movedAwayByUser,
                   !overlayOutOfDisplayed {
                    let staleByMove = durable.map { $0.folderId != s.folderId || !$0.isInInbox } ?? false
                    if !staleByMove {
                        #expect(
                            composedIdentities.contains(identity),
                            "I2 no-vanish VIOLATED for \(key): staged row present (durable=\(durable?.folderPath ?? "none"), headerComplete=\(durable?.headerComplete ?? false)) but identity missing — \(detail)"
                        )
                    }
                }
                // I2 (durable-visible limb): a query-visible durable row in
                // the displayed set with no overlay moving it out must show.
                if let d = durable, d.headerComplete, d.isInInbox,
                   query.displayedFolderIds.contains(d.folderId),
                   !state.movedAwayByUser, !overlayOutOfDisplayed {
                    #expect(
                        composedIdentities.contains(identity),
                        "I2 durable-visible VIOLATED for \(key): headerComplete durable row in displayed folder missing from composed list — \(detail)"
                    )
                }
                // I4 undo-visible: from undo(msg) onward — before AND after
                // undoRestoreWrite, across overlayDrain — always composed.
                if state.undoActive {
                    #expect(
                        composedIdentities.contains(identity),
                        "I4 undo-visible VIOLATED for \(key): undone message missing from composed list — \(detail)"
                    )
                }
            }
        }

        // I5 no-duplicates: unique ids AND unique identities.
        #expect(
            Set(composed.map(\.id)).count == composed.count,
            "I5 no-duplicates VIOLATED: duplicate ids — \(detail)"
        )
        #expect(
            composedIdentities.count == composedIdentityList.count,
            "I5 no-duplicates VIOLATED: duplicate identities (headerId skew / UID remap phantom) — \(detail)"
        )

        // I3 AI-monotonic: once a composed row shows non-nil AI fields, no
        // later compose shows nil for that identity (no clear steps in sim).
        //
        // Undo carve-out (designed parity behavior, NOT a bug): an undone row
        // whose durable copy never got its phase-2 AI write renders via the
        // P-step from the AI-less durable header — exactly what
        // `insertUndoneMessages` does today, and the §2.1a carry-over only
        // applies to same-folder D∪P rows (an undo target is stale-by-move
        // until the restore write lands, so its S copy is suppressed without
        // carry-over). The AI repaint/phase-2 restores the fields later.
        let identityToKey: [String: String] = Dictionary(
            uniqueKeysWithValues: world.messageKeys.map { (world.identity(of: $0), $0) }
        )
        for row in composed {
            let identity = identityKey(accountId: row.accountId, messageId: row.messageId, rfc822: row.rfc822MessageId)
            let key = identityToKey[identity]
            let undoActive = key.flatMap { world.states[$0]?.undoActive } ?? false
            let durableRow = key.flatMap { world.durableRow(forKey: $0) }
            if ai.tagSeen.contains(identity), !(undoActive && durableRow?.actionTag == nil) {
                #expect(
                    row.actionTag != nil,
                    "I3 AI-monotonic VIOLATED: actionTag flashed to nil for \(identity) — \(detail)"
                )
            }
            if row.actionTag != nil { ai.tagSeen.insert(identity) }
            if ai.blurbSeen.contains(identity), !(undoActive && durableRow?.summaryBlurb == nil) {
                #expect(
                    row.summaryBlurb != nil,
                    "I3 AI-monotonic VIOLATED: summaryBlurb flashed to nil for \(identity) — \(detail)"
                )
            }
            if row.summaryBlurb != nil { ai.blurbSeen.insert(identity) }
        }

        // I7 window-sanity: sorted per mode, length ≤ window, label filter
        // respected (unread filter is scenario-asserted — D's SQL-vs-overlay
        // parity makes a generic post-overlay isRead check wrong by design).
        #expect(
            composed.count <= query.targetCount,
            "I7 window-sanity VIOLATED: \(composed.count) rows > window \(query.targetCount) — \(detail)"
        )
        if composed.count >= 2 {
            for i in 0..<(composed.count - 1) {
                let a = composed[i], b = composed[i + 1]
                let ordered: Bool
                switch query.mode {
                case .triage:
                    ordered = a.tagSortOrder < b.tagSortOrder
                        || (a.tagSortOrder == b.tagSortOrder && a.date >= b.date)
                case .normal:
                    ordered = a.date >= b.date
                }
                #expect(
                    ordered,
                    "I7 window-sanity VIOLATED: rows \(i)/\(i + 1) out of \(query.mode) order — \(detail)"
                )
            }
        }
        if !query.filterLabelIds.isEmpty {
            for row in composed {
                #expect(
                    query.filterLabelIds.isSubset(of: Set(row.userLabels.map(\.id))),
                    "I7 window-sanity VIOLATED: row \(row.id) lacks required labels — \(detail)"
                )
            }
        }
    }

    // MARK: Scenario runner

    /// Applies each step (asserting legality — a scenario typo shows up as a
    /// legality failure, not a confusing invariant one), composes after
    /// EVERY step, and runs all invariants each time.
    @discardableResult
    private func runSteps(
        _ steps: [(SimWorld.Step, String)],
        world: inout SimWorld,
        query: InboxListQuery = SimWorld.defaultQuery,
        ai: inout AITracker,
        scenario: String
    ) -> [MessageSnapshot] {
        var lastComposed: [MessageSnapshot] = []
        for (i, pair) in steps.enumerated() {
            let (step, key) = pair
            #expect(
                world.isLegal(step, key),
                "scenario=\(scenario): step[\(i)]=\(step.rawValue)(\(key)) is not legal in the current lifecycle state"
            )
            world.apply(step, key)
            lastComposed = InboxListComposer.compose(world.inputs(query: query))
            assertInvariants(
                world, composed: lastComposed, query: query, ai: &ai,
                context: "scenario=\(scenario) step[\(i)]=\(step.rawValue)(\(key))"
            )
        }
        return lastComposed
    }

    /// Composes N times with no step in between (a "reload storm") and
    /// invariant-checks every one.
    @discardableResult
    private func composeRepeatedly(
        _ times: Int,
        world: SimWorld,
        query: InboxListQuery = SimWorld.defaultQuery,
        ai: inout AITracker,
        scenario: String,
        note: String
    ) -> [MessageSnapshot] {
        var lastComposed: [MessageSnapshot] = []
        for n in 0..<times {
            lastComposed = InboxListComposer.compose(world.inputs(query: query))
            assertInvariants(
                world, composed: lastComposed, query: query, ai: &ai,
                context: "scenario=\(scenario) compose#\(n) (\(note))"
            )
        }
        return lastComposed
    }

    private func contains(_ composed: [MessageSnapshot], _ world: SimWorld, _ key: String) -> Bool {
        let identity = world.identity(of: key)
        return composed.contains {
            identityKey(accountId: $0.accountId, messageId: $0.messageId, rfc822: $0.rfc822MessageId) == identity
        }
    }

    // MARK: - Named scenarios (the exact histories from the boot logs)

    @Test("archivedThenRestagedNeverReappears — boot_logs 3: a silent state-change push re-stages an archived message; it must never resurrect (I1/I6)")
    func archivedThenRestagedNeverReappears() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("m1", uid: "101", minutesAgo: 5, tag: "reply", blurb: "b1")
        ])
        var ai = AITracker()
        runSteps([
            (.stagePush, "m1"),
            (.phase1Commit, "m1"),
            (.ftsFlushCommit, "m1"),
            (.phase2Commit, "m1"),
            (.drainStaging, "m1"),
            (.userMove, "m1"),
            (.optimisticWrite, "m1"),
            (.overlayDrain, "m1"),
            (.silentStateChangePush, "m1"),  // §0A: re-stages with push-time folder truth (INBOX)
        ], world: &world, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        // compose×N — the resurrection was flaky in prod; hammer it.
        let composed = composeRepeatedly(
            10, world: world, ai: &ai,
            scenario: "archivedThenRestagedNeverReappears", note: "post re-stage storm"
        )
        #expect(!contains(composed, world, "m1"), "archived message resurrected via re-staged row")
        // And a literal reStage + redelivery for good measure.
        runSteps([
            (.reStage, "m1"),
            (.pushRedelivery, "m1"),
        ], world: &world, ai: &ai, scenario: "archivedThenRestagedNeverReappears")
        let final = InboxListComposer.compose(world.inputs(query: SimWorld.defaultQuery))
        #expect(!contains(final, world, "m1"), "archived message resurrected after reStage/pushRedelivery")
    }

    @Test("stagedSurvivesReloadStorm — a staged row with no durable write survives arbitrarily many composes (I2, boot_logs 2 guard-release class)")
    func stagedSurvivesReloadStorm() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        runSteps([(.stagePush, "m1")], world: &world, ai: &ai, scenario: "stagedSurvivesReloadStorm")
        let composed = composeRepeatedly(
            25, world: world, ai: &ai, scenario: "stagedSurvivesReloadStorm", note: "no phase1 — pre-durability"
        )
        #expect(contains(composed, world, "m1"), "staged row vanished during a reload storm")
    }

    @Test("readOverlayDoesNotEvictStaged — an isRead-only overlay mutation never evicts a staged row (race 1, f843c02 class)")
    func readOverlayDoesNotEvictStaged() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        let composed = runSteps([
            (.stagePush, "m1"),
            (.userRead, "m1"),
        ], world: &world, ai: &ai, scenario: "readOverlayDoesNotEvictStaged")
        #expect(contains(composed, world, "m1"), "staged row evicted by a non-removing (isRead) overlay mutation")
        #expect(composed.first?.isRead == true, "overlay isRead not applied to the staged row")
    }

    @Test("aiNeverFlashes — AI fields stay non-nil through the WHOLE staged→phase1→ftsFlush→phase2→drain lifecycle (I3, including the §2.1a window)")
    func aiNeverFlashes() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("m1", uid: "101", minutesAgo: 5, tag: "reply", blurb: "staged blurb")
        ])
        var ai = AITracker()
        // Every step composes + checks I3; also assert explicitly per stage.
        var composed = runSteps([(.stagePush, "m1")], world: &world, ai: &ai, scenario: "aiNeverFlashes")
        #expect(composed.first?.actionTag == .reply)
        #expect(composed.first?.summaryBlurb == "staged blurb")

        // phase-1: durable header EXISTS but headerComplete=false (invisible
        // to D) — row must still render from S, WITH its AI fields.
        composed = runSteps([(.phase1Commit, "m1")], world: &world, ai: &ai, scenario: "aiNeverFlashes")
        #expect(composed.count == 1)
        #expect(composed.first?.actionTag == .reply, "AI flashed in the phase1 (headerComplete=false) window")
        #expect(composed.first?.summaryBlurb == "staged blurb")

        // ftsFlush: durable becomes visible to D, AI-less — the S row is
        // suppressed as a duplicate but its AI fields must carry over.
        composed = runSteps([(.ftsFlushCommit, "m1")], world: &world, ai: &ai, scenario: "aiNeverFlashes")
        #expect(composed.count == 1)
        #expect(composed.first?.actionTag == .reply, "AI flashed when the AI-less durable row became D-visible (carry-over missing)")
        #expect(composed.first?.summaryBlurb == "staged blurb")
        #expect(composed.first?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder not mirrored with the carried actionTag")

        // phase-2 + drain: durable AI lands; S drains; still non-nil.
        composed = runSteps([
            (.phase2Commit, "m1"),
            (.drainStaging, "m1"),
        ], world: &world, ai: &ai, scenario: "aiNeverFlashes")
        #expect(composed.first?.actionTag == .reply)
        #expect(composed.first?.summaryBlurb == "staged blurb")
    }

    @Test("ftsFlushWindowNoVanish — THE §2.1a regression test: durable row exists (headerComplete=false) but is invisible to D; the S row must still render")
    func ftsFlushWindowNoVanish() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        let composed = runSteps([
            (.stagePush, "m1"),
            (.phase1Commit, "m1"),
            // NO ftsFlushCommit — we are INSIDE the window blanket
            // identity-existence suppression would blank.
        ], world: &world, ai: &ai, scenario: "ftsFlushWindowNoVanish")
        #expect(
            contains(composed, world, "m1"),
            "row vanished in the phase1→ftsFlush window (the §2.1a defect: blanket identity-existence suppression)"
        )
        // Storm it — the vanish-flicker was reload-driven.
        let stormed = composeRepeatedly(
            10, world: world, ai: &ai, scenario: "ftsFlushWindowNoVanish", note: "inside FTS-flush window"
        )
        #expect(contains(stormed, world, "m1"))
    }

    @Test("undoSurvivesEveryReload — from undo onward the row is in EVERY composed list, before AND after the restore write, across overlay drain (I4)")
    func undoSurvivesEveryReload() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        // Make it durable + visible, then archive it (write lands, overlay drains).
        runSteps([
            (.stagePush, "m1"),
            (.phase1Commit, "m1"),
            (.ftsFlushCommit, "m1"),
            (.phase2Commit, "m1"),
            (.drainStaging, "m1"),
            (.userMove, "m1"),
            (.optimisticWrite, "m1"),
            (.overlayDrain, "m1"),
        ], world: &world, ai: &ai, scenario: "undoSurvivesEveryReload")

        // Undo: overlay back-to-inbox, DB restore write still deferred.
        var composed = runSteps([(.undo, "m1")], world: &world, ai: &ai, scenario: "undoSurvivesEveryReload")
        #expect(contains(composed, world, "m1"), "undone row missing immediately after undo (P-step hole)")

        // The latent hole today: reloads between undo and the restore write
        // evicted the row. The P-step must survive any number of them.
        composed = composeRepeatedly(
            15, world: world, ai: &ai, scenario: "undoSurvivesEveryReload", note: "pre-restore-write storm"
        )
        #expect(contains(composed, world, "m1"), "undone row vanished during pre-restore-write reload storm")

        composed = runSteps([
            (.undoRestoreWrite, "m1"),
            (.overlayDrain, "m1"),
        ], world: &world, ai: &ai, scenario: "undoSurvivesEveryReload")
        #expect(contains(composed, world, "m1"), "undone row vanished after restore write / overlay drain")
    }

    @Test("staleDeleteSelfHeals — sync stale-deletes a still-staged row: the S row becomes eligible again and the display never blanks (§2.3 emergent property)")
    func staleDeleteSelfHeals() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        let composed = runSteps([
            (.stagePush, "m1"),
            (.phase1Commit, "m1"),
            (.ftsFlushCommit, "m1"),
            (.staleDelete, "m1"),  // durable gone; identity flips to "absent"
        ], world: &world, ai: &ai, scenario: "staleDeleteSelfHeals")
        #expect(
            contains(composed, world, "m1"),
            "display blanked after a transient sync stale-delete — S row did not become re-eligible"
        )
    }

    @Test("uidRemapArchiveSuppressesStaged — server-side MOVE re-keys the durable id; the stale re-staged INBOX row is suppressed via the rfc822 fallback (I1/I5, 485a4d1 class)")
    func uidRemapArchiveSuppressesStaged() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        let composed = runSteps([
            (.stagePush, "m1"),
            (.phase1Commit, "m1"),
            (.ftsFlushCommit, "m1"),
            (.phase2Commit, "m1"),
            (.drainStaging, "m1"),
            (.uidRemap, "m1"),  // MOVE to Archive: new UID, new headerId, rfc822 link only
            (.reStage, "m1"),   // stale re-stage under the OLD uid + INBOX folder
        ], world: &world, ai: &ai, scenario: "uidRemapArchiveSuppressesStaged")
        #expect(
            !contains(composed, world, "m1"),
            "UID-remapped archived message resurrected — rfc822 fallback identity lookup failed to suppress the stale staged row"
        )
    }

    @Test("pushRedeliveryIsIdempotent — at-least-once duplicates never produce a second row (I5) at any lifecycle stage")
    func pushRedeliveryIsIdempotent() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        var composed = runSteps([
            (.stagePush, "m1"),
            (.pushRedelivery, "m1"),  // pre-durability duplicate
        ], world: &world, ai: &ai, scenario: "pushRedeliveryIsIdempotent")
        #expect(composed.count == 1)

        composed = runSteps([
            (.phase1Commit, "m1"),
            (.pushRedelivery, "m1"),  // duplicate inside the FTS-flush window
            (.ftsFlushCommit, "m1"),
            (.pushRedelivery, "m1"),  // duplicate with a D-visible durable copy
            (.phase2Commit, "m1"),
            (.drainStaging, "m1"),
            (.pushRedelivery, "m1"),  // duplicate AFTER drain — re-populates S
        ], world: &world, ai: &ai, scenario: "pushRedeliveryIsIdempotent")
        #expect(composed.count == 1, "push redelivery produced a duplicate row")
        #expect(contains(composed, world, "m1"))
    }

    // MARK: - Filter / order / window scenarios (I7)

    @Test("unreadFilter — read staged rows drop (post-overlay), unread staged + unread durable stay")
    func unreadFilterScenario() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("mReadStaged", uid: "101", minutesAgo: 1, readAtPush: true),
            SimWorld.spec("mUnreadStaged", uid: "102", minutesAgo: 2),
            SimWorld.spec("mUnreadDurable", uid: "103", minutesAgo: 3),
        ])
        var ai = AITracker()
        let query = InboxListQuery(
            displayedFolderIds: world.displayedFolderIds, filterUnread: true,
            filterLabelIds: [], mode: .normal, targetCount: 50, beforeDate: nil
        )
        let composed = runSteps([
            (.stagePush, "mReadStaged"),
            (.stagePush, "mUnreadStaged"),
            (.stagePush, "mUnreadDurable"),
            (.phase1Commit, "mUnreadDurable"),
            (.ftsFlushCommit, "mUnreadDurable"),
            (.phase2Commit, "mUnreadDurable"),
            (.drainStaging, "mUnreadDurable"),
        ], world: &world, query: query, ai: &ai, scenario: "unreadFilter")
        #expect(composed.count == 2)
        #expect(!contains(composed, world, "mReadStaged"), "read staged row leaked through filterUnread")
        #expect(contains(composed, world, "mUnreadStaged"))
        #expect(contains(composed, world, "mUnreadDurable"))

        // A userRead overlay on the staged row now drops it too — S rows are
        // filtered POST-overlay (insertStagedRows parity).
        let after = runSteps([
            (.userRead, "mUnreadStaged"),
        ], world: &world, query: query, ai: &ai, scenario: "unreadFilter")
        #expect(!contains(after, world, "mUnreadStaged"), "post-overlay read staged row leaked through filterUnread")
    }

    @Test("labelFilter — S rows have no labels, so an active label filter drops them (the deliberate §2.1 unification; I7)")
    func labelFilterDropsStagedRows() {
        var world = SimWorld.standard(messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)])
        var ai = AITracker()
        let query = InboxListQuery(
            displayedFolderIds: world.displayedFolderIds, filterUnread: false,
            filterLabelIds: ["label-x"], mode: .normal, targetCount: 50, beforeDate: nil
        )
        let composed = runSteps([
            (.stagePush, "m1"),
        ], world: &world, query: query, ai: &ai, scenario: "labelFilter")
        #expect(
            composed.isEmpty,
            "staged (unlabeled) row leaked through an active label filter — insertStagedRows' gap must NOT survive into the reader"
        )
    }

    // audit round 4: labelFilterDropsStagedRows above only proves the
    // negative path (S always drops, zero labels). This proves the positive
    // path — D and P rows carrying the filtered label SURVIVE, in the same
    // compose call as an always-dropped S row and unlabeled D/P siblings —
    // pinning compose step 6's "uniform over D, P, and S" contract from both
    // directions at once.
    @Test("labeledRowsSurviveLabelFilterInCompose — a labeled D row and a labeled P (overlay-pinned, undo-shape) row survive an active label filter in the SAME compose call; unlabeled D/P siblings and the (always-unlabeled) S row all drop")
    func labeledRowsSurviveLabelFilterInCompose() {
        let accountId = "acc1"
        let folderPath = "INBOX"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let archivePath = "Archive"
        let now = Date()
        let labelX = [UserLabel(id: "label-x", accountId: accountId, name: "Filtered", isSystem: false)]

        // D — durable, already in the displayed folder.
        let dLabeled = SimHeader(
            id: MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "d-labeled"),
            accountId: accountId, messageId: "d-labeled", rfc822MessageId: nil,
            folderId: folderId, folderPath: folderPath, isInInbox: true, isRead: false,
            headerComplete: true, actionTag: nil, summaryBlurb: nil, date: now, userLabels: labelX
        ).toSnapshot()
        let dUnlabeled = SimHeader(
            id: MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "d-unlabeled"),
            accountId: accountId, messageId: "d-unlabeled", rfc822MessageId: nil,
            folderId: folderId, folderPath: folderPath, isInInbox: true, isRead: false,
            headerComplete: true, actionTag: nil, summaryBlurb: nil, date: now
        ).toSnapshot()

        // P — overlay-pinned "undo shape": durable identity lives in
        // Archive, but the shell has ALREADY applied the overlay's folderId
        // onto the snapshot (ComposeInputs.pinned's documented shape) before
        // compose ever sees it — mirrors InboxListReader's P-step.
        let pLabeled = SimHeader(
            id: MessageIdentity.headerId(accountId: accountId, folderPath: archivePath, messageId: "p-labeled"),
            accountId: accountId, messageId: "p-labeled", rfc822MessageId: nil,
            folderId: folderId, folderPath: archivePath, isInInbox: true, isRead: false,
            headerComplete: true, actionTag: nil, summaryBlurb: nil, date: now, userLabels: labelX
        ).toSnapshot()
        let pUnlabeled = SimHeader(
            id: MessageIdentity.headerId(accountId: accountId, folderPath: archivePath, messageId: "p-unlabeled"),
            accountId: accountId, messageId: "p-unlabeled", rfc822MessageId: nil,
            folderId: folderId, folderPath: archivePath, isInInbox: true, isRead: false,
            headerComplete: true, actionTag: nil, summaryBlurb: nil, date: now
        ).toSnapshot()
        let overlay: [String: AccountManager.PendingMutation] = [
            pLabeled.id: AccountManager.PendingMutation(folderId: folderId),
            pUnlabeled.id: AccountManager.PendingMutation(folderId: folderId),
        ]

        // S — staged-only row, no durable resolution. Always synthesizes
        // with userLabels == [] (compose step 2 / StagedInboxRow.
        // toMessageHeader()), so it must drop under an active label filter
        // regardless — the deliberate D/P/S unification (step 6 doc comment).
        let staged = StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: "s-staged",
            rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
            subject: "Staged", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: now,
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )

        let query = InboxListQuery(
            displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: ["label-x"],
            mode: .normal, targetCount: 50, beforeDate: nil
        )
        let composed = InboxListComposer.compose(ComposeInputs(
            durable: [dLabeled, dUnlabeled], pinned: [pLabeled, pUnlabeled], staged: [staged],
            stagedResolutions: [:], overlay: overlay, query: query
        ))

        let ids = composed.map(\.id)
        #expect(composed.count == 2, "expected exactly the two labeled D/P rows to survive, got ids=\(ids)")
        #expect(ids.contains(dLabeled.id), "labeled durable row dropped by the active label filter")
        #expect(ids.contains(pLabeled.id), "labeled pinned row dropped by the active label filter")
        #expect(!ids.contains(dUnlabeled.id), "unlabeled durable row leaked through the active label filter")
        #expect(!ids.contains(pUnlabeled.id), "unlabeled pinned row leaked through the active label filter")
        let stagedId = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "s-staged")
        #expect(!ids.contains(stagedId), "staged row (always userLabels == []) leaked through the active label filter")
        #expect(
            composed.first { $0.id == dLabeled.id }?.userLabels.map(\.id) == ["label-x"],
            "userLabels not carried onto the composed durable row"
        )
        #expect(
            composed.first { $0.id == pLabeled.id }?.userLabels.map(\.id) == ["label-x"],
            "userLabels not carried onto the composed pinned row"
        )
    }

    @Test("triageOrder — tagSortOrder asc then date desc, across durable AND staged sources")
    func triageOrderScenario() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("mReplyOld", uid: "101", minutesAgo: 60, tag: "reply"),
            SimWorld.spec("mArchiveNew", uid: "102", minutesAgo: 1, tag: "archive"),
            SimWorld.spec("mReplyStaged", uid: "103", minutesAgo: 120, tag: "reply"),
        ])
        var ai = AITracker()
        let query = InboxListQuery(
            displayedFolderIds: world.displayedFolderIds, filterUnread: false,
            filterLabelIds: [], mode: .triage, targetCount: 50, beforeDate: nil
        )
        let composed = runSteps([
            (.stagePush, "mReplyOld"),
            (.phase1Commit, "mReplyOld"),
            (.ftsFlushCommit, "mReplyOld"),
            (.phase2Commit, "mReplyOld"),
            (.drainStaging, "mReplyOld"),
            (.stagePush, "mArchiveNew"),
            (.phase1Commit, "mArchiveNew"),
            (.ftsFlushCommit, "mArchiveNew"),
            (.phase2Commit, "mArchiveNew"),
            (.drainStaging, "mArchiveNew"),
            (.stagePush, "mReplyStaged"),  // staged-only, oldest, reply-tagged
        ], world: &world, query: query, ai: &ai, scenario: "triageOrder")
        #expect(composed.count == 3)
        guard composed.count == 3 else { return }
        // reply(0) rows first (newest first within the tier), archive(2) last.
        #expect(composed[0].messageId == "101")  // reply, -60min
        #expect(composed[1].messageId == "103")  // reply, -120min (staged)
        #expect(composed[2].messageId == "102")  // archive, -1min
    }

    @Test("windowTrim — sorted trim to targetCount; a newer staged row displaces the oldest durable row (§4.3)")
    func windowTrimScenario() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("d1", uid: "101", minutesAgo: 10),
            SimWorld.spec("d2", uid: "102", minutesAgo: 20),
            SimWorld.spec("d3", uid: "103", minutesAgo: 30),
            SimWorld.spec("sNew", uid: "104", minutesAgo: 1),
        ])
        var ai = AITracker()
        let query = InboxListQuery(
            displayedFolderIds: world.displayedFolderIds, filterUnread: false,
            filterLabelIds: [], mode: .normal, targetCount: 3, beforeDate: nil
        )
        let composed = runSteps([
            (.stagePush, "d1"), (.phase1Commit, "d1"), (.ftsFlushCommit, "d1"),
            (.phase2Commit, "d1"), (.drainStaging, "d1"),
            (.stagePush, "d2"), (.phase1Commit, "d2"), (.ftsFlushCommit, "d2"),
            (.phase2Commit, "d2"), (.drainStaging, "d2"),
            (.stagePush, "d3"), (.phase1Commit, "d3"), (.ftsFlushCommit, "d3"),
            (.phase2Commit, "d3"), (.drainStaging, "d3"),
            (.stagePush, "sNew"),  // staged-only, newest — must displace d3
        ], world: &world, query: query, ai: &ai, scenario: "windowTrim")
        #expect(composed.count == 3)
        guard composed.count == 3 else { return }
        #expect(composed[0].messageId == "104", "newest staged row missing from the trimmed window")
        #expect(composed[1].messageId == "101")
        #expect(composed[2].messageId == "102")
        #expect(!contains(composed, world, "d3"), "oldest durable row not displaced by the window trim")
    }

    @Test("paginationCutoff — beforeDate applies to S (and P) rows, matching D's SQL cutoff")
    func paginationCutoffScenario() {
        var world = SimWorld.standard(messages: [
            SimWorld.spec("sNewer", uid: "101", minutesAgo: 1),
            SimWorld.spec("sOlder", uid: "102", minutesAgo: 120),
            SimWorld.spec("dOlder", uid: "103", minutesAgo: 90),
        ])
        var ai = AITracker()
        let cutoff = SimWorld.baseDate.addingTimeInterval(-60 * 60)  // 60 minutes ago
        let query = InboxListQuery(
            displayedFolderIds: world.displayedFolderIds, filterUnread: false,
            filterLabelIds: [], mode: .normal, targetCount: 50, beforeDate: cutoff
        )
        let composed = runSteps([
            (.stagePush, "sNewer"),
            (.stagePush, "sOlder"),
            (.stagePush, "dOlder"),
            (.phase1Commit, "dOlder"),
            (.ftsFlushCommit, "dOlder"),
            (.phase2Commit, "dOlder"),
            (.drainStaging, "dOlder"),
        ], world: &world, query: query, ai: &ai, scenario: "paginationCutoff")
        #expect(!contains(composed, world, "sNewer"), "staged row newer than the pagination cutoff leaked into the page")
        #expect(contains(composed, world, "sOlder"))
        #expect(contains(composed, world, "dOlder"))
    }

    // MARK: - F2 audit: excludeIds ordering (dedup BEFORE trim, not after)

    /// F2 (PLAN_INBOX_UNIFIED_READ.md audit): `compose` used to trim to
    /// `targetCount` BEFORE the VM's `loadedIds` dedup ran (that dedup lived
    /// entirely in `InboxViewModel.fetchPage`, downstream of the already-
    /// trimmed page). In triage mode the sort is NOT date-monotonic (an old
    /// high-priority row can sort ahead of newer untagged ones), so an
    /// already-loaded row can occupy a trim slot a not-yet-loaded row needed
    /// — the composed/paged result shrinks below `targetCount` even though
    /// more mail exists. `query.excludeIds` must be removed AFTER
    /// eligibility/carry-over decisions but BEFORE the sort/trim, restoring
    /// the old dedup-before-prefix ordering.
    @Test("excludeIdsAppliedBeforeTrim — the excluded (already-loaded) row sorts FIRST in triage mode; composed is still a full targetCount page of the OTHER rows, not short by one")
    func excludeIdsAppliedBeforeTrimScenario() {
        // Bypasses SimWorld deliberately: SimWorld.inputs' D-gather mirrors
        // the shell's PER-FOLDER SQL `.limit(query.targetCount)` (§2.1b),
        // which — with a single folder and 4 rows at targetCount=3 — would
        // itself trim `durable` down to 3 BEFORE compose ever sees it,
        // masking the compose-level trim-vs-exclude ordering this test
        // exists to pin. Constructing `ComposeInputs.durable` directly hands
        // compose all 4 rows, exactly as a multi-folder union (§2.1 step 1)
        // or a folder with room would in production.
        let accountId = "acc1"
        let folderPath = "INBOX"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let now = Date()

        func makeDurable(_ messageId: String, minutesAgo: Int, tag: ActionTag? = nil) -> MessageSnapshot {
            var h = MessageHeader(
                messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
                to: "me@example.com", date: now.addingTimeInterval(-60 * Double(minutesAgo)), snippet: "snip",
                folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
            )
            h.headerComplete = true
            h.actionTag = tag
            h.tagSortOrder = tag?.sortOrder ?? 99
            return MessageSnapshot(from: h)
        }

        // Lowest tagSortOrder (reply) sorts FIRST regardless of date — this
        // is the "already loaded" row the VM excludes.
        let rExcluded = makeDurable("101", minutesAgo: 1, tag: .reply)
        let r2 = makeDurable("102", minutesAgo: 2)
        let r3 = makeDurable("103", minutesAgo: 3)
        let r4 = makeDurable("104", minutesAgo: 4)

        let query = InboxListQuery(
            displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: [],
            mode: .triage, targetCount: 3, beforeDate: nil, excludeIds: [rExcluded.id]
        )
        let composed = InboxListComposer.compose(ComposeInputs(
            durable: [rExcluded, r2, r3, r4], pinned: [], staged: [],
            stagedResolutions: [:], overlay: [:], query: query
        ))

        // Old dedup-BEFORE-prefix answer: a full page of 3 non-excluded rows.
        // The BUGGY trim-before-dedup ordering would sort
        // [rExcluded, r2, r3, r4], trim to [rExcluded, r2, r3] FIRST, THEN
        // remove rExcluded — leaving only 2 rows (r2, r3), silently dropping
        // r4 and eating a trim slot the caller never asked to give up.
        #expect(composed.count == 3, "excludeIds shrank the page below targetCount — trim ran before exclusion")
        #expect(!composed.contains { $0.id == rExcluded.id }, "excluded (already-loaded) row leaked into the page")
        #expect(composed.contains { $0.id == r2.id })
        #expect(composed.contains { $0.id == r3.id })
        #expect(composed.contains { $0.id == r4.id }, "r4 was dropped — the trim-before-exclusion bug")
    }

    /// F2 × §2.1a case-(c) interaction (coordinator addendum): an S row whose
    /// identity resolution points at a durable row that is BOTH present in D
    /// AND targeted by `excludeIds` (the durable copy is already on screen
    /// from a previous page). Proves the exclusion point chosen for F2 — AFTER
    /// the S-eligibility loop's `byId[durable.id]` membership check, BEFORE
    /// sort/trim — keeps case (c) correct: the membership check sees D1 (not
    /// yet removed), so S1 is suppressed as a duplicate exactly like it would
    /// be with no `excludeIds` at all; THEN D1 itself is dropped by the
    /// exclusion step. The bug this guards against: excluding D1 BEFORE the S
    /// loop would make the `byId[durable.id]` check miss, falling S1 through
    /// to case (d) ("NOT in D ∪ P → INCLUDE") — resurrecting a duplicate row
    /// for an identity that's already on screen.
    @Test("excludeIdsCaseCInteraction — an S row resolving to a durable row that's BOTH in D and in excludeIds is still suppressed as a duplicate, and the excluded durable row itself is absent from the composed page")
    func excludeIdsCaseCInteractionScenario() {
        let accountId = "acc1"
        let folderPath = "INBOX"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)

        // D1 — already on screen from a PREVIOUS page; `excludeIds` targets it.
        var d1Header = MessageHeader(
            messageId: "1", subject: "Original", from: "Alice", fromAddress: "alice@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        d1Header.rfc822MessageId = "rfc-d1@example.com"
        d1Header.headerComplete = true
        let d1 = MessageSnapshot(from: d1Header)

        // D2 — unrelated durable row, NOT excluded — a control proving only
        // the targeted identity is affected.
        var d2Header = MessageHeader(
            messageId: "2", subject: "Other", from: "Bob", fromAddress: "bob@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        d2Header.rfc822MessageId = "rfc-d2@example.com"
        d2Header.headerComplete = true
        let d2 = MessageSnapshot(from: d2Header)

        // S1 — a staged re-push of D1's identity (e.g. a re-notification)
        // whose resolved durable ref is D1: same folder, still inInbox — NOT
        // stale-by-move, so §2.1a case (c) applies (suppress as a duplicate,
        // AI carry-over onto D1 only).
        let s1 = StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: "1",
            rfc822MessageId: "rfc-d1@example.com", threadId: nil, inReplyTo: nil, references: [],
            subject: "Original", senderName: "Alice", senderAddress: "alice@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: "reply", summaryBlurb: "staged blurb"
        )
        let resolutions: [String: StagedIdentityResolution] = [
            s1.headerId: StagedIdentityResolution(
                stagedHeaderId: s1.headerId,
                durable: DurableIdentityLookup.DurableHeaderRef(
                    id: d1.id, folderId: d1Header.folderId, folderPath: d1Header.folderPath,
                    isInInbox: true, rfc822MessageId: d1.rfc822MessageId
                )
            )
        ]

        let query = InboxListQuery(
            displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: [],
            mode: .normal, targetCount: 50, beforeDate: nil, excludeIds: [d1.id]
        )
        let composed = InboxListComposer.compose(ComposeInputs(
            durable: [d1, d2], pinned: [], staged: [s1],
            stagedResolutions: resolutions, overlay: [:], query: query
        ))

        #expect(composed.count == 1, "expected only the unrelated control row d2 to survive")
        #expect(!composed.contains { $0.id == d1.id }, "excluded durable row D1 leaked into the composed page")
        #expect(
            !composed.contains { $0.id == s1.headerId },
            "S1 was NOT suppressed as a duplicate — case (c) broke once its target became excludeIds-targeted"
        )
        #expect(composed.first?.id == d2.id, "unrelated control row D2 must be unaffected by D1's exclusion")
    }

    /// F2 normal-mode invariance (coordinator addendum): in `.normal` mode
    /// with a date-monotonic pagination window, an already-loaded id never
    /// re-enters a later page's D query in the first place (the SQL
    /// `date < beforeDate` cutoff guarantees every returned row is strictly
    /// older than every previously-loaded row) — so `excludeIds` has nothing
    /// to remove and composing with vs. without it produces the IDENTICAL
    /// page. Pins that the fix only changes behavior where the bug actually
    /// lived (triage mode's non-date-monotonic sort, §2.1a); it must not
    /// perturb the far more common normal-mode path.
    @Test("excludeIdsNormalModeNoOp — .normal mode, date-monotonic window: excludeIds is a no-op when no already-loaded row re-enters the batch")
    func excludeIdsNormalModeNoOpScenario() {
        let accountId = "acc1"
        let folderPath = "INBOX"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let now = Date()

        func makeDurable(_ messageId: String, minutesAgo: Int) -> MessageSnapshot {
            var h = MessageHeader(
                messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
                to: "me@example.com", date: now.addingTimeInterval(-60 * Double(minutesAgo)), snippet: "snip",
                folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
            )
            h.headerComplete = true
            return MessageSnapshot(from: h)
        }

        // Page 2's D input under NORMAL mode: every row is STRICTLY older
        // than the page-1 cursor — exactly what the SQL `date < beforeDate`
        // cutoff guarantees in production, so no already-loaded id can
        // appear here.
        let durable = [
            makeDurable("p2-1", minutesAgo: 61),
            makeDurable("p2-2", minutesAgo: 62),
            makeDurable("p2-3", minutesAgo: 63),
            makeDurable("p2-4", minutesAgo: 64),
        ]

        // loadedIds from page 1 — disjoint from `durable` above (a
        // well-behaved normal-mode page-2 D query, unlike the triage-mode
        // bug this fix targets).
        let loadedIds: Set<String> = [
            MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "p1-1"),
            MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "p1-2"),
        ]

        let inputsNoExclude = ComposeInputs(
            durable: durable, pinned: [], staged: [], stagedResolutions: [:], overlay: [:],
            query: InboxListQuery(
                displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: [],
                mode: .normal, targetCount: 4, beforeDate: now.addingTimeInterval(-60 * 60)
            )
        )
        let inputsWithExclude = ComposeInputs(
            durable: durable, pinned: [], staged: [], stagedResolutions: [:], overlay: [:],
            query: InboxListQuery(
                displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: [],
                mode: .normal, targetCount: 4, beforeDate: now.addingTimeInterval(-60 * 60),
                excludeIds: loadedIds
            )
        )

        let withoutExclude = InboxListComposer.compose(inputsNoExclude)
        let withExclude = InboxListComposer.compose(inputsWithExclude)

        #expect(
            withExclude.map(\.id) == withoutExclude.map(\.id),
            "excludeIds changed the composed page even though no already-loaded row re-entered the batch — should be a no-op here"
        )
        #expect(withExclude.count == 4)
    }

    // MARK: - F4 audit: same-batch staged-sibling thread adoption

    /// F4 (PLAN_INBOX_UNIFIED_READ.md audit): `compose`'s S-loop adoption
    /// source used to be `frozenDP` ONLY (frozen before the loop starts), so
    /// a staged reply to a staged sibling in the SAME batch couldn't
    /// chain-adopt — old `insertStagedRows` adopted from the growing
    /// `loadedMessages` array, so a same-batch reply-to-a-reply DID chain
    /// there. Bypasses `SimWorld` (whose `stage()` always synthesizes
    /// `threadId: nil, inReplyTo: nil, references: []`) to construct the
    /// staged/durable rows directly with the reply-chain fields the bug
    /// needs.
    @Test("sameBatchStagedSiblingChainAdoption — a staged reply-to-a-staged-reply in the SAME batch chain-adopts the thread")
    func sameBatchStagedSiblingChainAdoption() {
        let accountId = "acc1"
        let folderPath = "INBOX"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)

        // D1 — an existing durable row, already grouped into thread "T1".
        var d1Header = MessageHeader(
            messageId: "1", subject: "Original", from: "Alice", fromAddress: "alice@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: true
        )
        d1Header.rfc822MessageId = "rfc-d1@example.com"
        d1Header.computedThreadId = "T1"
        d1Header.headerComplete = true
        let d1 = MessageSnapshot(from: d1Header)

        // S1 — staged direct reply to D1 (references D1's rfc822MessageId).
        let s1 = StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: "2",
            rfc822MessageId: "rfc-s1@example.com", threadId: nil, inReplyTo: nil,
            references: ["rfc-d1@example.com"], subject: "Re: Original", senderName: "Bob",
            senderAddress: "bob@example.com", to: "me@example.com", snippet: "snip",
            date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
        // S2 — staged reply to S1 ONLY: a truncated references chain (no D1
        // link at all). Same batch as S1 — this is exactly the case old
        // `insertStagedRows` handled by adopting from the growing
        // `loadedMessages`, and a `frozenDP`-only adoption pool misses.
        let s2 = StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: "3",
            rfc822MessageId: "rfc-s2@example.com", threadId: nil, inReplyTo: "rfc-s1@example.com",
            references: ["rfc-s1@example.com"], subject: "Re: Re: Original", senderName: "Carol",
            senderAddress: "carol@example.com", to: "me@example.com", snippet: "snip",
            date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: nil
        )

        // Neither S1 nor S2 has a durable header of its own yet (ordinary new
        // staged messages) — both resolutions are nil.
        let resolutions: [String: StagedIdentityResolution] = [
            s1.headerId: StagedIdentityResolution(stagedHeaderId: s1.headerId, durable: nil),
            s2.headerId: StagedIdentityResolution(stagedHeaderId: s2.headerId, durable: nil),
        ]

        let query = InboxListQuery(
            displayedFolderIds: [folderId], filterUnread: false, filterLabelIds: [],
            mode: .normal, targetCount: 50, beforeDate: nil
        )
        let composed = InboxListComposer.compose(ComposeInputs(
            durable: [d1], pinned: [], staged: [s1, s2],
            stagedResolutions: resolutions, overlay: [:], query: query
        ))

        #expect(composed.count == 3)
        let s1Composed = composed.first { $0.id == s1.headerId }
        let s2Composed = composed.first { $0.id == s2.headerId }
        #expect(s1Composed?.computedThreadId == "T1", "S1 (direct reply to D1) did not adopt D1's thread")
        #expect(
            s2Composed?.computedThreadId == "T1",
            "S2 (same-batch reply to staged S1, no D1 link) did not chain-adopt — F4 regression"
        )
    }

    // MARK: - Permutation checks (commutable step pairs — §5A.1)

    /// Runs `setup`, then the pair in both orders (fresh worlds), asserting
    /// invariants throughout AND that the two orders converge to the same
    /// composed identity set.
    private func assertCommutes(
        setup: [(SimWorld.Step, String)],
        pair: ((SimWorld.Step, String), (SimWorld.Step, String)),
        messages: [SimMessageSpec],
        scenario: String
    ) {
        var identitySets: [Set<String>] = []
        for (order, steps) in [(0, [pair.0, pair.1]), (1, [pair.1, pair.0])] {
            var world = SimWorld.standard(messages: messages)
            var ai = AITracker()
            let composed = runSteps(
                setup + steps, world: &world, ai: &ai, scenario: "\(scenario)/order\(order)"
            )
            identitySets.append(Set(composed.map {
                identityKey(accountId: $0.accountId, messageId: $0.messageId, rfc822: $0.rfc822MessageId)
            }))
        }
        #expect(identitySets.count == 2)
        guard identitySets.count == 2 else { return }
        #expect(
            identitySets[0] == identitySets[1],
            "\(scenario): composed identity sets diverge across the two step orders — \(identitySets[0].sorted()) vs \(identitySets[1].sorted())"
        )
    }

    @Test("permutation: phase1Commit and userRead commute")
    func phase1CommitAndUserReadCommute() {
        assertCommutes(
            setup: [(.stagePush, "m1")],
            pair: ((.phase1Commit, "m1"), (.userRead, "m1")),
            messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5)],
            scenario: "phase1CommitVsUserRead"
        )
    }

    @Test("permutation: overlayDrain and phase2Commit commute")
    func overlayDrainAndPhase2Commute() {
        assertCommutes(
            setup: [
                (.stagePush, "m1"),
                (.phase1Commit, "m1"),
                (.ftsFlushCommit, "m1"),
                (.userRead, "m1"),
                (.optimisticWrite, "m1"),
            ],
            pair: ((.overlayDrain, "m1"), (.phase2Commit, "m1")),
            messages: [SimWorld.spec("m1", uid: "101", minutesAgo: 5, tag: "reply", blurb: "b1")],
            scenario: "overlayDrainVsPhase2Commit"
        )
    }

    // MARK: - Seeded fuzz (§5A.1 — explores the orderings nobody named)

    /// Pool: 4 messages (2 carrying AI fields) over 2 folders (INBOX
    /// displayed, Archive not). 200 sequences per seed × up to 12 legal
    /// random steps, invariants I1–I7 after EVERY step. All entropy comes
    /// from SplitMix64 over the fixed seeds — reproduce a failure by seed +
    /// sequence + step index in the assertion message.
    private var fuzzPool: [SimMessageSpec] {
        [
            SimWorld.spec("f1", uid: "201", minutesAgo: 1, tag: "reply", blurb: "blurb-f1"),
            SimWorld.spec("f2", uid: "202", minutesAgo: 2),
            SimWorld.spec("f3", uid: "203", minutesAgo: 3, tag: "archive", blurb: "blurb-f3"),
            SimWorld.spec("f4", uid: "204", minutesAgo: 4, readAtPush: true),
        ]
    }

    @Test(
        "seeded fuzz: I1–I7 hold across random legal step sequences",
        arguments: [UInt64(0x5EED_0000_0000_0001), UInt64(0x5EED_0000_0000_0002), UInt64(0x5EED_0000_0000_0003)]
    )
    func seededFuzzInvariants(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for sequence in 0..<200 {
            var world = SimWorld.standard(messages: fuzzPool)
            var ai = AITracker()
            let stepCount = 4 + rng.pick(9)  // 4...12 steps
            for stepIndex in 0..<stepCount {
                // Enumerate all legal (step, message) pairs in deterministic
                // order, pick one — the legality function keeps the walk
                // inside real lifecycle grammar.
                var legal: [(SimWorld.Step, String)] = []
                for step in SimWorld.Step.allCases {
                    for key in world.messageKeys where world.isLegal(step, key) {
                        legal.append((step, key))
                    }
                }
                guard !legal.isEmpty else { break }
                let (step, key) = legal[rng.pick(legal.count)]
                world.apply(step, key)
                let composed = InboxListComposer.compose(world.inputs(query: SimWorld.defaultQuery))
                assertInvariants(
                    world, composed: composed, query: SimWorld.defaultQuery, ai: &ai,
                    context: "fuzz seed=0x\(String(seed, radix: 16)) sequence=\(sequence) step[\(stepIndex)]=\(step.rawValue)(\(key))"
                )
            }
        }
    }

    // MARK: - Determinism (G2 audit — dictionary-iteration-order tie-break,
    // PLAN_INBOX_UNIFIED_READ.md)

    /// A durable `MessageSnapshot` with a specific id/date/tagSortOrder,
    /// bypassing `SimWorld`'s lifecycle machinery entirely — this test isn't
    /// about the lifecycle grammar, only `compose` step 7's sort/trim
    /// determinism under a tied comparator key.
    private func tiedSnapshot(id: String, date: Date, tagSortOrder: Int = 99) -> MessageSnapshot {
        var h = MessageHeader(
            messageId: id, subject: "Subj \(id)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: date, snippet: "snip",
            folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        h.id = id
        h.tagSortOrder = tagSortOrder
        h.headerComplete = true
        return MessageSnapshot(from: h)
    }

    /// G2: `byId.values` (compose step 1) iterates a Swift `Dictionary` —
    /// its order is not a function of insertion order alone and is not
    /// guaranteed stable across otherwise-identical composes. Without a
    /// final `id` tie-break, rows tied on the sort key can straddle the
    /// `targetCount` trim differently across calls, causing a row to
    /// appear/disappear across otherwise-identical reloads even though
    /// nothing in the underlying data changed. Drives `compose` 50× with
    /// the SAME six tied-date rows in SHUFFLED insertion order (seeded
    /// SplitMix64, per the file's fuzz precedent — never
    /// `SystemRandomNumberGenerator`) and asserts every run produces the
    /// IDENTICAL output.
    @Test("compose is deterministic under shuffled input order when a targetCount trim cuts through a tied-date group (normal mode)")
    func composeDeterministicUnderShuffleNormalMode() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ids = (0..<6).map { "acc1:INBOX:m\($0)" }
        var rng = SplitMix64(seed: 0xD37E_0000_0000_0001)
        var firstOutput: [String]?
        for run in 0..<50 {
            let shuffledIds = ids.shuffled(using: &rng)
            let durable = shuffledIds.map { tiedSnapshot(id: $0, date: now) }
            let query = InboxListQuery(
                displayedFolderIds: [MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX")],
                filterUnread: false, filterLabelIds: [], mode: .normal, targetCount: 3, beforeDate: nil
            )
            let composed = InboxListComposer.compose(ComposeInputs(
                durable: durable, pinned: [], staged: [], stagedResolutions: [:], overlay: [:], query: query
            ))
            let outputIds = composed.map(\.id)
            #expect(outputIds.count == 3)
            if let firstOutput {
                #expect(
                    outputIds == firstOutput,
                    "compose output changed across shuffled-input run \(run) — non-deterministic trim: \(outputIds) vs \(firstOutput)"
                )
            } else {
                firstOutput = outputIds
            }
        }
    }

    /// Same G2 mechanism, triage mode: rows tied on BOTH `tagSortOrder` AND
    /// `date` — the comparator's first two keys are exhausted, so only the
    /// `id` tie-break can produce a stable order.
    @Test("compose is deterministic under shuffled input order when a targetCount trim cuts through a tied tagSortOrder+date group (triage mode)")
    func composeDeterministicUnderShuffleTriageMode() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_100)
        let ids = (0..<6).map { "acc1:INBOX:t\($0)" }
        var rng = SplitMix64(seed: 0xD37E_0000_0000_0002)
        var firstOutput: [String]?
        for run in 0..<50 {
            let shuffledIds = ids.shuffled(using: &rng)
            let durable = shuffledIds.map { tiedSnapshot(id: $0, date: now, tagSortOrder: 5) }
            let query = InboxListQuery(
                displayedFolderIds: [MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX")],
                filterUnread: false, filterLabelIds: [], mode: .triage, targetCount: 3, beforeDate: nil
            )
            let composed = InboxListComposer.compose(ComposeInputs(
                durable: durable, pinned: [], staged: [], stagedResolutions: [:], overlay: [:], query: query
            ))
            let outputIds = composed.map(\.id)
            #expect(outputIds.count == 3)
            if let firstOutput {
                #expect(
                    outputIds == firstOutput,
                    "triage compose output changed across shuffled-input run \(run) — non-deterministic trim: \(outputIds) vs \(firstOutput)"
                )
            } else {
                firstOutput = outputIds
            }
        }
    }

    // MARK: - G3 in-memory-comparator hardening (DECISIONS.md ADR-IOS-055
    // audit round 3, `DurableIdentityLookup.isSameLogicalMessage`)

    /// A P row (overlay-pinned Archive message, shown via the "undo shape" —
    /// the shell has ALREADY applied the overlay's folderId onto it) that
    /// shares a raw IMAP UID with a genuinely NEW staged INBOX row, but whose
    /// rfc822 identities are both KNOWN and DISAGREE — proof the two are
    /// different messages (IMAP UIDs are per-folder, ADR-IOS-042). Before the
    /// G3 in-memory-comparator fix, compose step 2's belt `isDuplicateIdentity`
    /// check did a bare (accountId, messageId) match and wrongly suppressed
    /// the new staged row as "already on screen". `stagedResolutions` is
    /// empty — no durable header exists anywhere for the staged identity —
    /// so this exercises the belt dedup specifically, not the (a)/(b)/(c)/(d)
    /// durable-resolution branches above it.
    @Test("G3: a P row and a genuinely new staged row sharing a raw UID but DIFFERING known rfc822 both compose — the staged row is NOT dropped")
    func pinnedRowUidCollisionDoesNotSuppressNewStagedRow() {
        let inboxFolderId = MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX")

        // P row: true durable identity lives in Archive (folderPath "Archive"
        // — its `id` is the Archive-based header id), but the shell has
        // already applied an undo-restore overlay entry mapping its folderId
        // into the displayed inbox set (`ComposeInputs.pinned`'s documented
        // shape).
        var pinnedHeader = MessageHeader(
            messageId: "101", subject: "Archived, undo-pinned", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: SimWorld.baseDate, snippet: "p",
            folderId: inboxFolderId, accountId: "acc1", folderPath: "Archive", isInInbox: true
        )
        pinnedHeader.rfc822MessageId = "<y@example.com>"
        pinnedHeader.headerComplete = true
        let pinnedSnapshot = MessageSnapshot(from: pinnedHeader)
        // Overlay entry re-applying the SAME folderId — the shell already
        // applied it once onto the P snapshot above, so compose step 3's
        // re-application is an idempotent no-op (overlay keys off
        // `snapshot.id`, the durable header's own Archive-based id).
        let overlay: [String: AccountManager.PendingMutation] = [
            pinnedSnapshot.id: AccountManager.PendingMutation(folderId: inboxFolderId),
        ]

        // Genuinely NEW staged INBOX row — same raw UID ("101"), DIFFERENT
        // rfc822. No durable resolution anywhere (never landed durably).
        let stagedRow = StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: "101",
            rfc822MessageId: "<z@example.com>", threadId: nil, inReplyTo: nil, references: [],
            subject: "New message", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: SimWorld.baseDate.addingTimeInterval(60),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )

        let query = InboxListQuery(
            displayedFolderIds: [inboxFolderId], filterUnread: false, filterLabelIds: [],
            mode: .normal, targetCount: 50, beforeDate: nil
        )
        let composed = InboxListComposer.compose(ComposeInputs(
            durable: [], pinned: [pinnedSnapshot], staged: [stagedRow],
            stagedResolutions: [:], overlay: overlay, query: query
        ))

        let ids = composed.map(\.id)
        #expect(Set(ids).count == ids.count, "composed rows must have unique ids, got \(ids)")
        #expect(ids.count == 2, "both the pinned row and the new staged row must compose, got \(ids)")
        #expect(ids.contains(pinnedSnapshot.id), "the P row must still be present")
        let stagedId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "101")
        #expect(
            ids.contains(stagedId),
            "the genuinely new staged row was wrongly suppressed by the UID collision with the pinned row"
        )
        let rfc822s = Set(composed.compactMap(\.rfc822MessageId))
        #expect(
            rfc822s == ["<y@example.com>", "<z@example.com>"],
            "both distinct identities must be present, not collapsed into one — got \(rfc822s)"
        )
    }
}
