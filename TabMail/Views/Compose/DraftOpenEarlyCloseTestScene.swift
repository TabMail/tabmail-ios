/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import GRDB
import Synchronization

/// #309 fixture: a prepared draft open whose compose is held, and closed, before
/// it has bound its row. `--draft-open-early-close-empty-body` saves the draft with
/// an empty body. A database trace holds the compose's first read of the
/// row until "Release initial read", so the compose shows its first frame for as
/// long as a test reads it; the presenter, the compose and draft storage run
/// unchanged.
struct DraftOpenEarlyCloseTestScene: View {
    @State private var gate = InitialReadGate()
    @State private var navigationStore = NavigationStore()
    @State private var opening: PreparedDraftOpen?
    @State private var status = "Preparing early-close fixture"
    @State private var savedAt: Double?
    private static let accountID = "draft-early-close-account"
    private static let draftID = "draft-early-close-draft"
    private static let dirName = "draft-early-close-attachment"
    private static let body = ProcessInfo.processInfo.arguments.contains("--draft-open-early-close-empty-body")
        ? "" : "Keep this local attachment"
    private static let bytes = Data("unsubmitted local attachment bytes".utf8)

    var body: some View {
        VStack { Text(status); controls }
            .environment(navigationStore)
            .fullScreenCover(item: $opening) { item in
                DraftComposePresenter(source: item.source, prepared: item.outcome)
                    .environment(navigationStore)
                    // The compose's chat offers edits only with a session.
                    .environment(\.hasTabMailSession, true)
                    .overlay(alignment: .center) { controls }
            }
            .task { await setUp() }
    }

    private var controls: some View {
        VStack(spacing: 3) {
            HStack {
                Button("Release initial read") { gate.release() }
                Button("Inspect saved draft") { inspect() }
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in Text(gate.status) }
            Text(AISubscriptionGate.shared.isActive ? "subscription=active" : "subscription=inactive")
            Text(status)
        }
        .font(.caption2)
        .padding(6)
        .background(Color(.systemBackground))
    }

    private func setUp() async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config = Configuration()
            config.foreignKeysEnabled = true
            let gate = gate
            let draftID = Self.draftID
            config.prepareDatabase { db in
                db.trace(options: .statement) { event in gate.observe(event.expandedDescription, draftID: draftID) }
            }
            let pool = try DatabasePool(path: directory.appendingPathComponent("fixture.sqlite").path,
                                        configuration: config)
            let appDB = try AppDatabase(pool: pool, runStartupResets: false)
            AppDatabase.shared.withLock { $0 = appDB }
            var account = Account(emailAddress: "author@example.com", displayName: "Synthetic author", provider: .imap)
            account.id = Self.accountID
            let ownedAccount = account
            try DraftAttachmentStorage.saveAttachments([
                DraftAttachment(filename: "kept.txt", mimeType: "text/plain", data: Self.bytes)
            ], dirName: Self.dirName)
            let now = Date().timeIntervalSince1970
            var draft = Draft(id: draftID, accountId: Self.accountID,
                toJSON: Draft.encodeStringArray(["to-person@example.com"]),
                ccJSON: Draft.encodeStringArray(["cc-person@example.com"]),
                bccJSON: Draft.encodeStringArray(["bcc-person@example.com"]),
                subject: "Ready before inner load", body: Self.body, replyToId: nil,
                isForward: false, editHistoryJSON: nil, createdAt: now, updatedAt: now,
                serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil,
                attachmentsDirName: Self.dirName)
            draft.instanceEpoch = "early-close-generation"
            let ownedDraft = draft
            let accountID = Self.accountID
            try await pool.write { db in
                try ownedAccount.insert(db)
                let folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: accountID)
                try folder.insert(db)
                try ownedDraft.insert(db)
            }
            navigationStore.accounts = [account]
            // The compose's chat offers edits only to a subscriber; a fresh
            // simulator has none, and gate state persists across tests.
            AISubscriptionGate.shared.openGate()
            savedAt = now
            let outcome = await DraftOpenPreparation.prepare(.draftId(draftID))
            guard case .ready = outcome else { status = "Early-close preparation failed"; return }
            status = "Early-close fixture ready"
            gate.arm()
            // `--draft-open-changed-while-opening`: the first open finds the draft
            // changed, so its compose comes from the card's Try Again.
            let changed = ProcessInfo.processInfo.arguments.contains("--draft-open-changed-while-opening")
            opening = PreparedDraftOpen(source: .draftId(draftID),
                                        outcome: changed ? .unavailable(.changedWhileOpening) : outcome)
        } catch {
            status = "Early-close fixture error: \(error)"
        }
    }

    /// The saved row and its attachment, exactly as the fixture wrote them, and
    /// nothing queued to send.
    private func inspect() {
        do {
            let (row, queued) = try AppDatabase.dbPool.read {
                (try Draft.fetchOne($0, key: Self.draftID), try OutboxMessage.fetchCount($0))
            }
            let files = try DraftAttachmentStorage.loadAttachments(dirName: row?.attachmentsDirName)
            let unchanged = row?.body == Self.body && row?.updatedAt == savedAt
                && row?.attachmentsDirName == Self.dirName
                && files.count == 1 && files.first?.filename == "kept.txt" && files.first?.data == Self.bytes
                && queued == 0
            status = unchanged ? "Saved draft unchanged"
                : "Saved draft changed: row=\(row == nil ? "absent" : "present") files=\(files.count) queued=\(queued)"
        } catch {
            status = "Early-close inspection failed"
        }
    }
}

/// Holds the compose's first read of the fixture row (the one
/// `ComposeView.loadDraftOrPrepopulate` makes) until released.
private final class InitialReadGate: Sendable {
    private struct State: Sendable {
        var armed = false
        var phase = "waiting"
    }

    /// Bounds the hold, so a test that never releases it cannot hang the app.
    private static let holdLimitSeconds = 60
    private let state = Mutex(State())
    private let permit = DispatchSemaphore(value: 0)

    func arm() { state.withLock { $0.armed = true } }
    func release() { permit.signal() }
    var status: String { state.withLock { "initial=\($0.phase)" } }

    func observe(_ sql: String, draftID: String) {
        guard sql.contains("FROM \"draft\""), sql.contains(draftID),
              Thread.callStackSymbols.contains(where: { $0.contains("loadDraftOrPrepopulate") }) else { return }
        let hold = state.withLock { state -> Bool in
            guard state.armed, state.phase == "waiting" else { return false }
            state.phase = "held"
            return true
        }
        guard hold else { return }
        let result = permit.wait(timeout: .now() + .seconds(Self.holdLimitSeconds))
        state.withLock { $0.phase = result == .success ? "released" : "timed-out" }
    }
}
#endif
