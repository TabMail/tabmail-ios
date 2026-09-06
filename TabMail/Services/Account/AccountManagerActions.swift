/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - T4.V8 — honest admission reporting for role moves
//
// PORT of `v2final`'s `IntentionAdmissionDisposition` / `IntentionAdmissionOutcome`
// (`v2final:TabMail/Models/IntentionAdmissionQuarantine.swift`, commit `b1c89ad4a`
// "Stop reporting success for a user action that never reached the provider"),
// with the journal machinery SUBTRACTED — see `RoleMoveAdmission`'s doc.
//
// The one idea: an action's caller must be able to tell "this landed durably"
// from "this could not be determined" from "this provably no longer applies".
// A Bool cannot carry that, and collapsing the middle case into either edge
// reintroduces the bug in one direction or the other: folded into `admitted`
// the caller reports success for work that never reached the provider; folded
// into `failed` the caller reports failure for an action that is still
// outstanding, which invites an agent to retry and act twice.

/// Per-id outcome of a message-move admission. Case names are deliberately
/// identical to `v2final`'s `IntentionAdmissionDisposition` so the two trees
/// stay greppable against each other.
enum RoleMoveDisposition: String, Sendable, Equatable, CaseIterable {
    /// The optimistic local mutation AND its durable `PendingOperation`
    /// committed in the same transaction. The drain owns it from here.
    /// TERMINAL — success.
    case durablyAdmitted
    /// The outcome could not be DETERMINED, or admission was refused by a
    /// self-healing transient guard (unknown folder epoch — T1.3; a folder
    /// mid-UIDVALIDITY-reset — T4.S6; a swallowed or thrown database read; a
    /// rolled-back write). **RETRYABLE.** This is deliberately the default for
    /// every unknown: "we could not determine the answer" is never
    /// authoritative (core philosophy §6, exit 2), and conflating it with
    /// proven staleness is the single most repeated defect in this codebase.
    case retainedForRetry
    /// POSITIVELY PROVEN not applicable: the row is proven absent, it already
    /// sits in the destination role folder, the role is unsupported, or the
    /// server-reported epoch provably moved away from the one this row
    /// observed (core philosophy §6, exit 4 — C3 fail-closed).
    /// **TERMINAL — never retried.**
    case terminalStale
}

/// The `(admitted, pending, failed)` triple a role move reports back.
///
/// PORT of `v2final:IntentionAdmissionOutcome` (commit `b1c89ad4a`).
/// **SUBTRACTED:** the `IntentionAdmissionPhase` dimension, `merge(_:
/// IntentionPhaseAdmission)`, `restricted(to:)` and the quarantine table.
/// Premise unreachable on v3: v3 has no `IntentionJournal`, no `IntentionFold`,
/// no `recordAndWait` and no `intentionAdmissionQuarantine` table, so there is
/// no multi-phase fold whose phases could disagree and nothing that could write
/// a quarantine row. Restoring the phase key would index every entry by a
/// constant (`.move`) and adding the table needs a migration, which this work
/// is forbidden from creating.
///
/// `set` is MONOTONE by rank (`durablyAdmitted` > `retainedForRetry` >
/// `terminalStale`), which makes both halves of the V8 invariant structural
/// rather than a property of call ordering:
///   * proven-admitted work can never be downgraded to pending or failed
///     ("never report failure for work that was admitted"), and
///   * an unknown can never be downgraded to terminal ("could not determine"
///     is not "provider says stale").
/// A coarse outer classification may therefore be written first and refined
/// later — or not at all — without the result ever becoming a lie.
struct RoleMoveAdmission: Sendable, Equatable {
    private(set) var perID: [String: RoleMoveDisposition] = [:]

    /// Ids refused because the row at their address is provably a DIFFERENT
    /// physical message than the one the caller captured
    /// (`ExpectedMessageIdentity`). An ANNOTATION on top of the disposition,
    /// never a fourth disposition: these ids are also `.terminalStale`, and the
    /// monotone rank lattice above is deliberately untouched.
    ///
    /// It exists because "could not be archived" and "the message at that id is
    /// no longer the one you were shown" call for DIFFERENT recoveries. Retrying
    /// the same id after an identity refusal fails identically forever; the only
    /// recovery is to re-read and re-address. An agent told merely "failed" will
    /// retry; told "identity changed", it re-reads.
    private(set) var identityRefusedIds: Set<String> = []

    static let empty = RoleMoveAdmission()

    private static func rank(_ disposition: RoleMoveDisposition) -> Int {
        switch disposition {
        case .durablyAdmitted: 2
        case .retainedForRetry: 1
        case .terminalStale: 0
        }
    }

    /// Monotone assignment — see the type doc. Never lowers an id's rank.
    mutating func set(_ disposition: RoleMoveDisposition, id: String) {
        guard let existing = perID[id] else {
            perID[id] = disposition
            return
        }
        if Self.rank(disposition) > Self.rank(existing) { perID[id] = disposition }
    }

    mutating func set(_ disposition: RoleMoveDisposition, ids: some Sequence<String>) {
        for id in ids { set(disposition, id: id) }
    }

    mutating func merge(_ other: RoleMoveAdmission) {
        for (id, disposition) in other.perID { set(disposition, id: id) }
        identityRefusedIds.formUnion(other.identityRefusedIds)
    }

    /// Record a refusal by content identity. Sets the disposition AND the
    /// annotation together so the two can never disagree.
    mutating func setIdentityRefused(ids: some Sequence<String>) {
        for id in ids {
            set(.terminalStale, id: id)
            identityRefusedIds.insert(id)
        }
    }

    func disposition(for id: String) -> RoleMoveDisposition? { perID[id] }

    func ids(with disposition: RoleMoveDisposition) -> Set<String> {
        Set(perID.compactMap { $0.value == disposition ? $0.key : nil })
    }

    /// Durably admitted — the only bucket a caller may report as success.
    var admittedIds: Set<String> { ids(with: .durablyAdmitted) }
    /// Still outstanding. A caller must report these as NEITHER success NOR
    /// failure — see `RoleMoveDisposition.retainedForRetry`.
    var pendingIds: Set<String> { ids(with: .retainedForRetry) }
    /// Provably not applicable. Safe to surface as a failure.
    var failedIds: Set<String> { ids(with: .terminalStale) }

    /// Stable, compact representation for DEBUG-gated end-to-end action logs.
    /// The disposition is the useful fact; no message content is included.
    var diagnosticSummary: String {
        perID.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: ",")
    }
}

// MARK: - Expected message identity — the producer's content witness
//
// PORT of `v2final:ExpectedMessageIdentity`
// (`v2final:TabMail/Services/Account/AccountManagerIntentions.swift`), with the
// intention-journal plumbing SUBTRACTED (v3 has no journal — ADR-IOS-070).
//
// THE PROBLEM IT EXISTS FOR, in the reference's own words: the composite
// `MessageHeader.id` (`accountId:folderPath:messageId`) "is not proof of WHICH
// physical message a producer looked at: for IMAP, a UIDVALIDITY reset +
// force-resync can DELETE the row a gesture saw and INSERT a different physical
// message under the exact same composite key" while the producer's request is
// still in flight. Any consumer that re-resolves the bare address afterwards then
// acts on the impostor, and every downstream address/epoch check correctly
// authenticates THAT row — because it IS the row the consumer resolved. An epoch
// guard proves the row is addressable in the CURRENT epoch; it cannot prove the
// row is the message the producer pointed at, because after a turnover the
// impostor's epoch is fresh too.
//
// ⚑ NOT AN ADR-IOS-068 / D4 VIOLATION — the direction is the opposite one. D4
// forbids an RFC 822 Message-ID SELECTING or AUTHORIZING a mutation target. Here
// the target is still selected by the durable composite address exactly as
// before; the witness can only REFUSE that target, never widen it or nominate a
// different one. Same content-witness use `AIWriteTarget.resolveCurrentHeader`
// arm 6, `SearchView.resolveLocalResultHeaderId` arm 3, `MessageAICache`, the
// FTS/body stores and RFC 5322 threading already make.

/// One producer's snapshot of the message it captured, for comparison against
/// whatever row later occupies that address.
///
/// ⚑ FAILABLE ON PURPOSE — this is how "no witness ⇒ no refusal" stays
/// STRUCTURAL rather than being a boolean default someone can invert by accident.
/// Mail with no `Message-ID` header genuinely exists (RFC 5322 makes it a SHOULD,
/// not a MUST), and older rows and some provider quirks leave the column nil or
/// unusable. Refusing every action on that population would be a large behaviour
/// regression, so such a producer simply constructs NO identity and the consumer
/// keeps today's behaviour — exactly the reference's contract, whose `map` "SKIPS
/// an id whose header/snapshot has no normalizable one". The reference authored a
/// `(date)` substitute for that population and REMOVED it as unsound in both
/// directions (ADR-IOS-061 item E); a `(fromAddress, subject, date)` substitute
/// was likewise authored (`94fac3e79`) and reverted (`3bd9f0bac`). Do not
/// reintroduce one. The residual is registered as `IOS-IDENTITY-001`.
struct ExpectedMessageIdentity: Sendable, Equatable {
    /// Always a normalized, non-empty RFC 822 Message-ID — normalized ONCE, here,
    /// through the tree's single identity-COMPARISON normalizer.
    let rfc822MessageId: String

    init?(capturedRfc822MessageId: String?) {
        guard let normalized = MessageIdentity.comparableRfc822Identity(capturedRfc822MessageId) else {
            return nil
        }
        self.rfc822MessageId = normalized
    }

    init?(header: MessageHeader) {
        self.init(capturedRfc822MessageId: header.rfc822MessageId)
    }

    /// True when `header` is the same physical message this identity was captured
    /// from. A replacement is a different email and therefore carries a different
    /// Message-ID, so this witness cannot admit one. **No production statement
    /// nulls a row's `rfc822MessageId` deliberately**, so a
    /// captured-present/current-absent pair is treated as a genuine disagreement
    /// rather than an ordinary absence.
    ///
    /// ⚠️ That is the qualified form and the qualification is load-bearing — the
    /// absolute "never nulled once set" is OVERSTATED and this is the C3 witness,
    /// so it is the worst place in the tree to carry an absolute that is false.
    /// `MessageMetadata.rfc822MessageId` is `String?` by construction (nil
    /// whenever the provider payload omits the header) and three production
    /// statements assign that Optional straight onto an EXISTING row with no nil
    /// check — `SyncEngine.gmailDeltaSync` ×2 and `SyncEngine.exchangeDeltaSync`
    /// ×3, i.e. FIVE — so a stored identity can go from present to absent by PROPAGATION
    /// even though nothing nulls it literally. **The failure direction is why
    /// this stays as-is rather than being tightened:** this type is a VETO only,
    /// so a propagated nil causes a spurious refusal, which one ordinary gesture
    /// recovers; the alternative direction would admit a wrong message. Full
    /// derivation, the census predicate, and the stricter in-tree shape to copy
    /// if this is ever tightened (`SyncEngine.performFullSync`'s
    /// `if normalizedIncomingRfc822 != nil` merge guard): the ⚠️ CORRECTED
    /// 2026-08-05 block in the doc comment on
    /// `SearchView.resolveLocalResultHeaderId`, which also records why no guard
    /// is being added at those five sites.
    ///
    /// ⚠️ THIS COMMENT SAID "×1 … ×2 … those THREE sites" UNTIL R16-7
    /// (2026-08-06) — the PRE-re-census number, left behind when round 11 (R11-I)
    /// re-derived the same census and found FIVE. It is the worst shape in the
    /// class: it points the reader at the corrected block in
    /// `SearchView.resolveLocalResultHeaderId` while itself carrying the number
    /// that block exists to retract, so following the pointer produced a
    /// contradiction and trusting the pointer-holder produced a wrong count.
    /// A cache is not invalidated by citing the thing that invalidates it.
    /// Predicate, comments excluded so this paragraph cannot satisfy it:
    ///   `rg -c --pcre2 '^(?!\s*(///|//)).*\.rfc822MessageId\s*=' \
    ///    TabMail/Services/Sync/SyncEngineDeltaSync.swift` → **7**, of which the
    ///   two that build a freshly-parsed `header` for INSERT cannot null a stored
    ///   value and are not counted; the remaining **five** write onto a row that is
    ///   subsequently `update`d. Census by PROPERTY (assignment to
    ///   `rfc822MessageId` on an UPDATED row), never by receiver name — the
    ///   original miss was a `existing.rfc822MessageId =` search that was
    ///   structurally blind to the orphan-reclaim arm's `orphaned.` receiver
    ///   (`MIS-007`).
    func matches(_ header: MessageHeader) -> Bool {
        rfc822MessageId == MessageIdentity.comparableRfc822Identity(header.rfc822MessageId)
    }

    /// Zero-DB construction from headers a producer ALREADY holds. Ids with no
    /// usable witness are EXCLUDED from the map entirely (see the type doc).
    /// Duplicate ids keep the last entry — a caller passing one id twice is a
    /// caller bug, not a reason to trap.
    static func map(_ headers: [MessageHeader]) -> [String: ExpectedMessageIdentity] {
        Dictionary(
            headers.compactMap { header -> (String, ExpectedMessageIdentity)? in
                guard let identity = ExpectedMessageIdentity(header: header) else { return nil }
                return (header.id, identity)
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Split `headers` into the ones still matching their captured identity and
    /// the ids that provably do not. Fail-open per id: a header with no entry in
    /// `expectedIdentities` is kept, so the default empty map compiles to today's
    /// exact behaviour for every caller that passes none.
    static func partition(
        _ headers: [MessageHeader],
        against expectedIdentities: [String: ExpectedMessageIdentity]
    ) -> (matched: [MessageHeader], refusedIds: Set<String>) {
        guard !expectedIdentities.isEmpty else { return (headers, []) }
        var refusedIds: Set<String> = []
        let matched = headers.filter { header in
            guard let expected = expectedIdentities[header.id] else { return true }
            if expected.matches(header) { return true }
            refusedIds.insert(header.id)
            return false
        }
        return (matched, refusedIds)
    }
}

extension AccountManager {

    // MARK: - Actions (optimistic UI + persistent queue)
    //
    // All actions update GRDB state immediately (optimistic UI) then queue the
    // remote operation for async execution. The queue drains when:
    // - NetworkMonitor detects connection restored
    // - Foreground return (SyncScheduler.startForegroundPolling)
    // - After each successful sync poll
    // - On app launch (reconcilePendingOperations → drainPendingQueue)
    //
    // If the server state changed after queueing (message moved/deleted remotely),
    // the queued operation is dropped (conflict detection in drainPendingQueue).

    /// ADR-IOS-049: before an optimistic action writes GRDB, ensure every target
    /// message is durably in GRDB. A row surfaced in-memory via `.messagesStaged`
    /// (`InboxViewModel.insertStagedRows`) isn't in GRDB yet, so the optimistic UPDATE
    /// would hit 0 rows and the NSE merge would later resurrect it as inbox. Draining
    /// the merge first makes the row real so optimistic-state wins. Cheap indexed
    /// existence read on the action path (NOT the render path); no-op + zero
    /// coordinator hop for the ~all case where every target is already durable.
    func ensureDurable(_ messages: [MessageHeader]) async {
        let anyMissing = (try? await dbPool.read { db -> Bool in
            for m in messages {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE id = ?)", arguments: [m.id]) ?? false
                if !exists { return true }
            }
            return false
        }) ?? false
        guard anyMissing else { return }
        await NSEMergeCoordinator.shared.merge()
    }

    /// Off-main `MessageHeader` resolution for use INSIDE queued write closures
    /// (`enqueueWrite`) — never on the MainActor gesture path. Mirrors
    /// `InboxViewModel.lookupMessage`'s exact two-step lookup (durable GRDB row,
    /// else the ADR-IOS-049 staged-row synthesis from `NSEDataBridge.latestStagedRows`)
    /// so a gesture on a just-pushed row not yet durable in GRDB still resolves
    /// once its closure runs — one implementation shared by both call sites
    /// instead of a second copy of the two-step logic.
    ///
    /// Ids that resolve to nothing (row genuinely vanished — e.g. deleted by an
    /// earlier queued op) are silently dropped. Callers gate on the returned
    /// array being smaller than `ids` and must not strand any optimistic
    /// overlay entry registered for a dropped id.
    func resolveHeadersForAction(ids: [String]) async -> [MessageHeader] {
        guard !ids.isEmpty else { return [] }
        let durable = (try? await dbPool.read { db -> [MessageHeader] in
            try MessageHeader.filter(ids.contains(Column("id"))).fetchAll(db)
        }) ?? []
        var byId = Dictionary(uniqueKeysWithValues: durable.map { ($0.id, $0) })
        let missingIds = ids.filter { byId[$0] == nil }
        if !missingIds.isEmpty {
            let missingSet = Set(missingIds)
            let staged = NSEDataBridge.latestStagedRows.withLock { rows in
                rows.filter { missingSet.contains($0.headerId) }
            }
            for row in staged { byId[row.headerId] = row.toMessageHeader() }
        }
        // Preserve caller's id order; ids that resolved to nothing are dropped.
        return ids.compactMap { byId[$0] }
    }

    /// Singular convenience over `resolveHeadersForAction(ids:)` for single-message actions.
    func resolveHeaderForAction(id: String) async -> MessageHeader? {
        await resolveHeadersForAction(ids: [id]).first
    }

    /// PORT of `v2final:AccountManager.announceIdentityRefusedIds` (F9): post
    /// `.inboxDataDidChange` with the refused ids so a row this call already hid
    /// behind an optimistic overlay repaints at its real position instead of
    /// staying hidden until some unrelated reload.
    ///
    /// This is the SURFACING half of a fail-closed identity refusal, and it is not
    /// optional: refusing silently would convert a wrong-message mutation into a
    /// user-invisible no-op, which the never-drop rule forbids just as strongly.
    /// The other half is the caller's own report (the agent tools' `failed_ids` /
    /// `identity_changed_ids`; `UndoService.undo`'s own empty-restore post).
    ///
    /// Fire-and-forget off the calling context, matching every other
    /// `NotificationCenter.default.post` bridge in this file.
    nonisolated static func announceIdentityRefusedIds(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let payload = Array(ids)
        Task { @MainActor in
            NotificationCenter.default.post(name: .inboxDataDidChange, object: payload)
        }
    }

    // MARK: - T1.3 — an unknown folder epoch fails CLOSED for new gestures

    /// Whether a NEW user gesture against `folderPath` must be REFUSED because that
    /// folder's UIDVALIDITY epoch is not yet known. Callers must treat `true` as a
    /// **silent no-op** (owner decision §9 D6(a)): no op row, no local mutation, no
    /// error surfaced to the user.
    ///
    /// ⚑ NO REFERENCE — INVENTED.
    /// The `v2final` reference deliberately does the OPPOSITE. Its
    /// `observedUidValidityStampForTokenAdmission`
    /// (`v2final:TabMail/Services/Account/AccountManagerQueue.swift:837`) returns a
    /// nil stamp on an unobserved epoch, which then skips the claim-time check, the
    /// in-flight slot publish and the ledger compare — it fails **OPEN**, and records
    /// that as an accepted residual: *"virgin-folder fail-open is bounded by
    /// seed-write latency"* (`v2final:Companion/Decisions/Active/adr-ios-061.md:38`).
    /// That was only tenable because v2 carried an ADMISSION-TIME epoch mechanism:
    /// the claim-time stamp, the in-flight slot publish and the ledger compare above,
    /// backed by the memory-side mirror (`uidValidityLedgerBox`,
    /// `recordObservedUidValidity`, `stampUidValidityLedgerAfterReset`). v3
    /// deliberately omits that mirror — every v3 consumer holds a `Database` and
    /// reads `Folder.lastKnownUidValidity` directly, so there is no synchronous
    /// compare needing a memory copy (see the DELIBERATE OMISSIONS list on
    /// `AccountManager.runUidValidityResetReaction`) — so v3 is deliberately
    /// stronger here and refuses.
    ///
    /// ⚠️ **THIS SAID "v3 has NEITHER" (an epoch ledger NOR a purge-and-resync
    /// reaction) UNTIL R14-F6, AND THE SECOND HALF WAS FALSE.** v3 HAS the reaction:
    /// `AccountManager.runUidValidityResetReaction`
    /// (`AccountManagerUidValidityReset.swift`), driven from FIVE production call
    /// sites — `AccountManager.scheduleUidValidityResetReaction`,
    /// `SyncEngineFullSync`, `SyncEngineDeltaSync`, `SyncEngineEpochVerify`, and its
    /// own in-file re-drive. A compound absolute is false when EITHER half is, and
    /// this one sent readers looking for a reaction that has been there all along.
    ///
    /// **The refusal does not depend on the corrected half, which is why the
    /// disposition is unchanged and must stay unchanged.** The reaction repairs
    /// LOCAL rows after a turnover has been detected — it purges and resyncs. It
    /// cannot un-send a STORE or a COPY that already addressed the wrong message on
    /// the server, and that is the whole hazard here (C3, spelled out below). So the
    /// refusal rests on C3 alone; "v3 lacks a reaction" was never load-bearing for
    /// it and was merely wrong.
    ///
    /// **This deliberately drops one user intention, which this repo's core
    /// philosophy otherwise forbids. Do NOT "fix" it back to fail-open.** The owner
    /// authorised the trade (§9 D6, 2026-07-30): failing closed is always acceptable,
    /// and constraint C3 — *never mutate the wrong message* — is the one hard
    /// invariant. `MessageHeader.stableId` falls back to the bare numeric UID for any
    /// header with no `rfc822MessageId`, and native IMAP actions address that
    /// numeric UID directly. Admitting against a folder whose epoch is unknown
    /// can therefore apply that UID under a DIFFERENT epoch and STORE/COPY over an
    /// unrelated message — exactly C3.
    ///
    /// What makes the trade acceptable is that the window is **BOUNDED to the first
    /// sync of a folder**. T1.2b (`7c71f6c7b`) persists the epoch from the
    /// `Mailbox.Selection` of SELECTs the sync and folder-open paths already perform,
    /// and `OK [UIDVALIDITY n]` is core IMAP4rev1 — NOT a UIDPLUS extension — so even
    /// a server that never answers a UIDVALIDITY STATUS still reports one on SELECT.
    /// So nil means "the first sync has not finished yet", never "this server does not
    /// do UIDVALIDITY". Recorded for users as `IOS-EPOCH-001` in `KNOWN_ISSUES.md`.
    /// ⛔ A synthesized/fake epoch was PROPOSED AND REJECTED by the owner (2026-07-30):
    /// it would disable the check globally to paper over a case SELECT already covers.
    ///
    /// 🚨 **PROVIDER-SCOPED ON PURPOSE — never widen this to "the column is nil".**
    /// `Folder.lastKnownUidValidity` is nil FOREVER on Gmail and Exchange: UIDVALIDITY
    /// is an IMAP concept, and neither the Gmail nor the Graph provider ever populates
    /// `FolderInfo.uidValidity`, so nothing ever writes that column for their folders.
    /// Keying the refusal off the column alone would silently no-op every action on
    /// every Gmail and Exchange account permanently — a bricked app, not a bounded
    /// window. The partition below mirrors `EmailProvider.staleWindowMode` (`.uid` for
    /// IMAP, `.date` for Gmail/Exchange), expressed against the `Account` row because
    /// admission runs inside a write transaction with no provider instance in hand.
    /// `.icloud` IS an IMAP account and MUST stay in the set — several sync sites test
    /// `.imap` alone and wrongly exclude it; do not copy those.
    ///
    /// 🚨 **THE PROVIDER COLUMN IS A PROXY FOR "IS THIS ACCOUNT IMAP-BACKED", AND THE
    /// DEMO ACCOUNT BREAKS IT.** `DemoSeed.seedAccount` stores `provider: .imap`, but
    /// the account is served by `DemoProvider` — pure GRDB, no network, no SELECT, so
    /// nothing can EVER stamp `lastKnownUidValidity` on a demo folder. Without the
    /// exclusion below, every guarded gesture in Demo Mode is refused forever: archive,
    /// delete, move, mark read/unread, flag and all three label paths become silent
    /// no-ops. That is a permanent brick, not a bounded first-sync window — the exact
    /// shape the Gmail/Exchange scoping above exists to prevent, reached through a
    /// different door. The exclusion is placed HERE rather than papered over by seeding
    /// a synthetic epoch in `DemoSeed`: this predicate's one idea is *"does this
    /// account address messages by epoch-scoped UID?"*, and `DemoProvider` does not, so
    /// excluding it CORRECTS the proxy instead of feeding it a value that would make
    /// `Folder.lastKnownUidValidity` (documented as "the UIDVALIDITY the server last
    /// reported") lie for an account that has no server. A seeded epoch would also
    /// silently re-brick the moment demo seeding changed. Comparing against
    /// `DemoSeed.demoAccountId` is this repo's established idiom for the demo carve-out
    /// — `AccountManager.setupOAuthAccount`, `AccountManager.addIMAPAccount` and
    /// `AccountManager.addICloudAccount` each guard on `acct.id != DemoSeed.demoAccountId`,
    /// and so do all three in `v2final`. (Those three live in the FILE
    /// `AccountManagerSetup.swift`, which is an `extension AccountManager`; there is
    /// no `AccountManagerSetup` type to cite.)
    ///
    /// The COMPLETE class this exclusion closes. Only two of the five providers are in
    /// the predicate at all (`.imap`, `.icloud`), so the class is "stored as IMAP-family
    /// but not backed by a live `IMAPProvider`". EIGHT sites, not seven:
    /// `setupOAuthAccount` (`.gmail`/`.outlook` — excluded by provider),
    /// `addIMAPAccount` (`.imap`, real IMAP — the intended bounded window),
    /// `addICloudAccount` (`.icloud`, real IMAP — same), `addCalDAVAccount` (`.caldav`,
    /// `calendarOnly` — NOT in the predicate, and it owns no mail folders, so it is
    /// doubly exempt), the two `CalendarSetupView` sites (`.gmail`/`.outlook`,
    /// `calendarOnly` — excluded by provider), `PreviewMocks`, `ScreenshotMode`, and
    /// `DemoSeed` (`.imap`, `DemoProvider` — the one real member, closed below).
    ///
    /// ⚠ TWO CORRECTIONS TO AN EARLIER VERSION OF THIS CENSUS, both worth keeping
    /// visible because each was a method error, not a typo:
    ///
    /// (a) It listed SEVEN sites and MISSED `ScreenshotMode` (`ScreenshotMode.swift`),
    /// which inserts an account with `provider = "imap"` and its folders by RAW SQL —
    /// `INSERT INTO folder (id, accountId, name, path, role, unreadCount, totalCount,
    /// backfillComplete)`, no `lastKnownUidValidity` column — so those folders are
    /// nil-epoch forever with no server that could ever stamp them. It was missed
    /// because the census was taken with an `rg 'Account\('` sweep, which only finds
    /// Swift literal initialisers; that is the SAME search shape that missed `DemoSeed`
    /// in the previous round. A census of "who can produce this state" must sweep the
    /// SQL too. It is currently INERT — every message `ScreenshotMode` seeds targets
    /// `screenshot-account`, which is `.gmail` and therefore excluded by provider, so
    /// no gesture ever reaches a nil-epoch `screenshot-imap` folder — and it is a
    /// screenshot-fixture path that never runs in a shipped session. But it is one
    /// message-seed away from a second Demo-Mode-shaped brick, so it is named here
    /// rather than left to be rediscovered.
    ///
    /// (b) It dismissed `PreviewMocks` as "never inserted into the shared database".
    /// That is FALSE: `PreviewMocks.bootstrapAppDatabase` installs a pool INTO
    /// `AppDatabase.shared` and `PreviewMocks.seedInbox` writes an `.imap` account plus
    /// a nil-epoch INBOX through it. The conclusion (no production brick) survives, but
    /// the reason is different and must be stated correctly: the pool it installs is an
    /// EPHEMERAL per-invocation temp-directory database, and `PreviewMocks` is compiled
    /// for and reached only from `#Preview` bodies in the Xcode canvas — no shipped
    /// session executes it, and nothing it writes outlives the preview process.
    ///
    /// A MISSING `Folder` ROW FAILS **CLOSED** for the IMAP family. It is not a benign
    /// unknown: `SyncEngine.fullSync` deletes a vanished folder's row while RETAINING
    /// its headers (there is no foreign key — see the NOTE above its `folder.delete(db)`
    /// in the FILE `SyncEngineFullSync.swift`, which is an `extension SyncEngine`; there
    /// is no `SyncEngineFullSync` type to cite),
    /// so an orphaned header keeps a `folderId`/`folderPath` with no metadata, and a
    /// later re-appearance of the same path re-adopts it under a brand-new row whose
    /// epoch is nil. Admitting a gesture on such a header writes a bare UID from the OLD
    /// epoch into a durable op — precisely C3. Orphans are reachable by real gestures
    /// (the notification path queries `messageHeader` without joining `folder`).
    /// This does NOT brick the two callers that used to justify the fail-open:
    /// `UserLabelMenuModel.applyLabel(_:)` / `removeLabel(_:)` (in the file
    /// `UserLabelMenuView.swift`) now resolve the header INSIDE their own admission
    /// write transaction and abort when it is missing — strictly stronger than the
    /// `resolvedFolderPath()` helper they replaced (T4.V13), which returned `nil`
    /// instead of guessing `"INBOX"` but still read the header in an EARLIER
    /// transaction, so a MOVE landing between the two could name the folder the
    /// message had already left. That helper no longer exists. And the
    /// draft sites consult this guard only when the op will actually resolve an EXISTING
    /// UID (see `queueDraftSave`), so a FIRST save on an account with no drafts-role row
    /// — the one save that must not be refused, because nothing else can create the
    /// server copy — is classified APPEND-only and never reaches here.
    ///
    /// ⚠ That last clause used to read "…which cannot be true on an account that has no
    /// drafts-role row to have synced through", i.e. it asserted a numeric
    /// `serverDraftId` is IMPOSSIBLE without a `Folder` row. FALSE, and the false form
    /// is the more dangerous one because it invites removing the guard: nothing about
    /// APPENDing into a real server mailbox named "Drafts" and persisting the UID
    /// `IMAPProvider.saveDraft` returns creates a `Folder` row — only
    /// `SyncEngine.fullSync`'s folder-list upsert does. So a LATER save on such an
    /// account CAN be numeric and CAN be refused here. It is transient (the next folder
    /// list creates the row) and fail-closed, and the user's content is never at risk —
    /// the local `Draft` row is untouched.
    ///
    /// Every remaining unknown still fails **OPEN** (returns `false` = admit): a missing
    /// account row and a non-IMAP-family provider.
    nonisolated static func newGestureRefusedForUnknownEpoch(
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> Bool {
        guard let account = try Account.fetchOne(db, key: accountId) else { return false }
        // Account-side mirror of `staleWindowMode == .uid`. `.icloud` is IMAP.
        guard account.provider == .imap || account.provider == .icloud else { return false }
        // Stored as `.imap`, served by `DemoProvider` — no server, no epoch, ever.
        guard accountId != DemoSeed.demoAccountId else { return false }
        guard let folder = try Folder.fetchOne(db, key: "\(accountId):\(folderPath)") else {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] T1.3 refusing new gesture — no folder row for '\(folderPath)' (orphaned header? account \(accountId.prefix(8)))")
            }
            return true
        }
        // T4.S6 — a folder mid UIDVALIDITY reset is the SAME condition this guard
        // already refuses, reached from the other side: `lastKnownUidValidity` still
        // holds an epoch, but it is the one the server has ABANDONED, so a UID
        // resolved against it addresses whichever message the new numbering put
        // there. Refusing here is what makes the drain-side park meaningful — a
        // gesture admitted between the reaction's step 1 (arm) and step 5 (stamp)
        // would be dropped by the stamp transaction's address-only sweep, i.e. it
        // would silently vanish; refusing it instead keeps the failure visible at
        // the point of action. TRANSIENT: bounded by the reaction, which full sync
        // re-drives on every cycle.
        if folder.uidValidityResetPendingAt != nil {
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] T4.S6 refusing new gesture — folder '\(folderPath)' is mid UIDVALIDITY reset (account \(accountId.prefix(8)))")
            }
            return true
        }
        guard folder.lastKnownUidValidity == nil else { return false }
        if DebugModeManager.isLoggingEnabled() {
            print("[Queue] T1.3 refusing new gesture — folder '\(folderPath)' has no known UIDVALIDITY epoch yet (account \(accountId.prefix(8)))")
        }
        return true
    }

    /// The UIDVALIDITY a NEW gesture admitted in THIS transaction must record on
    /// its `PendingOperation`, or `nil` for a provider family that does not
    /// address messages by epoch-scoped UID (Gmail, Graph, Demo).
    ///
    /// Call it immediately after `newGestureRefusedForUnknownEpoch` returned
    /// `false`, in the SAME write transaction: that guard PROVES the epoch is
    /// known for the IMAP family, and this reads the value it proved. Splitting
    /// the proof from the recording is what produced audit finding A-1 — the
    /// notification cold path called the guard and then inserted the op without
    /// the stamp, so checkpoint A deleted the op for lacking exactly the datum
    /// admission had just established.
    ///
    /// Same provider classification as `admittedOrdinaryActionTargets` and
    /// `roleMoveRejectDispositions` below (`.imap`/`.icloud`, minus the Demo
    /// account, which is stored as IMAP but served by `DemoProvider`).
    nonisolated static func admissionEpochForNewGesture(
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> Int? {
        guard let account = try Account.fetchOne(db, key: accountId) else { return nil }
        guard account.provider == .imap || account.provider == .icloud else { return nil }
        guard accountId != DemoSeed.demoAccountId else { return nil }
        guard let folder = try Folder.fetchOne(
            db, key: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)),
              let epoch = folder.lastKnownUidValidity,
              let epochUInt = UInt32(exactly: epoch), epochUInt > 0 else { return nil }
        return epoch
    }

    /// T2.4 provider-address admission. This is the v3 provider-ID adaptation
    /// of the inverse re-key in v2final commit `a75196398`: ordinary actions
    /// persist the provider's native address, while IMAP additionally proves
    /// that every admitted UID belongs to the source folder's current epoch.
    ///
    /// ⚑ NO REFERENCE — INVENTED adaptation after the direct-constructor,
    /// call-site, and history census. v2final has no provider-ID admission
    /// helper because it deliberately re-keyed in the opposite direction.
    ///
    /// `internal` rather than `private`: the user-label producers
    /// (`UserLabelMenuModel.applyLabel`/`removeLabel`,
    /// `InboxViewModel.removeUserLabel`) and the outbox's
    /// `deleteCompletedSendAtomic` reply/forward flags live in other files and
    /// must admit through this exact predicate. They previously enqueued
    /// `MessageHeader.stableId` — an rfc822 string on IMAP — with no epoch, which
    /// checkpoint A could only ever refuse (audit finding A-6). ⚠ CORRECTED (audit
    /// round 2): the A-6 write-ups described that refusal as the op being "queued
    /// and then deleted unexecuted on the next drain". That was checkpoint A's
    /// behaviour at the time; it now SKIPS an unprovable op rather than deleting it,
    /// because an absence of evidence is not an exit. The accurate description of
    /// the un-admitted shape today is a PERMANENTLY UNCLAIMABLE ROW — never
    /// executed, never retired. The user-visible loss is unchanged, which is why
    /// admitting through this predicate is still the fix.
    nonisolated static func admittedOrdinaryActionTargets(
        _ messages: [MessageHeader],
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> (messages: [MessageHeader], providerIds: [String], observedUidValidity: Int?)? {
        guard let account = try Account.fetchOne(db, key: accountId) else { return nil }

        // Demo is stored as IMAP but is backed by DemoProvider: its local ids are
        // stable and it will never observe a mailbox epoch.
        let isDemo = accountId == DemoSeed.demoAccountId
        let isIMAP = !isDemo && (account.provider == .imap || account.provider == .icloud)
        if !isIMAP {
            let admitted = messages.filter { !$0.messageId.isEmpty }
            guard !admitted.isEmpty else { return nil }
            return (admitted, admitted.map(\.messageId), nil)
        }

        guard let folder = try Folder.fetchOne(
            db, key: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)),
              folder.uidValidityResetPendingAt == nil,
              let liveEpoch = folder.lastKnownUidValidity,
              let liveUInt = UInt32(exactly: liveEpoch), liveUInt > 0 else {
            return nil
        }

        // Fail each unproven on-screen address closed before local mutation.
        // A valid sibling in the same gesture remains actionable; the stale
        // member is omitted rather than contaminating the operation's epoch.
        let admitted = messages.filter { message in
            guard message.observedUidValidity == liveEpoch,
                  let observed = message.observedUidValidity,
                  let observedUInt = UInt32(exactly: observed), observedUInt > 0,
                  let uid = UInt32(message.messageId), uid > 0,
                  message.messageId == String(uid) else {
                return false
            }
            return true
        }
        guard !admitted.isEmpty else { return nil }
        return (admitted, admitted.map(\.messageId), liveEpoch)
    }

    /// Why `admittedOrdinaryActionTargets` did NOT admit each of `rejected`,
    /// expressed as the disposition its caller must report. Reads only; changes
    /// nothing about WHICH messages are admitted — it explains an existing refusal.
    ///
    /// ⚑ NO REFERENCE — INVENTED. `v2final` needs no equivalent: its admission
    /// refusals are produced by the journal fold, which already types every id
    /// (`IntentionPhaseAdmission`). v3 admits inside a plain write transaction
    /// with a `nil`/filtered-out result, so the reason has to be re-derived.
    ///
    /// **EXACTLY ONE ARM IS TERMINAL** — a positive epoch mismatch, i.e. the
    /// folder's `lastKnownUidValidity` (what the server actually reported on
    /// its last SELECT) disagrees with the `observedUidValidity` this row
    /// carries. That is core philosophy §6 exit 4: proven turnover, C3
    /// fail-closed, never retried because every retry would fail identically.
    ///
    /// **EVERY OTHER ARM IS RETRYABLE**, including the ones that look like
    /// permanent refusals:
    ///   * `observedUidValidity == nil` — the row has not been stamped yet.
    ///     An UNREAD epoch is an ABSENCE of evidence, never a mismatch.
    ///   * `lastKnownUidValidity == nil` (T1.3) — the folder's first sync has
    ///     not finished; bounded by that sync.
    ///   * `uidValidityResetPendingAt != nil` (T4.S6) — bounded by the reset
    ///     reaction, which full sync re-drives every cycle.
    ///   * a missing `Folder` or `Account` row — the admission fails closed on
    ///     it, but nothing about it is provider-authoritative.
    ///   * a malformed/empty provider address — a broken LOCAL row, which is
    ///     also not the provider telling us anything.
    /// Widening the terminal arm to any of these would drop a user intention
    /// on an unknown, which is exactly what exit 4 is written to forbid.
    ///
    /// A6 (database-performance lens): the `Account` and `Folder` rows are the
    /// SAME for every member of a group, so they are read ONCE per group, not
    /// once per message — two keyed primary-key fetches total, and only on the
    /// refusal path (a fully-admitted group performs zero extra reads).
    private nonisolated static func roleMoveRejectDispositions(
        _ rejected: [MessageHeader],
        accountId: String,
        folderPath: String,
        db: Database
    ) throws -> [String: RoleMoveDisposition] {
        guard !rejected.isEmpty else { return [:] }

        func all(_ disposition: RoleMoveDisposition) -> [String: RoleMoveDisposition] {
            Dictionary(uniqueKeysWithValues: rejected.map { ($0.id, disposition) })
        }

        guard let account = try Account.fetchOne(db, key: accountId) else { return all(.retainedForRetry) }
        let isDemo = accountId == DemoSeed.demoAccountId
        let isIMAP = !isDemo && (account.provider == .imap || account.provider == .icloud)
        // Non-IMAP-family: the only refusal cause is an empty provider id.
        guard isIMAP else { return all(.retainedForRetry) }

        guard let folder = try Folder.fetchOne(
            db, key: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)) else {
            return all(.retainedForRetry)
        }
        guard folder.uidValidityResetPendingAt == nil else { return all(.retainedForRetry) }
        guard let liveEpoch = folder.lastKnownUidValidity,
              let liveUInt = UInt32(exactly: liveEpoch), liveUInt > 0 else {
            return all(.retainedForRetry)
        }

        var result: [String: RoleMoveDisposition] = [:]
        for message in rejected {
            // An UNREAD epoch on the row is an absence of evidence, not a
            // mismatch — the only terminal arm is a POSITIVE disagreement.
            guard let observed = message.observedUidValidity, observed != liveEpoch else {
                result[message.id] = .retainedForRetry
                continue
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[Queue] T4.V8 terminal-stale — '\(folderPath)' epoch moved \(observed) → \(liveEpoch) (account \(accountId.prefix(8)))")
            }
            result[message.id] = .terminalStale
        }
        return result
    }

    // MARK: - Mark-as-Read-on-Archive/Delete Setting (Settings → User Interface)

    /// UserDefaults key for the "Mark as read on archive & delete" toggle.
    /// Governs EVERY archive/delete-to-trash entry point (inbox swipe incl.
    /// thread variants, detail-view, settings bulk archive, agent tools, AND
    /// notification action buttons via `performCoordinatedRoleMove`). The
    /// owner's request (feature round 2026-07-15, `main` line commit
    /// `98bebba7c`) was uniform mark-read on these actions; an audit at the
    /// time showed no path did it before, so all origins now compose the read
    /// intent when this is ON. A move to a user-CHOSEN folder is deliberately
    /// out of scope — this is "I have dealt with this", not "file it".
    static let markReadOnArchiveDeleteKey = "markReadOnArchiveDelete"

    /// Default true (missing key ⇒ ON) — `bool(forKey:)` returns `false` for a
    /// never-set key, which would silently invert a default-ON setting; the
    /// explicit `object(forKey:) == nil` check is the same pattern
    /// `ProactiveNotifyService.isEnabled` uses for its own default-true toggle.
    static var markReadOnArchiveDeleteEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: markReadOnArchiveDeleteKey) == nil { return true }
        return defaults.bool(forKey: markReadOnArchiveDeleteKey)
    }

    /// Compose the mark-as-read-on-archive/delete intent for the UNREAD members
    /// of `messages`.
    ///
    /// 🚨 **MUST be awaited IMMEDIATELY BEFORE the caller's own move, inside the
    /// SAME queued closure. Never in a separate `enqueueWrite`, never in a
    /// detached `Task`, and never reordered "for efficiency".**
    ///
    /// THE ADDRESS PROBLEM (`tabmail-ios/CLAUDE.md`): a `PendingOperation`
    /// addresses its members in the SOURCE folder, and on IMAP an address is
    /// `(folder, UID, UIDVALIDITY)` — a move changes the address. `markRead`
    /// records an op naming the source folderPath and the source epoch, and
    /// `optimisticMoveToFolder` nulls the row's `observedUidValidity` the
    /// instant the move lands. Issue the move first and the read intent either
    /// can never be admitted again (a dropped intention — forbidden) or, on the
    /// wire, addresses whatever now occupies that UID in the source folder —
    /// C3 wrong-message mutation, which nothing recovers.
    ///
    /// Ordering on the wire follows from ordering here: the read op is ADMITTED
    /// first, so it takes the lower `queuePosition` (allocated inside its own
    /// insert transaction, and these are separate strictly sequential write
    /// transactions), and the global single-operation executor claims the live
    /// front row in `queuePosition` order. Nothing about the two ops naming the
    /// same member ids is needed for that — the order is the ADMISSION order,
    /// not a per-lane order, and `createdAt` does not decide it.
    ///
    /// The unread count decrements exactly ONCE: `markRead` decrements
    /// `folder.unreadCount` by its own fresh in-transaction
    /// `countCurrentlyUnread`, and `optimisticMoveToFolder` re-reads `isRead`
    /// from the DB (never a caller snapshot) for its own source/dest delta, so
    /// it sees zero unread moving and adjusts nothing.
    func markReadBeforeRoleMove(_ messages: [MessageHeader]) async {
        guard Self.markReadOnArchiveDeleteEnabled else { return }
        let unread = messages.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        await markRead(unread)
    }

    /// Id-taking variant for the gesture entry points, which hold only a
    /// tap-time `lookupMessage` snapshot (gesture paths are zero-DB on the main
    /// actor). Re-resolves row truth INSIDE the queued closure first — the same
    /// doctrine as `move(_:to:)`'s own re-resolve, and for the same reason: a
    /// second gesture landing before this closure commits would otherwise let
    /// the read op name a folder the message has already left. Ids that no
    /// longer resolve are dropped by `resolveHeadersForAction`'s documented
    /// contract, exactly as they are for the move.
    ///
    /// The setting is checked BEFORE the resolve so an OFF toggle costs no
    /// extra read — pre-feature parity, byte for byte.
    func markReadBeforeRoleMove(ids: [String]) async {
        guard Self.markReadOnArchiveDeleteEnabled else { return }
        let fresh = await resolveHeadersForAction(ids: ids)
        await markReadBeforeRoleMove(fresh)
    }

    func markRead(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    guard let admission = try Self.admittedOrdinaryActionTargets(
                        msgs, accountId: accountId, folderPath: folderPath, db: db) else { continue }
                    let admitted = admission.messages
                    let msgIds = admitted.map(\.id)
                    let folderId = admitted[0].folderId
                    folderIds.insert(folderId)
                    let newlyRead = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: true))
                    if newlyRead > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
                    }
                    var markReadOp = PendingOperation(
                        type: .markRead, messageIds: admission.providerIds,
                        accountId: accountId, folderPath: folderPath,
                        observedUidValidity: admission.observedUidValidity)
                    try markReadOp.insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markRead write failed: \(error)")
            affectedFolderIds = []
        }
        // Clear delivered notifications for messages the user just read
        for msg in messages {
            NSEDataBridge.clearNotification(accountId: msg.accountId, messageId: msg.messageId)
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: the optimistic write above already decremented
        // folder.unreadCount, so the app-icon badge can update NOW (bg-task
        // protected) — without it, a read→immediate-background leaves the badge
        // stale until the next foreground recount.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    func markUnread(_ messages: [MessageHeader]) async {
        await ensureDurable(messages)

        let affectedFolderIds: Set<String>
        do {
            affectedFolderIds = try await dbPool.write { db in
                let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
                var folderIds: Set<String> = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    guard let admission = try Self.admittedOrdinaryActionTargets(
                        msgs, accountId: accountId, folderPath: folderPath, db: db) else { continue }
                    let admitted = admission.messages
                    let msgIds = admitted.map(\.id)
                    // Count unread BEFORE marking unread — fresh DB read to compute delta
                    let folderId = admitted[0].folderId
                    folderIds.insert(folderId)
                    let alreadyUnread = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
                    let newlyUnread = msgIds.count - alreadyUnread
                    try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db, Column("isRead").set(to: false))
                    if newlyUnread > 0 {
                        try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
                    }
                    var markUnreadOp = PendingOperation(
                        type: .markUnread, messageIds: admission.providerIds,
                        accountId: accountId, folderPath: folderPath,
                        observedUidValidity: admission.observedUidValidity)
                    try markUnreadOp.insert(db)
                }
                return folderIds
            }
        } catch {
            print("[Queue] ERROR: markUnread write failed: \(error)")
            affectedFolderIds = []
        }
        // Post immediately from actor for responsive sidebar badges, then async recount for accuracy
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        // notifyImmediately: optimistic write already adjusted folder.unreadCount,
        // so the badge updates NOW (bg-task protected) and survives a quick background.
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds, notifyImmediately: true) }
        Task { await drainPendingQueue() }
    }

    // MARK: - Unread Count Helpers

    /// Count currently-unread messages from the DB inside an active transaction.
    /// Always re-reads from DB to avoid stale-snapshot races (e.g., markRead + move
    /// firing as concurrent Tasks — the second write must see the first's committed state).
    private nonisolated static func countCurrentlyUnread(msgIds: [String], db: Database) throws -> Int {
        guard !msgIds.isEmpty else { return 0 }
        let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
            arguments: StatementArguments(msgIds)) ?? 0
    }

    // MARK: - Optimistic Move (shared by archive, delete, move)

    /// Retain the already-visible optimistic overlay while an in-flight IMAP
    /// predecessor is still producing the UID needed by the opposite move.
    /// Re-registering the same exact member is idempotent and does not take a
    /// second retain.
    private func registerDeferredMoveSuccessors(_ successors: [DeferredMoveSuccessor]) {
        for successor in successors {
            let isNew = deferredMoveSuccessors[successor.oldHeaderId] == nil
            deferredMoveSuccessors[successor.oldHeaderId] = successor
            if isNew { retainOverlayEntry(id: successor.oldHeaderId) }
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager deferred.register "
                    + "id=\(successor.oldHeaderId) "
                    + "predecessor=\(successor.predecessorOperationId.prefix(8)) "
                    + "predecessorDestination=\(successor.predecessorDestinationPath) "
                    + "desiredDestination=\(successor.desiredDestinationPath) "
                    + "newRetain=\(isNew) "
                    + roleActionOverlayDiagnostic(id: successor.oldHeaderId))
        }
    }

    /// Apply latest-move-wins to an opposite waiting behind in-flight IMAP
    /// work. Returning to the predecessor destination cancels the opposite;
    /// any other destination retargets it. Neither case waits for the provider.
    private func coalesceDeferredMoves(
        headerIds: Set<String>, destinationPath: String
    ) -> (ids: Set<String>, admission: RoleMoveAdmission) {
        var ids: Set<String> = []
        var admission = RoleMoveAdmission()
        for headerId in headerIds {
            let candidateIds = [headerId]
                + MessageHeaderRekey.predecessorHeaderIds(leadingTo: headerId)
            guard let successorHeaderId = candidateIds.first(where: {
                deferredMoveSuccessors[$0] != nil
            }),
                  var successor = deferredMoveSuccessors[successorHeaderId]
            else { continue }
            ids.insert(headerId)
            if destinationPath == successor.predecessorDestinationPath {
                deferredMoveSuccessors.removeValue(forKey: successorHeaderId)
                releaseOverlayEntry(id: successorHeaderId)
                admission.set(.durablyAdmitted, id: headerId)
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] manager deferred.coalesce id=\(headerId) "
                        + "successorKey=\(successorHeaderId) "
                        + "decision=cancelSuccessor destination=\(destinationPath) "
                        + roleActionOverlayDiagnostic(id: successorHeaderId))
            } else {
                successor.desiredDestinationPath = destinationPath
                deferredMoveSuccessors[successorHeaderId] = successor
                admission.set(.retainedForRetry, id: headerId)
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] manager deferred.coalesce id=\(headerId) "
                        + "successorKey=\(successorHeaderId) "
                        + "decision=retarget destination=\(destinationPath) "
                        + roleActionOverlayDiagnostic(id: successorHeaderId))
            }
        }
        return (ids, admission)
    }

    #if DEBUG
    func deferredMoveSuccessorCountForTesting() -> Int {
        deferredMoveSuccessors.count
    }

    func clearDeferredMoveSuccessorsForTesting() {
        let retainedIds = Array(deferredMoveSuccessors.keys)
        deferredMoveSuccessors.removeAll()
        for id in retainedIds { releaseOverlayEntry(id: id) }
    }
    #endif

    /// A terminal predecessor without destination evidence cannot safely run
    /// its deferred inverse. Drop that process-local convenience and its
    /// overlay; the normal sync path remains the source of truth.
    func dropDeferredMoveSuccessors(for predecessorOperationId: String) {
        let oldHeaderIds = deferredMoveSuccessors.values.compactMap { successor in
            successor.predecessorOperationId == predecessorOperationId
                ? successor.oldHeaderId
                : nil
        }
        guard !oldHeaderIds.isEmpty else { return }
        for oldHeaderId in oldHeaderIds {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager deferred.drop id=\(oldHeaderId) "
                    + "predecessor=\(predecessorOperationId.prefix(8)) "
                    + roleActionOverlayDiagnostic(id: oldHeaderId))
            deferredMoveSuccessors.removeValue(forKey: oldHeaderId)
            releaseOverlayEntry(id: oldHeaderId)
        }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .inboxDataDidChange, object: oldHeaderIds)
        }
    }

    /// Turn an opposite gesture recorded during an in-flight IMAP MOVE into an
    /// ordinary queued move only after the provider has named the destination
    /// UID. The predecessor has already been retired in the same transaction
    /// that produced `result`, so this reuses the normal optimistic-move path;
    /// there is no second queue, guessed UID, Message-ID search or migration.
    func materializeDeferredMoveSuccessors(
        after predecessor: PendingOperation,
        result: MoveFinishResult
    ) async {
        await enqueueWriteAfterPriorAdmissions { [self, predecessor, result] in
            await materializeDeferredMoveSuccessorsInFIFO(
                after: predecessor, result: result)
        }
    }

    private func materializeDeferredMoveSuccessorsInFIFO(
        after predecessor: PendingOperation,
        result: MoveFinishResult
    ) async {
        let waiting = deferredMoveSuccessors.values.filter {
            $0.predecessorOperationId == predecessor.id
        }
        guard !waiting.isEmpty else { return }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager deferred.materialize.begin "
                + "predecessor=\(predecessor.id.prefix(8)) "
                + "waiting=[\(waiting.map(\.oldHeaderId).joined(separator: ","))]")
        for successor in waiting {
            deferredMoveSuccessors.removeValue(forKey: successor.oldHeaderId)
        }

        let appliedByOldId = Dictionary(
            result.applied.map { ($0.oldHeaderId, $0) },
            uniquingKeysWith: { first, _ in first })
        let rowsByOldId: [String: MessageHeader] = (try? await dbPool.read { db in
            var rows: [String: MessageHeader] = [:]
            for successor in waiting {
                guard let record = appliedByOldId[successor.oldHeaderId],
                      let row = try MessageHeader.fetchOne(db, key: record.newHeaderId),
                      row.accountId == predecessor.accountId,
                      row.folderPath == predecessor.destinationPath,
                      row.messageId == record.newProviderMessageId
                else { continue }
                rows[successor.oldHeaderId] = row
            }
            return rows
        }) ?? [:]

        for (destinationPath, successors) in Dictionary(
            grouping: waiting, by: \.desiredDestinationPath
        ) {
            let rows = successors.compactMap { rowsByOldId[$0.oldHeaderId] }
            guard rows.count == successors.count else {
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] manager deferred.materialize.refused "
                        + "predecessor=\(predecessor.id.prefix(8)) "
                        + "destination=\(destinationPath) "
                        + "resolved=\(rows.count)/\(successors.count)")
                continue
            }
            let admission = await move(rows, to: destinationPath)
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager deferred.materialize.admission "
                    + "predecessor=\(predecessor.id.prefix(8)) "
                    + "destination=\(destinationPath) "
                    + "outcome=\(admission.diagnosticSummary)")
        }

        // The forward is already retired. Any inverse that could not be
        // admitted is deliberately dropped; the next sync exposes server truth.
        let completedOldIds = waiting.map(\.oldHeaderId)
        for oldId in completedOldIds {
            releaseOverlayEntry(id: oldId)
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager deferred.materialize.end "
                + "predecessor=\(predecessor.id.prefix(8)) "
                + "released=[\(completedOldIds.joined(separator: ","))]")

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .inboxDataDidChange, object: completedOldIds)
        }
    }

    /// Core optimistic move: reassigns messages to the destination folder in GRDB,
    /// queues tag removal if leaving inbox, and queues the PendingOperation.
    /// Unread counts are adjusted inline (same transaction) for immediate UI feedback.
    /// UnreadCountManager async recount serves as safety net.
    /// Post-drain sync reconciles UIDs via stale detection + UID remap.
    ///
    /// Gmail-specific: archive destination is the synthetic "__GMAIL_ALL_MAIL__" folder;
    /// the provider-level archive just removes the INBOX label. The optimistic folder
    /// assignment works the same regardless.
    /// Returns the set of affected folder IDs (source + destination) for unread recount,
    /// plus the per-id `(admitted, pending, failed)` disposition (T4.V8): every id in
    /// `msgs` that this call does NOT durably admit is classified by
    /// `roleMoveRejectDisposition` so no caller can mistake a refusal for success.
    /// ⚠️ The `admission` half is only meaningful when the ENCLOSING transaction
    /// commits — a later throw rolls the `PendingOperation` insert back with it, so
    /// `move()`'s catch re-classifies the whole batch rather than trusting a partial.
    @discardableResult
    private nonisolated static func optimisticMoveToFolder(
        msgs: [MessageHeader],
        accountId: String,
        folderPath: String,
        destinationPath: String,
        opType: OperationType,
        removeTagsIfLeavingInbox: Bool,
        db: Database
    ) throws -> (
        folderIds: Set<String>, admission: RoleMoveAdmission,
        deferredSuccessors: [DeferredMoveSuccessor]
    ) {
        var outcome = RoleMoveAdmission()
        // Self-move is a no-op — don't create PendingOperation or touch local state.
        // Happens when archiving from All Mail on Gmail (source=dest=__GMAIL_ALL_MAIL__).
        guard folderPath != destinationPath else {
            print("[Queue] Skipping no-op move (source==dest): \(folderPath)")
            // PROVEN: the row already sits at the requested destination, so the
            // requested end state is already true. Terminal, never retried.
            outcome.set(.terminalStale, ids: msgs.map(\.id))
            return ([], outcome, [])
        }

        // 1.6.38 GUARD, PORTED TO PROVIDER-NATIVE ADDRESSING.
        //
        // A queued opposite move has not reached the provider, so the latest
        // gesture may annihilate it and restore the exact source address it
        // already carries. If it is in flight, the source UID will change and
        // cannot be guessed; retain an in-memory successor until COPYUID proves
        // the new address. The strict whole-bundle match prevents a partial or
        // unrelated operation sharing one UID from being folded.
        if opType == .move, !msgs.isEmpty {
            let ids = msgs.map(\.messageId)
            let idSet = Set(ids)
            let activeMoves = try PendingOperation
                .filter(Column("accountId") == accountId)
                .filter(Column("type") == OperationType.move.rawValue)
                .filter(Column("status") != PendingStatus.cancelled.rawValue)
                .fetchAll(db)
            let related = activeMoves.filter {
                !Set($0.messageIds).isDisjoint(with: idSet)
            }
            let exactOpposites = related.filter { op in
                op.messageIds.count == ids.count
                    && Set(op.messageIds) == idSet
                    && op.destinationPath == folderPath
                    && op.folderPath == destinationPath
                    && msgs.allSatisfy { message in
                        message.id == MessageIdentity.headerId(
                            accountId: accountId, folderPath: op.folderPath,
                            messageId: message.messageId)
                    }
            }
            if related.count == 1, exactOpposites.count == 1 {
                let predecessor = exactOpposites[0]
                if predecessor.status == PendingStatus.queued.rawValue,
                   !predecessor.everAttempted {
                    let sourceFolderId = msgs[0].folderId
                    let destinationFolderId = MessageIdentity.folderId(
                        accountId: accountId, folderPath: destinationPath)
                    let destinationFolder = try Folder.fetchOne(db, key: destinationFolderId)
                    let destinationIsInbox = destinationFolder?.role == .inbox
                    let unreadMoving = try Self.countCurrentlyUnread(
                        msgIds: msgs.map(\.id), db: db)

                    var assignments: [ColumnAssignment] = [
                        Column("folderId").set(to: destinationFolderId),
                        Column("folderPath").set(to: destinationPath),
                        Column("isInInbox").set(to: destinationIsInbox),
                        Column("observedUidValidity").set(to: predecessor.observedUidValidity),
                    ]
                    if removeTagsIfLeavingInbox && msgs[0].isInInbox {
                        assignments.append(Column("actionTag").set(to: nil as String?))
                        assignments.append(Column("tagSortOrder").set(to: 99))
                    }
                    try MessageHeader
                        .filter(msgs.map(\.id).contains(Column("id")))
                        .updateAll(db, assignments)
                    _ = try PendingOperation.deleteOne(db, key: predecessor.id)

                    try Self.restoreInboxAICacheAfterOptimisticMove(
                        headerIds: msgs.map(\.id), accountId: accountId,
                        destinationPath: destinationPath,
                        destinationIsInbox: destinationIsInbox == true, db: db)
                    if unreadMoving > 0 {
                        try db.execute(
                            sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?",
                            arguments: [unreadMoving, sourceFolderId])
                        try db.execute(
                            sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?",
                            arguments: [unreadMoving, destinationFolderId])
                    }
                    outcome.set(.durablyAdmitted, ids: msgs.map(\.id))
                    return ([sourceFolderId, destinationFolderId], outcome, [])
                }

                if predecessor.status == PendingStatus.inFlight.rawValue,
                   predecessor.observedUidValidity != nil {
                    let successors = msgs.map { message in
                        DeferredMoveSuccessor(
                            predecessorOperationId: predecessor.id,
                            predecessorDestinationPath: folderPath,
                            oldHeaderId: message.id,
                            desiredDestinationPath: destinationPath)
                    }
                    outcome.set(.retainedForRetry, ids: msgs.map(\.id))
                    return ([], outcome, successors)
                }
            }
        }

        // Capture the source-native ids and epoch before the optimistic move
        // clears `observedUidValidity` on the destination row.
        let admissionResult = try Self.admittedOrdinaryActionTargets(
            msgs, accountId: accountId, folderPath: folderPath, db: db)
        let admittedIds = Set((admissionResult?.messages ?? []).map(\.id))
        let rejectDispositions = try Self.roleMoveRejectDispositions(
            msgs.filter { !admittedIds.contains($0.id) },
            accountId: accountId, folderPath: folderPath, db: db)
        for (id, disposition) in rejectDispositions { outcome.set(disposition, id: id) }
        guard let admission = admissionResult else { return ([], outcome, []) }
        let admitted = admission.messages
        let leavingInbox = admitted[0].isInInbox

        // Optimistic local update — move to destination folder immediately.
        // Message appears in destination right away; post-drain sync reconciles UIDs.
        let destFolderId = "\(accountId):\(destinationPath)"
        let destFolder = try Folder.fetchOne(db, key: destFolderId)
        let destIsInbox = destFolder?.role == .inbox

        let msgIds = admitted.map(\.id)
        // Tags are local-only (ADR-IOS-036) — there is no server-side keyword
        // to remove, so leaving the inbox clears `actionTag` in THIS write
        // (same statement as the folder move) instead of queuing a
        // PendingOperation. `tagSortOrder = 99` mirrors the "no tag" sentinel
        // `sweepStaleActionTags` writes (SyncEngineMaintenance.swift) and the
        // `MessageHeader.tagSortOrder` column default — same value, same
        // meaning, so a message that leaves the inbox and one the periodic
        // sweep later catches converge on identical local state.
        if removeTagsIfLeavingInbox && leavingInbox {
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: destIsInbox),
                Column("observedUidValidity").set(to: nil as Int?),
                Column("actionTag").set(to: nil as String?),
                Column("tagSortOrder").set(to: 99)
            )
        } else {
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(db,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: destIsInbox),
                Column("observedUidValidity").set(to: nil as Int?)
            )
        }

        // Returning to Inbox should reuse the durable AI result already keyed
        // to the Inbox content identity. The old implementation waited for a
        // later queue sweep, leaving actionTag nil (and the UI spinning) even
        // when the cache was warm. This stays inside the same transaction as
        // the optimistic move, so the row is never briefly published as an
        // uncached Inbox message.
        try Self.restoreInboxAICacheAfterOptimisticMove(
            headerIds: msgIds,
            accountId: accountId,
            destinationPath: destinationPath,
            destinationIsInbox: destIsInbox == true,
            db: db)

        // Inline unread count update — fresh DB read, not stale snapshot.
        // Re-read isRead from DB to avoid double-decrement when markRead + move race.
        let unreadMoving = try Self.countCurrentlyUnread(msgIds: msgIds, db: db)
        if unreadMoving > 0 {
            let sourceFolderId = admitted[0].folderId
            try db.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
            try db.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
        }

        var queuedOp = PendingOperation(
            type: opType, messageIds: admission.providerIds,
            accountId: accountId, folderPath: folderPath,
            destinationPath: destinationPath,
            observedUidValidity: admission.observedUidValidity)
        try queuedOp.insert(db)
        print("[Queue] Queued \(opType.rawValue) for \(admission.providerIds.count) msgs: \(folderPath) → \(destinationPath) (account: \(accountId))")
        // The local mutation and the durable op are now in the SAME open
        // transaction — that is exactly what `durablyAdmitted` asserts.
        outcome.set(.durablyAdmitted, ids: admittedIds)
        return ([admitted[0].folderId, destFolderId], outcome, [])
    }

    /// Restore missing AI fields only for rows that the enclosing optimistic
    /// transaction has actually moved into Inbox. Internal for executable
    /// regression coverage; it is not a second move path.
    nonisolated static func restoreInboxAICacheAfterOptimisticMove(
        headerIds: [String],
        accountId: String,
        destinationPath: String,
        destinationIsInbox: Bool,
        db: Database
    ) throws {
        guard destinationIsInbox else { return }
        for headerId in headerIds {
            guard var header = try MessageHeader.fetchOne(db, key: headerId),
                  header.accountId == accountId,
                  header.folderPath == destinationPath,
                  header.isInInbox
            else { continue }
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: accountId,
                folderPath: destinationPath,
                db: db)
            try header.update(db)
        }
    }

    /// T4.V8: returns the per-id `(admitted, pending, failed)` triple. Existing
    /// gesture callers (`InboxViewModel`, `MessageDetailViewModel`, `SettingsView`)
    /// legitimately ignore it, hence `@discardableResult`; the coordinated agent-tool
    /// and notification paths consume it so they stop reporting success for work that
    /// never reached the provider.
    @discardableResult
    func move(_ messages: [MessageHeader], to destinationPath: String) async -> RoleMoveAdmission {
        var outcome = RoleMoveAdmission()
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager.move phase=begin destination=\(destinationPath) "
                + "members=[\(messages.map { "\($0.id){\($0.folderPath)}" }.joined(separator: ","))] "
                + "deferredCount=\(deferredMoveSuccessors.count)")

        // If Undo already recorded the exact opposite behind an in-flight
        // predecessor, a new gesture back to the predecessor's destination is
        // the net cancel-out. Fold it before re-resolving the deliberately
        // optimistic row (whose durable folder still reflects the predecessor).
        let requestedIds = Set(messages.map(\.id))
        let coalesced = coalesceDeferredMoves(
            headerIds: requestedIds, destinationPath: destinationPath)
        outcome.merge(coalesced.admission)
        let remainingMessages = messages.filter { !coalesced.ids.contains($0.id) }
        guard !remainingMessages.isEmpty else {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.move phase=coalescedAll "
                    + "destination=\(destinationPath) outcome=\(outcome.diagnosticSummary)")
            return outcome
        }

        // Re-resolve fresh headers by id — the single choke point for every
        // surface (swipe, detail view, agent tools, settings bulk-archive).
        // Gesture paths capture `lookupMessage` snapshots at tap time and pass
        // them into queued closures; a second destination-changing gesture on
        // the same message before the first closure commits would otherwise
        // record a PendingOperation against the STALE source folderPath (on
        // IMAP the drain would otherwise carry the prior source observation.
        // The write acts on row truth at execution time — same doctrine as
        // `performCoordinatedRoleMove`'s in-closure re-resolve, which stays
        // as-is (its double resolve is harmless). Ids that no longer resolve
        // (vanished rows) are dropped from the batch — correct, per
        // `resolveHeadersForAction`'s documented contract.
        let unresolvedIds = remainingMessages.map(\.id)
        let fresh = await resolveHeadersForAction(ids: unresolvedIds)
        // Observability (audit round 5): resolveHeadersForAction swallows read
        // errors (`try?` → []), so an empty result for a NON-empty input is
        // either all-rows-vanished (legit) or a genuine read failure — in the
        // latter case this drop is the only trace the gesture ever existed.
        // Distinguishing the two needs a throwing resolve variant — recorded
        // as a phase-2 consideration in PLAN_OVERLAY_CALLSITE_AUDIT.md §6.
        //
        // T4.V8: because those two causes are NOT distinguishable here, an id
        // the resolve dropped is `retainedForRetry`, never `terminalStale` —
        // a swallowed read failure is an unknown, and this is the gesture path
        // (zero-extra-DB contract), so the probe that CAN prove absence lives
        // in `performCoordinatedRoleMove` instead, which is a non-gesture path.
        let freshIds = Set(fresh.map(\.id))
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager.move phase=resolved destination=\(destinationPath) "
                + "requested=[\(unresolvedIds.joined(separator: ","))] "
                + "fresh=[\(fresh.map { "\($0.id){\($0.folderPath)}" }.joined(separator: ","))]")
        outcome.set(.retainedForRetry, ids: unresolvedIds.filter { !freshIds.contains($0) })
        if fresh.isEmpty, !remainingMessages.isEmpty {
            print("[Queue] WARNING: move(to: \(destinationPath)) resolved 0 of \(remainingMessages.count) ids — vanished rows or read failure; nothing queued")
        }
        // Same-folder move is a no-op. Drop those messages here — using FRESH
        // data so a stale caller snapshot whose row already sits at the
        // destination (e.g. an earlier queued move already landed it there)
        // is correctly filtered instead of queuing a pointless/incorrect
        // PendingOperation whose server-side MOVE has provider-dependent
        // effects (e.g. archive-from-Archive).
        let movable = fresh.filter { $0.folderPath != destinationPath }
        // PROVEN: already at the destination, so the requested end state holds.
        outcome.set(.terminalStale, ids: fresh.filter { $0.folderPath == destinationPath }.map(\.id))
        guard !movable.isEmpty else {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.move phase=noMovable destination=\(destinationPath) "
                    + "outcome=\(outcome.diagnosticSummary)")
            return outcome
        }
        await ensureDurable(movable)

        let grouped = Dictionary(grouping: movable) { "\($0.accountId)|\($0.folderPath)" }
        let affectedFolderIds: Set<String>
        let deferredSuccessors: [DeferredMoveSuccessor]
        do {
            let written = try await dbPool.write { db -> (
                folderIds: Set<String>, admission: RoleMoveAdmission,
                deferredSuccessors: [DeferredMoveSuccessor]
            ) in
                var folderIds: Set<String> = []
                var admission = RoleMoveAdmission()
                var deferredSuccessors: [DeferredMoveSuccessor] = []
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    let moved = try Self.optimisticMoveToFolder(msgs: msgs, accountId: accountId, folderPath: folderPath, destinationPath: destinationPath, opType: .move, removeTagsIfLeavingInbox: true, db: db)
                    folderIds.formUnion(moved.folderIds)
                    admission.merge(moved.admission)
                    deferredSuccessors.append(contentsOf: moved.deferredSuccessors)
                }
                return (folderIds, admission, deferredSuccessors)
            }
            affectedFolderIds = written.folderIds
            deferredSuccessors = written.deferredSuccessors
            outcome.merge(written.admission)
        } catch {
            print("[Queue] ERROR: move write failed: \(error)")
            affectedFolderIds = []
            deferredSuccessors = []
            // The transaction rolled back, so NOTHING landed for ANY member —
            // including groups that had already produced a `durablyAdmitted`
            // classification inside the closure (whose return value is
            // discarded on throw and therefore never reaches `outcome`).
            // A failed durable write is retryable, never authoritative
            // (core philosophy §6, exit 2).
            outcome.set(.retainedForRetry, ids: movable.map(\.id))
        }
        registerDeferredMoveSuccessors(deferredSuccessors)
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager.move phase=recorded destination=\(destinationPath) "
                + "outcome=\(outcome.diagnosticSummary) "
                + "deferredRegistered=\(deferredSuccessors.count)")
        Task { @MainActor in
            NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        }
        Task { await UnreadCountManager.shared.requestRecount(folderIds: affectedFolderIds) }
        Task { await drainPendingQueue() }
        return outcome
    }

    func markFlagged(_ messages: [MessageHeader], flagged: Bool) async {
        await ensureDurable(messages)

        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
        do {
            try await dbPool.write { db in
                for (_, msgs) in grouped {
                    let accountId = msgs[0].accountId
                    let folderPath = msgs[0].folderPath
                    guard let admission = try Self.admittedOrdinaryActionTargets(
                        msgs, accountId: accountId, folderPath: folderPath, db: db) else { continue }
                    for msg in admission.messages {
                        try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [flagged, msg.id])
                    }
                    let opType: OperationType = flagged ? .markFlagged : .markUnflagged
                    var flagOp = PendingOperation(
                        type: opType, messageIds: admission.providerIds,
                        accountId: accountId, folderPath: folderPath,
                        observedUidValidity: admission.observedUidValidity)
                    try flagOp.insert(db)
                }
            }
        } catch {
            print("[Queue] ERROR: markFlagged write failed: \(error)")
        }
        Task { @MainActor in NotificationCenter.default.post(name: .inboxDataDidChange, object: nil) }
        Task { await drainPendingQueue() }
    }

    /// Drop messages whose CURRENT folder already has `role` — same-role moves
    /// (archive-from-Archive, delete-from-Trash) are no-ops. Accounts can carry
    /// more than one folder per role (e.g. iCloud "Trash" + "Deleted Messages"),
    /// so the path-equality filter in `move()` alone can't catch these: the
    /// canonical `fetchOne` destination may be the OTHER same-role folder.
    private func messagesNotInRole(_ messages: [MessageHeader], role: FolderRole) async -> [MessageHeader] {
        let folderIds = Set(messages.map(\.folderId))
        let roleFolderIds: Set<String> = (try? await dbPool.read { db in
            let rows = try Folder
                .filter(folderIds.contains(Column("id")) && Column("role") == role.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.id))
        }) ?? []
        guard !roleFolderIds.isEmpty else { return messages }
        return messages.filter { !roleFolderIds.contains($0.folderId) }
    }

    /// T4.V8: see `move(_:to:)`. Ids `messagesNotInRole` drops are PROVEN already
    /// in the target role folder (the requested end state already holds), so they
    /// are `terminalStale`, not a silent success.
    @discardableResult
    func archive(_ messages: [MessageHeader]) async -> RoleMoveAdmission {
        let movable = await messagesNotInRole(messages, role: .archive)
        var outcome = RoleMoveAdmission()
        let movableIds = Set(movable.map(\.id))
        outcome.set(.terminalStale, ids: messages.map(\.id).filter { !movableIds.contains($0) })
        outcome.merge(await moveToRoleFolderPerAccount(movable, role: .archive))
        return outcome
    }

    @discardableResult
    func delete(_ messages: [MessageHeader]) async -> RoleMoveAdmission {
        guard let first = messages.first else { return .empty }
        AccountManager.logDeleteTrace(accountId: first.accountId, messages: messages, callSite: "AccountManager.delete")
        let movable = await messagesNotInRole(messages, role: .trash)
        var outcome = RoleMoveAdmission()
        let movableIds = Set(movable.map(\.id))
        outcome.set(.terminalStale, ids: messages.map(\.id).filter { !movableIds.contains($0) })
        outcome.merge(await moveToRoleFolderPerAccount(movable, role: .trash))
        return outcome
    }

    /// Resolve the role folder PER ACCOUNT and move each account's messages to
    /// ITS OWN path. The previous implementation resolved the path from only
    /// `movable.first`'s account and applied it to every account in the batch —
    /// a cross-account batch (agent tools and the notification router accept
    /// ids spanning accounts) mis-filed every non-first account's messages
    /// into a folder path that doesn't exist for that account: the row got an
    /// optimistic folderId no real folder backs (message vanishes from that
    /// account's views until the next sync heals it) and a PendingOperation
    /// whose destinationPath is meaningless to that provider (self-heal drop —
    /// the archive/delete never happens server-side). Follow-up-session audit
    /// round 6; pre-existing, reachable via EmailArchiveTool/EmailDeleteTool.
    ///
    /// T4.V8 — DEVIATION FROM `v2final`, stated deliberately. `v2final
    /// :AccountManager.recordRoleMove` classifies an account whose role folder
    /// resolves cleanly to nothing (`RoleFolderResolution.absent`) as
    /// `terminalStale`. v3 classifies it `retainedForRetry` instead, because on
    /// v3 that is an unknown, not a provider verdict: nothing here consulted the
    /// provider, and the folder row appears as soon as `SyncEngine.fullSync`'s
    /// folder-list upsert runs. In `v2final` the terminal call was backed by a
    /// journal + quarantine substrate that kept the intention visible and
    /// recoverable after a terminal classification; v3 has neither, so a
    /// terminal verdict here would be a silent drop on an unknown.
    @discardableResult
    private func moveToRoleFolderPerAccount(_ movable: [MessageHeader], role: FolderRole) async -> RoleMoveAdmission {
        guard !movable.isEmpty else { return .empty }
        var outcome = RoleMoveAdmission()
        let byAccount = Dictionary(grouping: movable, by: \.accountId)
        for (accountId, accountMessages) in byAccount {
            let path: String?
            do {
                path = try await dbPool.read { db in
                    try Folder.filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                        .fetchOne(db)?.path
                }
            } catch {
                // A thrown read answers nothing at all — strictly retryable.
                print("[Queue] ERROR: \(role.rawValue) folder lookup failed for account \(accountId): \(error) — \(accountMessages.count) message(s) skipped")
                outcome.set(.retainedForRetry, ids: accountMessages.map(\.id))
                continue
            }
            guard let path else {
                print("[Queue] ERROR: no \(role.rawValue) folder found for account \(accountId) — \(accountMessages.count) message(s) skipped")
                outcome.set(.retainedForRetry, ids: accountMessages.map(\.id))
                continue
            }
            outcome.merge(await move(accountMessages, to: path))
        }
        return outcome
    }

    // MARK: - Coordinated Tool Actions (agent tools, ADR-IOS-057 vicinity)

    /// Archive/delete via the same overlay + FIFO write-queue lifecycle as gesture
    /// actions, for agent tools (`EmailArchiveTool`/`EmailDeleteTool`). Tools resolve
    /// headers BEFORE an unbounded user-confirmation wait (for the confirmation card
    /// display) — that snapshot can go stale while the user waits, so a later
    /// user move/delete must not be silently reversed by an action that blindly
    /// trusts it. This helper takes ids (never a pre-resolved header) and
    /// re-resolves fresh headers INSIDE the queued closure, so the write acts on
    /// row truth at EXECUTION time — and participates in the same optimistic
    /// overlay + FIFO ordering as gesture-driven archive/delete. Awaits durable
    /// completion (the local GRDB write + `PendingOperation` insert have landed)
    /// before returning.
    ///
    /// Retain/release audit: one `retainOverlayEntry` per actionable id below,
    /// BEFORE its `registerMutation` call (ADR-IOS-057 ordering — the overlay
    /// entry must not be removable by a sibling op's release before this id's
    /// own retain lands). The queued closure releases every retained id on
    /// every exit: ids dropped by the closure's own fresh re-resolve (vanished
    /// row, or already moved into the role folder by an earlier queued op) are
    /// released as soon as the drop is detected; the remaining (fresh) ids are
    /// released once, after the `archive()`/`delete()` write completes (or is
    /// skipped on the defensive unsupported-role branch, unreachable in
    /// practice — the guard at the top of this function only lets `.archive`/
    /// `.trash` reach the retain loop at all). There is exactly one path
    /// through the closure body — no early returns — so the two release loops
    /// together cover every id this call ever retained.
    ///
    /// **T4.V8 — returns the `(admitted, pending, failed)` triple.** PORT of the
    /// receipt `v2final:AccountManager.recordRoleMove` returns
    /// (`IntentionAdmissionOutcome`, commit `b1c89ad4a`), adapted to v3's
    /// journal-less shape. Callers (`EmailArchiveTool`, `EmailDeleteTool`,
    /// `NotificationActionRouter`) previously reported unconditional success after
    /// this `await`, so a refused or rolled-back admission was indistinguishable
    /// from a completed one. It is a TRIPLE and not a Bool on purpose: collapsing
    /// `pending` into `admitted` reports success for work that never reached the
    /// provider, and collapsing it into `failed` tells an agent to retry an action
    /// that is still outstanding — which makes it act twice.
    ///
    /// **`expectedIdentities` — the CONTENT witness the re-resolve needs.** The
    /// re-resolve above is what makes this helper act on execution-time truth, but
    /// on its own it answers only "what is at this ADDRESS now", and on IMAP the
    /// address is a per-folder UID a UIDVALIDITY turnover reassigns. A caller that
    /// captured headers before an unbounded wait therefore hands them in here
    /// (`ExpectedMessageIdentity.map`, zero extra I/O — the headers are already in
    /// hand for the confirmation card), and BOTH resolve points refuse any id whose
    /// row is provably a different message now.
    ///
    /// 🚨 **NO DEFAULT VALUE, DELIBERATELY.** This parameter used to be
    /// `= [:]`, which made the C3 protection **fail-OPEN and SILENT**: omitting
    /// it read as an ordinary optional argument, and both of this function's
    /// refusals (`preRefusedIds`, `freshRefusedIds`) are witness-gated, so a
    /// caller that omitted it disabled them with nothing at the call site
    /// saying so. Exactly that happened — the two notification-action call
    /// sites in `AppDelegate` omitted it while the two agent-tool call sites
    /// passed it, so a notification tap ran with both C3 checks inert. Passing
    /// an EMPTY map is still allowed and still means "no refusal", but it is
    /// now a decision a reader can see. Do not restore the default.
    /// (Reference `v2final:AccountManager.recordRoleMove` did not need one: it
    /// takes `headers: [MessageHeader]` and derives the witness itself, so
    /// there was no seam to omit.)
    ///
    /// APPLIED TWICE ON PURPOSE, exactly as the reference does
    /// (`v2final:recordRoleMove` + `filterMembersAgainstExpectedIdentity`): the
    /// pre-resolve verify runs against an EARLIER resolve than the queued closure's,
    /// and the FIFO write queue can put an unbounded amount of other work between
    /// them — wide enough for a UIDVALIDITY reset to purge and re-seat an impostor
    /// under the same composite id in between. Checking only the first would prove
    /// identity and then discard the proof, which is the defect itself.
    ///
    /// `@discardableResult` for the test call sites that drive the coordination
    /// lifecycle rather than the receipt; every production caller consumes it.
    @discardableResult
    func performCoordinatedRoleMove(
        ids: [String],
        role: FolderRole,
        expectedIdentities: [String: ExpectedMessageIdentity]
    ) async -> RoleMoveAdmission {
        guard !ids.isEmpty else { return .empty }
        var outcome = RoleMoveAdmission()
        guard role == .archive || role == .trash else {
            BackgroundSyncLogger.logInbox("[AccountManager] performCoordinatedRoleMove — unsupported role \(role.rawValue), no-op")
            // PORT of `v2final:recordRoleMove`'s unsupported-role arm: terminal,
            // because no retry of the same call can ever behave differently.
            outcome.set(.terminalStale, ids: ids)
            return outcome
        }

        // Pre-resolve fresh headers to drop ids that no longer exist or are
        // already in the target role folder, and to look up each account's
        // destination folder for the overlay's display-only folderId. This
        // snapshot is intentionally re-taken again INSIDE the queued closure
        // below — the actual write never trusts this one.
        let preResolved = await resolveHeadersForAction(ids: ids)

        // T4.V8: `resolveHeadersForAction` swallows read errors (`try?` → []),
        // so an id it did not return is EITHER a genuinely vanished row OR a
        // failed read. `move()` cannot tell them apart and must therefore call
        // the whole set retryable — but this is a non-gesture path (tool /
        // notification dispatch, not a finger gesture; the same reasoning
        // `v2final:recordRoleMove` records for its own pre-resolve), so one
        // extra THROWING probe is affordable here and turns a proven clean
        // absence into an honest `terminalStale` instead of an eternal
        // "pending". A thrown probe stays `retainedForRetry`: the database
        // could not answer, and an unanswered question is never a verdict.
        let unresolvedIds = Set(ids).subtracting(preResolved.map(\.id))
        if !unresolvedIds.isEmpty {
            do {
                let durablyPresent = try await dbPool.read { db -> Set<String> in
                    try Set(String.fetchAll(
                        db,
                        MessageHeader.select(Column("id")).filter(unresolvedIds.contains(Column("id")))))
                }
                // Mirror `resolveHeadersForAction`'s SECOND lookup step so a
                // row that lives only in the ADR-IOS-049 staged cache is never
                // declared absent.
                let stagedPresent = NSEDataBridge.latestStagedRows.withLock { rows in
                    Set(rows.map(\.headerId)).intersection(unresolvedIds)
                }
                let provenAbsent = unresolvedIds.subtracting(durablyPresent).subtracting(stagedPresent)
                outcome.set(.terminalStale, ids: provenAbsent)
                outcome.set(.retainedForRetry, ids: unresolvedIds.subtracting(provenAbsent))
            } catch {
                print("[Queue] ERROR: performCoordinatedRoleMove(\(role.rawValue)) absence probe failed: \(error) — \(unresolvedIds.count) id(s) retained")
                outcome.set(.retainedForRetry, ids: unresolvedIds)
            }
        }

        // C3 — CONTENT PROOF, pass 1. A row that no longer carries the captured
        // Message-ID is a DIFFERENT physical message at the same address, so this
        // id is provably not the work the caller confirmed. TERMINAL: retrying the
        // same id can never behave differently, because the id names an address the
        // impostor now owns. The caller re-reads and re-addresses instead.
        let (identityMatched, preRefusedIds) = ExpectedMessageIdentity.partition(
            preResolved, against: expectedIdentities)
        if !preRefusedIds.isEmpty {
            outcome.setIdentityRefused(ids: preRefusedIds)
            Self.announceIdentityRefusedIds(preRefusedIds)
            print("[Queue] performCoordinatedRoleMove(\(role.rawValue)) refused \(preRefusedIds.count) id(s) at pre-resolve: the row at that address is not the message the caller captured (C3)")
        }

        let movable = await messagesNotInRole(identityMatched, role: role)
        // PROVEN already in the target role folder — `messagesNotInRole` fails
        // OPEN on a read error (it returns every message when its read throws),
        // so an id it DROPS is always a positive in-role match, never an unknown.
        let movableIds = Set(movable.map(\.id))
        outcome.set(.terminalStale, ids: identityMatched.map(\.id).filter { !movableIds.contains($0) })
        guard !movable.isEmpty else {
            // Observability (audit round 5): callers (agent tools, notification
            // router) used to report success unconditionally after this await — a
            // silent return here on a read failure (resolveHeadersForAction
            // swallows errors to []) would leave no trace anywhere. Vanished/
            // already-in-role ids are legit no-ops; the log is the only failure
            // correlate. T4.V8 additionally returns the typed dispositions above.
            print("[Queue] performCoordinatedRoleMove(\(role.rawValue)): 0 of \(ids.count) ids actionable after resolve/role filter — nothing to do")
            return outcome
        }

        let accountIds = Set(movable.map(\.accountId))
        let destFolderIdByAccount: [String: String]
        do {
            destFolderIdByAccount = try await dbPool.read { db -> [String: String] in
                var result: [String: String] = [:]
                for accountId in accountIds {
                    if let folder = try Folder
                        .filter(Column("accountId") == accountId && Column("role") == role.rawValue)
                        .fetchOne(db) {
                        result[accountId] = folder.id
                    }
                }
                return result
            }
        } catch {
            // T4.V8: this read used to be `try?` → `[:]`, which made a thrown
            // read look exactly like "no account has a role folder" and skipped
            // every id. Nothing was consulted and nothing was decided — retryable.
            print("[Queue] ERROR: performCoordinatedRoleMove(\(role.rawValue)) role-folder lookup failed: \(error) — \(movable.count) message(s) retained")
            outcome.set(.retainedForRetry, ids: movable.map(\.id))
            return outcome
        }

        // Skip ids whose account has no folder for this role — mirrors
        // archive()/delete()'s own "no archive/trash folder for account" skip
        // (including its ERROR log convention — audit round 5). T4.V8: retryable,
        // not terminal — see `moveToRoleFolderPerAccount`'s deviation note.
        let actionable = movable.filter { destFolderIdByAccount[$0.accountId] != nil }
        let actionableIds = Set(actionable.map(\.id))
        outcome.set(.retainedForRetry, ids: movableIds.subtracting(actionableIds))
        guard !actionable.isEmpty else {
            print("[Queue] ERROR: performCoordinatedRoleMove(\(role.rawValue)) — no \(role.rawValue) folder resolved for account(s) \(accountIds.sorted().joined(separator: ",")); \(movable.count) message(s) skipped")
            return outcome
        }

        for msg in actionable {
            guard let destFolderId = destFolderIdByAccount[msg.accountId] else { continue }
            retainOverlayEntry(id: msg.id)
            registerMutation(id: msg.id, mutation: PendingMutation(
                folderId: destFolderId,
                // Tag clears locally the moment the message LEAVES the inbox —
                // mirrors the DB-side clear semantics (F6): archive/trash
                // destinations are never the inbox, so for this helper's two
                // supported roles "isInInbox on the pre-resolved snapshot"
                // IS "leaving the inbox".
                actionTag: msg.isInInbox ? .some(nil) : nil
            ))
        }

        let queued = await withCheckedContinuation { (cont: CheckedContinuation<RoleMoveAdmission, Never>) in
            enqueueWrite {
                var queuedOutcome = RoleMoveAdmission()
                // Re-resolve INSIDE the queued closure: acts on row truth at
                // EXECUTION time, not the confirmation-time snapshot above —
                // the staleness bug this helper exists to close.
                let fresh = await self.resolveHeadersForAction(ids: Array(actionableIds))
                // C3 — CONTENT PROOF, pass 2. See the `expectedIdentities` note on
                // this function: pass 1 ran before this closure took its FIFO turn,
                // so its proof is stale by exactly the window this pass closes.
                let (freshMatched, freshRefusedIds) = ExpectedMessageIdentity.partition(
                    fresh, against: expectedIdentities)
                if !freshRefusedIds.isEmpty {
                    queuedOutcome.setIdentityRefused(ids: freshRefusedIds)
                    Self.announceIdentityRefusedIds(freshRefusedIds)
                    print("[Queue] performCoordinatedRoleMove(\(role.rawValue)) refused \(freshRefusedIds.count) id(s) at execution: the row at that address is not the message the caller captured (C3)")
                }
                let freshMovable = await self.messagesNotInRole(freshMatched, role: role)
                let freshIds = Set(freshMovable.map(\.id))

                // Ids dropped by the fresh resolve (vanished row, or already
                // in the role folder — e.g. an earlier queued op moved it
                // there first) get no write; release their retain now.
                //
                // T4.V8: those two causes are conflated here (and the vanished
                // half is itself ambiguous with a swallowed read failure), so
                // the union is `retainedForRetry` — the classification that is
                // wrong in NEITHER direction. The earlier pre-resolve pass has
                // already recorded a proven `terminalStale` for the ids it could
                // prove, and `set` is monotone, so a proof taken there is never
                // downgraded by this coarser pass.
                //
                // ⚑ THE IDENTITY-REFUSED IDS ARE EXCLUDED FROM THE `retainedForRetry`
                // CLASSIFICATION, NOT FROM THE RELEASE. `set` is monotone by RANK,
                // and `retainedForRetry` OUTRANKS `terminalStale` — so folding them
                // in would silently promote a PROVEN wrong-message refusal into
                // "still outstanding", telling the agent to keep waiting for work
                // that will never happen. Their overlay retain must still be
                // released here, on the same pass, or the impostor row stays hidden
                // behind a stranded optimistic entry.
                let droppedByFreshResolve = actionableIds.subtracting(freshIds)
                queuedOutcome.set(.retainedForRetry, ids: droppedByFreshResolve.subtracting(freshRefusedIds))
                for id in droppedByFreshResolve {
                    self.releaseOverlayEntry(id: id)
                }

                // Mark-as-read-on-archive/delete (Settings → User Interface,
                // default ON). Composed against `freshMovable` — the SAME
                // execution-time set the move below acts on, after BOTH C3
                // content-witness passes and the role filter — so the read op
                // and the move op can never name different messages. Awaited
                // immediately before the move inside this one closure; see
                // `markReadBeforeRoleMove` for why that ordering is the C3
                // guard and not a stylistic choice.
                await self.markReadBeforeRoleMove(freshMovable)

                switch role {
                case .archive:
                    queuedOutcome.merge(await self.archive(freshMovable))
                case .trash:
                    queuedOutcome.merge(await self.delete(freshMovable))
                default:
                    // Unreachable — the guard at the top of this function
                    // only lets .archive/.trash reach the retain loop.
                    BackgroundSyncLogger.logInbox("[AccountManager] performCoordinatedRoleMove — unexpected role \(role.rawValue) reached queued closure")
                    queuedOutcome.set(.terminalStale, ids: freshIds)
                }

                for id in freshIds {
                    self.releaseOverlayEntry(id: id)
                }
                cont.resume(returning: queuedOutcome)
            }
        }
        outcome.merge(queued)
        return outcome
    }

    /// Diagnostic-only: log the trash-folder lookup result and the message(s) being deleted
    /// so we can correlate a delete action with the destinationPath that ends up on the
    /// PendingOperation. Includes every role=.trash candidate to surface duplicate or
    /// cross-account contamination.
    /// `callSite` identifies the entry point (multiple code paths queue a delete).
    static nonisolated func logDeleteTrace(accountId: String, messages: [MessageHeader], callSite: String) {
        let allTrash: [Folder] = (try? AppDatabase.dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchAll(db)
        }) ?? []
        let trashFolder = allTrash.first
        print("[DeleteTrace] \(callSite) — accountId=\(accountId) msgCount=\(messages.count) resolvedTrash=\(trashFolder.map { "id=\($0.id) name=\($0.name) path=\($0.path) role=\($0.role.rawValue)" } ?? "<nil>") trashCandidates=\(allTrash.count)")
        for f in allTrash {
            print("[DeleteTrace] trashCandidate: id=\(f.id) name=\(f.name) path=\(f.path)")
        }
        for m in messages {
            print("[DeleteTrace] msg: id=\(m.id) folderPath=\(m.folderPath) accountId=\(m.accountId) messageId=\(m.messageId) rfc822=\(m.rfc822MessageId ?? "<nil>") stableId=\(m.stableId)")
        }
    }

    // MARK: - Search

    func search(query: String, account: Account, folder: String, after: Date? = nil, before: Date? = nil, from: String? = nil, to: String? = nil) async throws -> [MessageHeaderInfo] {
        guard let queue = workQueues[account.id] else { throw ProviderError.notConnected }
        return try await queue.execute(priority: .userAction) {
            try await queue.provider.search(query: query, folder: folder, after: after, before: before, from: from, to: to)
        }
    }

    // MARK: - Undo Support

    private struct UndoMoveWriteResult: Sendable {
        var restoredOriginalHeaderIds: [String] = []
        var affectedFolderIds: Set<String> = []
        var queuedInverse = false
        var deferredSuccessors: [DeferredMoveSuccessor] = []
        /// The inverse `PendingOperation`'s identity, carried OUT of the write so
        /// the `phase=queuedInverse` diagnostic can be emitted after the
        /// transaction has committed. Both are set together, immediately after
        /// `inverseOp.insert(db)`, and are nil on every path that queues no
        /// inverse — so "both non-nil" is the same condition as "the row is
        /// durable". A file-backed line emitted INSIDE the closure would survive
        /// a rollback (`AppLogStore.append` enqueues its file I/O on an
        /// independent queue that no `ROLLBACK` can retract) and would then name
        /// an operation that never existed.
        var inverseOpId: String?
        var inverseCreatedAt: Date?
    }

    /// Compatibility entry point for the existing UI/test call shape. Execution
    /// immediately collapses each captured header to the PORTed command/member
    /// payload; the full row is never saved or resurrected.
    @discardableResult
    func undoDestructiveAction(
        _ messages: [MessageHeader],
        accountId: String,
        originalOpType: OperationType,
        fromFolderPath: String,
        toFolderPath: String,
        toFolderId: String
    ) async -> [String] {
        guard originalOpType == .move else {
            // SUBTRACT — archive/delete compatibility rows and removeTag
            // cancellation. T2.4 emits every destructive gesture as `.move`.
            return []
        }
        return await undoMove(
            accountId: accountId,
            forwardDestinationPath: fromFolderPath,
            members: messages.map(UndoMember.init(header:))
        )
    }

    /// Restore immediately, as in 1.6.38. A queued forward is annihilated; a
    /// completed forward gets one ordinary inverse; an in-flight IMAP forward
    /// records a process-local successor until COPYUID supplies its new UID.
    /// There is no Message-ID mutation lookup or full-row resurrection.
    @discardableResult
    func undoMove(
        accountId: String,
        forwardDestinationPath: String,
        members: [UndoMember]
    ) async -> [String] {
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager.undoMove phase=begin "
                + "forwardDestination=\(forwardDestinationPath) "
                + "members=[\(members.map { "\($0.originalHeaderId){source=\($0.sourceFolderPath),provider=\($0.providerMessageId)}" }.joined(separator: ","))] "
                + "deferredCount=\(deferredMoveSuccessors.count)")
        guard !members.isEmpty,
              !forwardDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        let providerIds = members.map(\.providerMessageId)
        let providerIdSet = Set(providerIds)
        let sourcePaths = Set(members.map(\.sourceFolderPath))
        let sourceFolderIds = Set(members.map(\.sourceFolderId))
        let sourceEpochs = Set(members.map(\.sourceObservedUidValidity))
        guard providerIdSet.count == members.count,
              providerIds.allSatisfy({ !$0.isEmpty }),
              sourcePaths.count == 1,
              sourceFolderIds.count == 1,
              sourceEpochs.count == 1,
              let sourcePath = sourcePaths.first,
              let sourceFolderId = sourceFolderIds.first
        else {
            print("[UndoStack] undoMove refused heterogeneous/duplicate command for account \(accountId)")
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.undoMove phase=refused "
                    + "reason=heterogeneousOrDuplicate account=\(accountId)")
            return []
        }
        let sourceEpoch = members[0].sourceObservedUidValidity
        // The forward gesture can itself be a process-local successor waiting
        // behind an in-flight opposite move. Undoing that newest gesture means
        // cancelling the successor, not trying to move the still-source row
        // from a destination address it has not received yet. The synchronous
        // admission ledger guarantees the gesture's move closure has already
        // registered this successor before the inverse closure reaches here.
        // This is exact and whole-command: every member must name a successor
        // whose current desired destination is the forward destination and
        // whose predecessor already leaves the message in the undo source.
        let memberHeaderIds = Set(members.map(\.originalHeaderId))
        if memberHeaderIds.count == members.count,
           members.allSatisfy({ member in
               guard let successor = deferredMoveSuccessors[member.originalHeaderId]
               else { return false }
               return successor.desiredDestinationPath == forwardDestinationPath
                   && successor.predecessorDestinationPath == sourcePath
           }) {
            let cancelled = coalesceDeferredMoves(
                headerIds: memberHeaderIds,
                destinationPath: sourcePath)
            guard cancelled.ids == memberHeaderIds else { return [] }
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.undoMove phase=cancelledDeferred "
                    + "ids=[\(memberHeaderIds.sorted().joined(separator: ","))]")
            return members.map(\.originalHeaderId)
        }

        let result: UndoMoveWriteResult
        do {
            result = try await dbPool.write { db -> UndoMoveWriteResult in
                guard let account = try Account.fetchOne(db, key: accountId) else { return UndoMoveWriteResult() }
                let isIMAP = accountId != DemoSeed.demoAccountId
                    && (account.provider == .imap || account.provider == .icloud)

                // Authenticate every exact local member before touching any
                // row or operation. A vanished/re-keyed row is a whole-command
                // refusal; there is no upsert/resurrection fallback.
                //
                // 🚨 THE LAST GUARD IS THE ONLY ONE THAT NAMES THE MESSAGE. The
                // five above all describe the ADDRESS, and on IMAP the address is
                // a per-folder UID the server reassigns at a UIDVALIDITY
                // turnover: the reset reaction purges this folder and step 6
                // resyncs it, so a DIFFERENT physical message can occupy this
                // exact composite id while the in-memory undo stack — which the
                // reaction does not touch — still names it. All five then pass,
                // and so does the epoch check inside
                // `admittedOrdinaryActionTargets`, because the impostor's epoch
                // is the FRESH one. Undo would move a message the user never
                // touched, and nothing recovers a misattributed move (C3).
                //
                // Refuse-only, never a lookup key (ADR-IOS-068/D4): the member is
                // still selected by its recorded address. A member whose captured
                // witness is unusable keeps today's behaviour — see
                // `ExpectedMessageIdentity`.
                var currentRows: [MessageHeader] = []
                for member in members {
                    guard let row = try MessageHeader.fetchOne(db, key: member.originalHeaderId),
                          row.accountId == accountId,
                          row.messageId == member.providerMessageId,
                          row.folderPath == forwardDestinationPath,
                          row.folderId == MessageIdentity.folderId(
                              accountId: accountId, folderPath: forwardDestinationPath)
                    else { return UndoMoveWriteResult() }
                    if let expected = ExpectedMessageIdentity(
                        capturedRfc822MessageId: member.sourceRfc822MessageId),
                       !expected.matches(row) {
                        print("[UndoStack] undoMove refused \(member.originalHeaderId): the row at that address is not the message the gesture moved (C3 content witness)")
                        return UndoMoveWriteResult()
                    }
                    currentRows.append(row)
                }

                let activeMoves = try PendingOperation
                    .filter(Column("accountId") == accountId)
                    .filter(Column("type") == OperationType.move.rawValue)
                    .filter(Column("status") != PendingStatus.cancelled.rawValue)
                    .fetchAll(db)

                let related = activeMoves.filter {
                    !Set($0.messageIds).isDisjoint(with: providerIdSet)
                }
                let relatedSummary = related.map { operation in
                    let operationId = String(operation.id.prefix(8))
                    let destination = operation.destinationPath ?? "<nil>"
                    let summary: String = "\(operationId){status=\(operation.status),"
                        + "attempted=\(operation.everAttempted),"
                        + "from=\(operation.folderPath),to=\(destination)}"
                    return summary
                }.joined(separator: ",")
                BackgroundSyncLogger.logInbox(
                    "[RoleActionTrace] manager.undoMove phase=relatedOps "
                        + "members=[\(members.map(\.originalHeaderId).joined(separator: ","))] "
                        + "ops=[\(relatedSummary)]")
                func exactAddressPayload(_ op: PendingOperation) -> Bool {
                    let ids = op.messageIds
                    return ids.count == providerIds.count
                        && Set(ids) == providerIdSet
                        && op.folderPath == sourcePath
                        && op.destinationPath == forwardDestinationPath
                }
                func exactPayload(_ op: PendingOperation) -> Bool {
                    exactAddressPayload(op)
                        && op.observedUidValidity == sourceEpoch
                }
                func exactInFlightPayload(_ op: PendingOperation) -> Bool {
                    guard exactAddressPayload(op) else { return false }
                    if op.observedUidValidity == sourceEpoch { return true }
                    // A second optimistic gesture can be built from the
                    // destination row while the first IMAP command is still on
                    // the wire. That row deliberately has no SOURCE epoch.
                    // In this one exact in-flight case, inherit the epoch from
                    // the already-admitted command instead of dropping Undo.
                    // A non-nil mismatch still fails closed.
                    return sourceEpoch == nil
                        && (op.observedUidValidity.map { $0 > 0 } ?? false)
                }

                let annihilable = related.filter {
                    $0.status == PendingStatus.queued.rawValue
                        && !$0.everAttempted
                        && exactPayload($0)
                }
                let annihilate = related.count == 1 && annihilable.count == 1
                // Carried out of the write; see `UndoMoveWriteResult`.
                var inverseOpId: String?
                var inverseCreatedAt: Date?

                // The optimistic row still names the SOURCE UID while the
                // exact IMAP forward is on the wire. Record the opposite now,
                // but let the drain's COPYUID result name it. This preserves
                // 1.6.38's immediate Undo without restoring its Message-ID
                // search mutation target.
                if isIMAP,
                   related.count == 1,
                   exactInFlightPayload(related[0]),
                   related[0].status == PendingStatus.inFlight.rawValue {
                    let predecessor = related[0]
                    BackgroundSyncLogger.logInbox(
                        "[RoleActionTrace] manager.undoMove phase=deferBehindInFlight "
                            + "predecessor=\(predecessor.id.prefix(8)) "
                            + "ids=[\(members.map(\.originalHeaderId).joined(separator: ","))]")
                    return UndoMoveWriteResult(
                        restoredOriginalHeaderIds: members.map(\.originalHeaderId),
                        deferredSuccessors: members.map { member in
                            DeferredMoveSuccessor(
                                predecessorOperationId: predecessor.id,
                                predecessorDestinationPath: forwardDestinationPath,
                                oldHeaderId: member.originalHeaderId,
                                desiredDestinationPath: sourcePath)
                        })
                }

                if annihilate {
                    BackgroundSyncLogger.logInbox(
                        "[RoleActionTrace] manager.undoMove phase=annihilateQueued "
                            + "op=\(annihilable[0].id.prefix(8)) "
                            + "ids=[\(members.map(\.originalHeaderId).joined(separator: ","))]")
                    if isIMAP {
                        guard let epoch = sourceEpoch,
                              let positive = UInt32(exactly: epoch), positive > 0,
                              providerIds.allSatisfy({ id in
                                  guard let uid = UInt32(id), uid > 0 else { return false }
                                  return id == String(uid)
                              })
                        else { return UndoMoveWriteResult() }
                    }
                    _ = try PendingOperation.deleteOne(db, key: annihilable[0].id)
                } else {
                    // A related but non-exact bundle is not evidence the
                    // forward completed. Refuse partial/cross-mailbox/
                    // cross-epoch cancellation whole.
                    if !related.isEmpty && !(related.count == 1 && exactPayload(related[0])) {
                        return UndoMoveWriteResult()
                    }
                    // UNDO IS JUST A REVERSE MOVE — it was never a rollback. The
                    // inverse is admitted through the SAME predicate as any
                    // ordinary forward gesture from `forwardDestinationPath`,
                    // so IMAP needs no special case and no receipt: the drain
                    // has already re-keyed each row to the destination address
                    // `COPYUID` proved, and admission re-derives that address
                    // from the row plus its folder's live epoch.
                    //
                    // WHOLE-COMMAND, never partial: a bundle that is only
                    // partly admissible is refused entirely, exactly as the
                    // non-exact-payload arm above refuses. A partly-reversed
                    // move is a worse outcome than an unreversed one, because
                    // the user cannot see which half moved.
                    guard let admission = try Self.admittedOrdinaryActionTargets(
                        currentRows, accountId: accountId,
                        folderPath: forwardDestinationPath, db: db),
                        admission.messages.count == currentRows.count
                    else { return UndoMoveWriteResult() }
                    // Bound to a local ONLY so the diagnostic emitted after this
                    // write returns can name the row's `id` and `createdAt`.
                    // `PendingOperation` is a `PersistableRecord` (non-mutating
                    // `insert`), so this is the same value, inserted the same way, in
                    // the same transaction.
                    var inverseOp = PendingOperation(
                        type: .move,
                        messageIds: admission.providerIds,
                        accountId: accountId,
                        folderPath: forwardDestinationPath,
                        destinationPath: sourcePath,
                        observedUidValidity: admission.observedUidValidity
                    )
                    try inverseOp.insert(db)
                    inverseOpId = inverseOp.id
                    inverseCreatedAt = inverseOp.createdAt
                }

                // Undo remains instant, as it was in 1.6.38. For a queued IMAP
                // inverse the row temporarily carries destination UID + source
                // folder, so its epoch MUST be nil. The exact queued-opposite
                // guard above can safely cancel it; every other provider action
                // remains fail-closed until the inverse re-keys it for real.
                let restoredEpoch = annihilate || !isIMAP ? sourceEpoch : nil
                // ⚑ NO REFERENCE — INVENTED: smallest field-level restoration
                // for v3's exact authenticated row. Preserve every unrelated
                // field (notably current read/flag state); never `save` a stale
                // snapshot or recreate a missing row.
                for member in members {
                    try MessageHeader.filter(Column("id") == member.originalHeaderId).updateAll(
                        db,
                        Column("folderId").set(to: member.sourceFolderId),
                        Column("folderPath").set(to: member.sourceFolderPath),
                        Column("isInInbox").set(to: member.sourceIsInInbox),
                        Column("observedUidValidity").set(to: restoredEpoch),
                        Column("actionTag").set(to: member.sourceActionTag?.rawValue),
                        Column("tagSortOrder").set(to: member.sourceTagSortOrder)
                    )
                }

                let restoredIds = members.map(\.originalHeaderId)
                let destinationFolderId = MessageIdentity.folderId(
                    accountId: accountId, folderPath: forwardDestinationPath)
                let unreadRestored = currentRows.filter { !$0.isRead }.count
                if unreadRestored > 0 {
                    try db.execute(
                        sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?",
                        arguments: [unreadRestored, destinationFolderId])
                    try db.execute(
                        sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?",
                        arguments: [unreadRestored, sourceFolderId])
                }
                return UndoMoveWriteResult(
                    restoredOriginalHeaderIds: restoredIds,
                    affectedFolderIds: [sourceFolderId, destinationFolderId],
                    queuedInverse: !annihilate,
                    inverseOpId: inverseOpId,
                    inverseCreatedAt: inverseCreatedAt
                )
            }
        } catch {
            print("[UndoStack] ERROR: undoMove write failed: \(error)")
            return []
        }
        registerDeferredMoveSuccessors(result.deferredSuccessors)
        // `opId` and `createdAt` are what CORRELATE this inverse with the drain
        // lines it later produces: `queueLog` prints `id.prefix(8)` next to the
        // claimed row's `queuePosition`, so without the id an undo cannot be
        // matched to the position it was executed at — the gap that made
        // `IOS-QUEUE-008` unreadable from an exported log. `createdAt` is
        // rendered as an epoch interval deliberately: it is the operation's AGE,
        // and sub-second resolution is what distinguishes a delete from the undo
        // issued a moment later when reading a trace by hand. It does NOT decide
        // wire order — `queuePosition` does.
        //
        // Emitted HERE rather than next to the insert because the write above
        // can still roll back after the row is inserted, and this sink is
        // file-backed: `AppLogStore.append` enqueues I/O that no `ROLLBACK`
        // retracts, so a pre-commit line can name an operation that never
        // became durable. `providerIds` is the list the write admitted — every
        // member was authenticated against its `providerMessageId` and the
        // inverse is queued only when admission returned one target per member,
        // so it equals `providerIds` here.
        if let inverseOpId = result.inverseOpId, let inverseCreatedAt = result.inverseCreatedAt {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.undoMove phase=queuedInverse "
                    + "from=\(forwardDestinationPath) to=\(sourcePath) "
                    + "providerIds=[\(providerIds.joined(separator: ","))] "
                    + "opId=\(inverseOpId) "
                    + "createdAt=\(inverseCreatedAt.timeIntervalSince1970)")
        }
        BackgroundSyncLogger.logInbox(
            "[RoleActionTrace] manager.undoMove phase=result "
                + "restored=[\(result.restoredOriginalHeaderIds.joined(separator: ","))] "
                + "queuedInverse=\(result.queuedInverse) "
                + "deferred=\(result.deferredSuccessors.count)")
        for id in result.restoredOriginalHeaderIds {
            BackgroundSyncLogger.logInbox(
                "[RoleActionTrace] manager.undoMove phase=resultOverlay id=\(id) "
                    + roleActionOverlayDiagnostic(id: id))
        }
        if result.deferredSuccessors.isEmpty,
           !result.restoredOriginalHeaderIds.isEmpty {
            Task { @MainActor in
                NotificationCenter.default.post(name: .unreadCountsDidChange, object: nil)
                NotificationCenter.default.post(
                    name: .inboxDataDidChange,
                    object: result.restoredOriginalHeaderIds)
            }
            Task { await UnreadCountManager.shared.requestRecount(folderIds: result.affectedFolderIds) }
        }
        if result.queuedInverse { Task { await drainPendingQueue() } }
        return result.restoredOriginalHeaderIds
    }

    // MARK: - Draft Queue (persistent save/delete)

    /// Look up the Drafts folder path for an account.
    func draftsFolderPath(accountId: String) async throws -> String {
        try await dbPool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)?.path ?? "Drafts"
        }
    }

    /// Queue a draft save to the server's Drafts folder via PendingOperation.
    /// Creates/updates an optimistic MessageHeader in the Drafts folder so the draft
    /// appears immediately in the UI (before IMAP APPEND completes).
    @discardableResult
    func queueDraftSave(draftId: String, accountId: String) async -> Bool {
        do {
            let folderPath = try await draftsFolderPath(accountId: accountId)
            let ftsInfo = try await dbPool.write {
                db -> (record: FTSHeaderRecord, bodyText: String)? in
                guard let draft = try Draft.fetchOne(db, key: draftId),
                      draft.accountId == accountId,
                      let instanceEpoch = draft.instanceEpoch,
                      !instanceEpoch.isEmpty else {
                    return nil
                }

                let folderId = "\(accountId):\(folderPath)"
                let placeholderMessageId = PendingOperation.draftPlaceholderMessageId(
                    draftId: draft.id, instanceEpoch: instanceEpoch)
                let placeholderHeaderId = PendingOperation.draftPlaceholderHeaderPK(
                    accountId: accountId,
                    draftsFolderPath: folderPath,
                    draftId: draft.id,
                    instanceEpoch: instanceEpoch)
                let account = try Account.fetchOne(db, key: accountId)
                let senderEmail = account?.emailAddress ?? accountId
                let senderName = account?.displayName ?? senderEmail
                let snippet = EmailFilter.snippetFromPlainText(draft.body)

                var header = try MessageHeader.fetchOne(db, key: placeholderHeaderId)
                    ?? MessageHeader(
                        messageId: placeholderMessageId,
                        subject: draft.subject,
                        from: senderName,
                        fromAddress: senderEmail,
                        to: draft.toArray.joined(separator: ", "),
                        date: Date(timeIntervalSince1970: draft.updatedAt),
                        snippet: snippet,
                        folderId: folderId,
                        accountId: accountId,
                        folderPath: folderPath,
                        isInInbox: false)
                header.subject = draft.subject
                header.to = draft.toArray.joined(separator: ", ")
                header.cc = draft.ccArray.joined(separator: ", ")
                header.bcc = draft.bccArray.joined(separator: ", ")
                header.snippet = snippet
                header.date = Date(timeIntervalSince1970: draft.updatedAt)
                header.isRead = true
                header.observedUidValidity = nil
                try header.save(db)
                try MessageBody(
                    contentKey: ContentKey(rawValue: placeholderHeaderId),
                    htmlContent: MessageBody.plainTextToHTML(draft.body)
                ).save(db)

                var saveDraftOp = PendingOperation(
                    type: .saveDraft,
                    messageIds: [draft.id, placeholderMessageId],
                    accountId: accountId,
                    folderPath: folderPath,
                    instanceEpoch: instanceEpoch,
                    draftId: draft.id
                )
                try saveDraftOp.insert(db)

                return (
                    FTSHeaderRecord(
                        contentKey: ContentKey(rawValue: placeholderHeaderId),
                        headerId: placeholderHeaderId,
                        messageId: placeholderMessageId,
                        subject: draft.subject,
                        from: "\(senderName) <\(senderEmail)>",
                        to: draft.toArray.joined(separator: ", "),
                        cc: draft.ccArray.joined(separator: ", "),
                        bcc: draft.bccArray.joined(separator: ", "),
                        dateMs: Int64(draft.updatedAt * 1000),
                        folderId: folderId),
                    draft.body)
            }

            guard let ftsInfo else { return false }
            do {
                _ = try await SearchIndex.shared.indexHeaders([ftsInfo.record])
                if !ftsInfo.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await SearchIndex.shared.updateBodies([(
                        contentKey: ftsInfo.record.contentKey,
                        body: ftsInfo.bodyText)])
                }
            } catch {
                print("[Queue] WARNING: FTS indexing failed for draft \(ftsInfo.record.headerId): \(error)")
            }
            try? await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                    arguments: [ftsInfo.record.headerId])
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            Task { await drainPendingQueue() }
            return true
        } catch {
            print("[Queue] ERROR: queueDraftSave failed: \(error)")
            return false
        }
    }
    /// Queue a draft delete from the server's Drafts folder via PendingOperation.
    /// Optimistically removes the MessageHeader from the Drafts folder immediately.
    ///
    /// - Parameter identity: the PROVIDER-NATIVE address of the server copy, already
    ///   typed by provider — `.imap(folder, uidValidity, uid)`, `.gmail(resourceId:)`,
    ///   `.gmailContainedMessage(messageId:)`, `.outlook(graphId:)`, `.demo(localId:)`.
    ///   The IMAP case carries its own minted epoch, which is validated here against
    ///   the folder's `lastKnownUidValidity` and recorded on the op as
    ///   `draftServerUidValidity` so `IMAPProvider.deleteDraft` can take its STRONG
    ///   arm. A `.imap` identity that fails that validation is REFUSED rather than
    ///   downgraded — there is no weaker arm.
    ///
    /// ⚠️ CORRECTED 2026-08-06. This doc block described a `uidValidity:` parameter
    /// and an `rfc822MessageId:` parameter, NEITHER OF WHICH EXISTS on this function
    /// — the epoch moved inside `DraftDeleteIdentity.imap` and the RFC leg was
    /// deleted with the Message-ID-search path. It also said a nil epoch "keeps the
    /// op on the unchanged arm", implying a Message-ID search that ADR-IOS-068/D4
    /// bans (an RFC 822 Message-ID never selects or authorizes a mutation target).
    /// A parameter doc that names parameters the signature does not have is worse
    /// than none: it tells the next editor to pass something, and what it tells them
    /// to pass is the banned identity.
    @discardableResult
    func queueDraftDelete(
        identity: DraftDeleteIdentity,
        accountId: String,
        folderPath explicitFolderPath: String? = nil,
        draftId: String? = nil,
        instanceEpoch: String? = nil,
        deleteOwnedLocalDraft: Bool = false
    ) async -> Bool {
        do {
            let folderPath: String
            if let explicitFolderPath {
                folderPath = explicitFolderPath
            } else {
                folderPath = try await draftsFolderPath(accountId: accountId)
            }
            let deletedAttachmentDir = try await dbPool.write { db -> String? in
                let folderId = "\(accountId):\(folderPath)"
                let encodedId: String
                let addressKind: DraftDeleteAddressKind
                let mintedUidValidity: Int?
                switch identity {
                case .imap(let addressFolder, let uidValidity, let uid):
                    guard addressFolder == folderPath,
                          uid > 0,
                          uidValidity > 0,
                          let folder = try Folder.fetchOne(db, key: folderId),
                          folder.lastKnownUidValidity == uidValidity else {
                        throw ProviderError.actionIdentityResolutionFailed(String(uid))
                    }
                    encodedId = String(uid)
                    addressKind = .providerResource
                    mintedUidValidity = uidValidity
                case .gmail(let resourceId):
                    guard !resourceId.isEmpty else {
                        throw ProviderError.actionIdentityResolutionFailed(resourceId)
                    }
                    encodedId = resourceId
                    addressKind = .providerResource
                    mintedUidValidity = nil
                case .gmailContainedMessage(let messageId):
                    guard !messageId.isEmpty else {
                        throw ProviderError.actionIdentityResolutionFailed(messageId)
                    }
                    encodedId = messageId
                    addressKind = .gmailContainedMessage
                    mintedUidValidity = nil
                case .outlook(let graphId):
                    guard !graphId.isEmpty else {
                        throw ProviderError.actionIdentityResolutionFailed(graphId)
                    }
                    encodedId = graphId
                    addressKind = .providerResource
                    mintedUidValidity = nil
                case .demo(let localId):
                    guard !localId.isEmpty else {
                        throw ProviderError.actionIdentityResolutionFailed(localId)
                    }
                    encodedId = localId
                    addressKind = .providerResource
                    mintedUidValidity = nil
                }

                // Display removal follows only an exact provider-native header id.
                let exactHeaderId = "\(accountId):\(folderPath):\(encodedId)"
                if try MessageHeader.deleteOne(db, key: exactHeaderId) {
                    _ = try MessageBody.deleteOne(
                        db, key: ContentKey(rawValue: exactHeaderId))
                }
                if let draftId, let instanceEpoch {
                    let placeholder = PendingOperation.draftPlaceholderHeaderPK(
                        accountId: accountId,
                        draftsFolderPath: folderPath,
                        draftId: draftId,
                        instanceEpoch: instanceEpoch)
                    if try MessageHeader.deleteOne(db, key: placeholder) {
                        _ = try MessageBody.deleteOne(
                            db, key: ContentKey(rawValue: placeholder))
                    }
                }

                var deleteDraftOp = PendingOperation(
                    type: .deleteDraft,
                    messageIds: [encodedId],
                    accountId: accountId,
                    folderPath: folderPath,
                    observedUidValidity: mintedUidValidity,
                    draftServerUidValidity: mintedUidValidity,
                    instanceEpoch: instanceEpoch,
                    draftId: draftId,
                    draftDeleteAddressKind: addressKind
                )
                try deleteDraftOp.insert(db)
                if deleteOwnedLocalDraft {
                    guard let draftId,
                          let instanceEpoch,
                          let owned = try Draft.fetchOne(db, key: draftId),
                          owned.accountId == accountId,
                          owned.instanceEpoch == instanceEpoch else {
                        throw DraftStore.DraftEpochAdmissionError.staleOrReserved
                    }
                    let dir = owned.attachmentsDirName
                    try DraftStore.applyDelete(
                        id: draftId,
                        expectedInstanceEpoch: instanceEpoch,
                        db: db)
                    return dir
                }
                return nil
            }
            if let deletedAttachmentDir {
                DraftAttachmentStorage.deleteAttachments(dirName: deletedAttachmentDir)
            }
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            Task { await drainPendingQueue() }
            return true
        } catch {
            print("[Queue] ERROR: queueDraftDelete failed: \(error)")
            return false
        }
    }
}
