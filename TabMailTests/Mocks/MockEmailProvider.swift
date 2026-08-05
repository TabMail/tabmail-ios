/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Configurable mock EmailProvider for testing services that depend on email operations.
/// Records all method calls for assertion. Can be configured to throw errors or return specific results.
actor MockEmailProvider: EmailProvider {
    // MARK: - Stale-detection window mode (configurable per test; .uid mimics IMAP)

    nonisolated let staleWindowMode: StaleWindowMode

    init(
        staleWindowMode: StaleWindowMode = .date,
        saveDraftResult: DraftSaveOutcome = .created(.outlook(graphId: "mock-draft-id")),
        saveDraftThrows: Error? = nil
    ) {
        self.staleWindowMode = staleWindowMode
        self.saveDraftResult = saveDraftResult
        self.saveDraftThrows = saveDraftThrows
    }

    // MARK: - UIDVALIDITY observation (the epoch test seam)

    /// Per-folder mocked `lastObservedUidValidity`. `Mutex`-backed nonisolated
    /// seam (mirrors `IMAPProvider.lastObservedUidValidityBox` — cited by
    /// SYMBOL, not line: `IMAPProvider.swift` grows on this branch and even a
    /// comment-only edit there shifts every line citation into it) — the
    /// protocol requirement is synchronous
    /// (`EmailProvider.lastObservedUidValidity(folderPath:)`; callers include a
    /// GRDB write closure, which cannot `await`), so an actor-isolated `var`
    /// cannot satisfy it.
    ///
    /// **Without this override the mock inherits the protocol's `nil` default
    /// (the `extension EmailProvider` implementation of the same requirement),
    /// and every mock-driven test of "capture the
    /// folder epoch" observes `nil` on BOTH sides of whatever it is comparing —
    /// passing without ever executing the branch it was written for.** That is
    /// the vacuous-assertion shape the plan's structural finding (c) names.
    ///
    /// REFERENCE (`v2final`, tag `e28dd4edb`): ported verbatim from
    /// `v2final:TabMailTests/Mocks/MockEmailProvider.swift:29-71`. This region is
    /// keying-agnostic — it is about the FOLDER epoch, not about message
    /// identity — so it needed no adaptation to v3's provider-id keying.
    private nonisolated let mockedUidValidityBox = Mutex<[String: UInt32]>([:])

    nonisolated func lastObservedUidValidity(folderPath: String) -> UInt32? {
        if let sequenced = mockedUidValiditySequenceBox.withLock({ box -> UInt32?? in
            guard var seq = box[folderPath], !seq.isEmpty else { return nil }
            let next = seq.removeFirst()
            box[folderPath] = seq
            return next
        }) {
            return sequenced
        }
        return mockedUidValidityBox.withLock { $0[folderPath] }
    }

    /// Test seam: configure the value `lastObservedUidValidity(folderPath:)`
    /// returns for `folderPath`. Pass `nil` to clear (simulates "never
    /// SELECTed this folder").
    func setMockedUidValidity(_ value: UInt32?, folderPath: String) {
        mockedUidValidityBox.withLock {
            if let value { $0[folderPath] = value } else { $0.removeValue(forKey: folderPath) }
        }
    }

    /// Test seam: a per-CALL sequence of values for
    /// `lastObservedUidValidity(folderPath:)` — each call CONSUMES the next
    /// entry; once exhausted, calls fall back to the static
    /// `setMockedUidValidity` value. Simulates the shared cross-connection
    /// mirror ADVANCING between a walk's own fetch (which must capture the
    /// epoch exactly once) and a later guard evaluation (which must NOT re-read
    /// the live mirror): sequence `[old]` + static `new` yields `old` exactly
    /// once — at capture time — and `new` for any subsequent (buggy) live
    /// re-read.
    private nonisolated let mockedUidValiditySequenceBox = Mutex<[String: [UInt32?]]>([:])

    func setMockedUidValiditySequence(_ values: [UInt32?], folderPath: String) {
        mockedUidValiditySequenceBox.withLock { $0[folderPath] = values }
    }

    /// The epoch `fetchMessagesWithObservedEpoch` reports as BOUND to its own
    /// fetch, independently of what the `lastObservedUidValidity` mirror answers.
    ///
    /// The two are separable in production — the mirror is written by every
    /// tracked SELECT of the path (the backfill walk's, and through
    /// `fetchMessageHeaders` also self-heal's and deep backfill's), so a
    /// concurrent SELECT can make it disagree with the SELECT that served THIS
    /// fetch — and a test that cannot separate them cannot tell which one a sync
    /// pass stamped.
    ///
    /// ⚠ When this box is UNSET the override below falls back to the mirror, and
    /// that fallback is the MOCK'S OWN choice, not the protocol's: the
    /// `extension EmailProvider` default pairs the fetch with an explicit `nil`
    /// and never touches the mirror (deliberately — see its comment). This mock
    /// overrides precisely because it is the double that MODELS an IMAP-like
    /// provider, and without the fallback every existing mock-driven epoch test —
    /// `MockProviderEpochSeamTests` above all, whose whole subject is that a
    /// mock-observed epoch reaches `Folder.lastKnownUidValidity` — would go
    /// vacuously green against a `nil` on both sides. Do not "simplify" this to
    /// match the protocol default; what a NON-overriding conformer produces is
    /// pinned separately by
    /// `SelectSourcedFolderEpochTests.aConformerThatDoesNotOverrideReportsNoEpoch`,
    /// against `DemoProvider`, so the two contracts are tested apart.
    private nonisolated let mockedBoundFetchEpochBox = Mutex<[String: UInt32?]>([:])

    func setMockedBoundFetchEpoch(_ value: UInt32?, folderPath: String) {
        mockedBoundFetchEpochBox.withLock { $0[folderPath] = value }
    }

    func fetchMessagesWithObservedEpoch(
        folder: String, limit: Int, offset: Int
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        let messages = try await fetchMessages(folder: folder, limit: limit, offset: offset)
        if let bound = mockedBoundFetchEpochBox.withLock({ $0[folder] }) {
            return (messages, bound)
        }
        return (messages, lastObservedUidValidity(folderPath: folder))
    }

    /// T4.S6b: the sample `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`
    /// FETCHes, per folder path, plus the epoch the SELECT that served it reported.
    ///
    /// **This override is MANDATORY, for the same reason
    /// `lastObservedUidValidity`'s is.** The `extension EmailProvider` default
    /// answers `([], nil)`, which the door reads as "the server reported no
    /// UIDVALIDITY ⇒ do nothing" — so a mock-driven test of the verified door would
    /// take the anti-brick leg and pass without ever executing the branch it was
    /// written for. Configure with `setMockedEpochSample`; UNCONFIGURED it keeps the
    /// protocol default's `([], nil)`, so every OTHER mock-driven suite (which never
    /// configures it) is unaffected by the door existing at all.
    ///
    /// The mock answers ONLY the UIDs it was asked for, from the configured set — a
    /// real server cannot return a UID the FETCH did not name, and a mock that
    /// returned extras would let a test "agree" on a row the door never sampled.
    private nonisolated let mockedEpochSampleBox = Mutex<[String: (messages: [MessageHeaderInfo], observedEpoch: UInt32?)]>([:])

    /// Records every `sampleHeadersForEpochVerification` call, in order, as
    /// `(folder, uids)`. The read side is how a test asserts that NO verification
    /// FETCH was issued (INV-4: a genuine first sync must not pay for one) and that
    /// a second cycle issues none (INV-6: no loop).
    private nonisolated let epochSampleCallsBox = Mutex<[(folder: String, uids: [UInt32])]>([])

    func setMockedEpochSample(
        messages: [MessageHeaderInfo], observedEpoch: UInt32?, folderPath: String
    ) {
        mockedEpochSampleBox.withLock { $0[folderPath] = (messages, observedEpoch) }
    }

    nonisolated func epochSampleCalls() -> [(folder: String, uids: [UInt32])] {
        epochSampleCallsBox.withLock { $0 }
    }

    func sampleHeadersForEpochVerification(
        folder: String, uids: [UInt32]
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        epochSampleCallsBox.withLock { $0.append((folder: folder, uids: uids)) }
        guard let configured = mockedEpochSampleBox.withLock({ $0[folder] }) else { return ([], nil) }
        let requested = Set(uids)
        return (configured.messages.filter { requested.contains(UInt32($0.messageId) ?? 0) },
                configured.observedEpoch)
    }

    // MARK: - Call Recording

    var callLog: [String] = []

    // MARK: - Configurable Results

    var connectThrows: Error?
    var disconnectThrows: Error?
    var fetchFoldersResult: [FolderInfo] = []
    var fetchFoldersThrows: Error?
    var fetchMessagesResult: [MessageHeaderInfo] = []
    var fetchMessagesThrows: Error?
    var fetchMessageResult: FullMessageInfo?
    var fetchMessageThrows: Error?
    var searchResult: [MessageHeaderInfo] = []
    var searchThrows: Error?
    var markReadThrows: Error?
    var markUnreadThrows: Error?
    var markFlaggedThrows: Error?
    var moveThrows: Error?
    /// Configures `move(ids:from:to:)` to simulate a batch that fails PARTWAY
    /// through (e.g. an IMAP MOVE command that drops the connection
    /// mid-batch): every id BEFORE `failingId` is recorded into `movedIds` as
    /// if it had already succeeded, then `error` is thrown once `failingId`
    /// is reached — ids at/after it are never attempted/recorded. Set via
    /// `setMoveThrowsOnId`, cleared via `clearMoveThrowsOnId`. Takes
    /// precedence over `moveThrows` when both are configured and `ids`
    /// contains the failing id.
    var moveThrowsOnId: (id: String, error: Error)?
    var sendThrows: Error?
    var appendToSentResult: Bool = true
    var appendToSentThrows: Error?
    var fetchHistoryResult: HistoryResponse?
    var fetchHistoryThrows: Error?
    var fetchMessageHeadersResult: [MessageHeaderInfo] = []
    var fetchMessageHeadersThrows: Error?

    // MARK: - Await-boundary hooks (the in-flight test seam)

    /// Awaited from INSIDE the corresponding provider call, so a test can act
    /// while that call is genuinely in flight — the durable row is claimed, the
    /// provider has been entered, and nothing has returned yet. Without them a
    /// test can only observe the before and after states and must infer the
    /// window between them, which is exactly where claim/epoch/identity races
    /// live.
    ///
    /// REFERENCE (`v2final`, tag `e28dd4edb`):
    /// `v2final:TabMailTests/Mocks/MockEmailProvider.swift:119-126` (the
    /// properties) and `:437-455` (the setters). Ported to the three calls the
    /// reference's own suites drive — `markRead`
    /// (`AccountManagerQueueDrainTests`, `AccountManagerQueueLivenessTests`),
    /// `saveDraft` (`AccountManagerQueueDrainTests`, three draft suites) and
    /// `move` (`AccountManagerQueueDemotionTests`,
    /// `AccountManagerQueueLivenessTests`, `InboxGestureActionTests`) — and to
    /// v3's own signatures, which differ from the reference's on `saveDraft`
    /// (v3 returns the typed `DraftSaveOutcome`).
    var markReadHook: (@Sendable () async -> Void)?
    var saveDraftHook: (@Sendable () async -> Void)?
    /// Awaited BEFORE `move()` records or mutates anything — lets a test
    /// suspend the provider call itself (not just the durable write queue) so
    /// it can observe/act while the claimed row is genuinely in flight. Never
    /// held while any gate is held: this fires entirely outside the queue's
    /// mutation gate, mirroring production.
    var moveHook: (@Sendable () async -> Void)?
    /// Awaited from INSIDE `send(draft:)`, AFTER the draft is recorded, so a
    /// test can act while the SMTP transaction is genuinely on the wire: the
    /// outbox row is claimed `.sending`, `sentAt` is still NULL (it is stamped
    /// only after this call RETURNS), and nothing downstream — Sent header, Sent
    /// APPEND, finalize — has happened. That window is where the outbox's
    /// reconcile-versus-drain hazard lives, and it cannot be observed from
    /// before/after states.
    var sendHook: (@Sendable () async -> Void)?

    // MARK: - Parameter Tracking

    var markedReadIds: [(ids: [String], folder: String)] = []
    var markedUnreadIds: [(ids: [String], folder: String)] = []
    var markedFlaggedIds: [(ids: [String], flagged: Bool, folder: String)] = []
    var movedIds: [(ids: [String], from: String, to: String)] = []
    var sentDrafts: [DraftMessage] = []
    var appendedToSent: [(draft: DraftMessage, sentFolderPath: String, messageId: String)] = []

    // MARK: - EmailProvider Protocol

    func connect() async throws {
        callLog.append("connect")
        if let error = connectThrows { throw error }
    }

    func disconnect() async throws {
        callLog.append("disconnect")
        if let error = disconnectThrows { throw error }
    }

    func fetchFolders() async throws -> [FolderInfo] {
        callLog.append("fetchFolders")
        if let error = fetchFoldersThrows { throw error }
        return fetchFoldersResult
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        callLog.append("fetchMessages(folder:\(folder),limit:\(limit),offset:\(offset))")
        if let error = fetchMessagesThrows { throw error }
        return fetchMessagesResult
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        callLog.append("fetchMessage(id:\(id),folder:\(folder))")
        if let error = fetchMessageThrows { throw error }
        guard let result = fetchMessageResult else {
            throw ProviderError.messageNotFound
        }
        return result
    }

    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] {
        callLog.append("search(query:\(query))")
        if let error = searchThrows { throw error }
        return searchResult
    }

    func markRead(ids: [String], folder: String) async throws {
        callLog.append("markRead(ids:\(ids),folder:\(folder))")
        markedReadIds.append((ids: ids, folder: folder))
        if let markReadHook { await markReadHook() }
        if let error = markReadThrows { throw error }
    }

    func markUnread(ids: [String], folder: String) async throws {
        callLog.append("markUnread(ids:\(ids),folder:\(folder))")
        markedUnreadIds.append((ids: ids, folder: folder))
        if let error = markUnreadThrows { throw error }
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        callLog.append("markFlagged(ids:\(ids),flagged:\(flagged),folder:\(folder))")
        markedFlaggedIds.append((ids: ids, flagged: flagged, folder: folder))
        if let error = markFlaggedThrows { throw error }
    }

    func move(ids: [String], from: String, to: String) async throws {
        callLog.append("move(ids:\(ids),from:\(from),to:\(to))")
        if let moveHook { await moveHook() }
        if let (failingId, error) = moveThrowsOnId, ids.contains(failingId) {
            // Partial-batch progress: record everything BEFORE the failing id
            // as if it had already succeeded on the wire (mirrors an IMAP
            // batch MOVE that aborts mid-command on a connection drop), then
            // throw. Ids at/after the failing one are never attempted.
            let succeededPrefix = Array(ids.prefix(while: { $0 != failingId }))
            if !succeededPrefix.isEmpty {
                movedIds.append((ids: succeededPrefix, from: from, to: to))
            }
            throw error
        }
        movedIds.append((ids: ids, from: from, to: to))
        if let error = moveThrows { throw error }
    }

    func send(draft: DraftMessage) async throws {
        callLog.append("send")
        sentDrafts.append(draft)
        if let hook = sendHook { await hook() }
        if let error = sendThrows { throw error }
    }

    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        callLog.append("appendToSentFolder(sentFolderPath:\(sentFolderPath),messageId:\(messageId))")
        appendedToSent.append((draft: draft, sentFolderPath: sentFolderPath, messageId: messageId))
        if let error = appendToSentThrows { throw error }
        return appendToSentResult
    }

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        callLog.append("fetchHistory(since:\(historyId))")
        if let error = fetchHistoryThrows { throw error }
        return fetchHistoryResult
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        callLog.append("fetchMessageHeaders(ids:\(ids))")
        if let error = fetchMessageHeadersThrows { throw error }
        return fetchMessageHeadersResult
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        callLog.append("fetchTextBodies(ids:\(ids.count),folder:\(folder))")
        return []
    }

    // MARK: - Draft Operations

    let saveDraftResult: DraftSaveOutcome
    let saveDraftThrows: Error?

    func saveDraft(_ draft: DraftMessage, existingIdentity: DraftDeleteIdentity?, draftsFolderPath: String) async throws -> DraftSaveOutcome {
        callLog.append("saveDraft(existingIdentity:\(String(describing: existingIdentity)),draftsFolderPath:\(draftsFolderPath))")
        if let saveDraftHook { await saveDraftHook() }
        if let error = saveDraftThrows { throw error }
        return saveDraftResult
    }

    func deleteDraft(identity: DraftDeleteIdentity) async throws {
        callLog.append("deleteDraft(identity:\(identity))")
    }

    // MARK: - Test Helpers

    /// Set moveThrows from outside the actor.
    func setMoveThrows(_ error: Error?) {
        moveThrows = error
    }

    /// See `moveThrowsOnId` doc comment.
    func setMoveThrowsOnId(_ id: String, error: Error) {
        moveThrowsOnId = (id, error)
    }

    /// Clears a previously configured `setMoveThrowsOnId` — simulates the
    /// failure condition clearing (e.g. connection restored) so a retry
    /// against the SAME mock instance succeeds and its call recordings
    /// (`movedIds`) accumulate across both attempts.
    func clearMoveThrowsOnId() {
        moveThrowsOnId = nil
    }

    func setMarkReadHook(_ hook: (@Sendable () async -> Void)?) {
        markReadHook = hook
    }

    func setSaveDraftHook(_ hook: (@Sendable () async -> Void)?) {
        saveDraftHook = hook
    }

    func setMoveHook(_ hook: (@Sendable () async -> Void)?) {
        moveHook = hook
    }

    func setSendHook(_ hook: (@Sendable () async -> Void)?) {
        sendHook = hook
    }

    /// Reset all recorded state.
    func reset() {
        callLog.removeAll()
        markedReadIds.removeAll()
        markedUnreadIds.removeAll()
        markedFlaggedIds.removeAll()
        movedIds.removeAll()
        sentDrafts.removeAll()
        appendedToSent.removeAll()
        markReadHook = nil
        saveDraftHook = nil
        moveHook = nil
        sendHook = nil
    }
}
