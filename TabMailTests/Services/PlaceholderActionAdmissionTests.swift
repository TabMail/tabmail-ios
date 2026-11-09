/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A local placeholder row (`sent-…` for the optimistic Sent copy of a sent
/// message, `draft-…` for a draft the server has not saved yet) has no address
/// on any server.
///
/// THE PROPERTY: on a provider that talks to a server, no action ever hands a
/// placeholder id to the provider, and nothing changes locally or is recorded as
/// done for a placeholder row the action did not reach. Once a draft save lands,
/// its row carries the server's id in the same write that records the save, so
/// an action on it reaches the real message. On the demo account the mailbox is
/// the local database and nothing ever replaces a placeholder, so there the row
/// is the message and every action on it lands. Each refusal check runs the same
/// action on a real row too, so no check here is vacuous.
@Suite("A local placeholder row never reaches the provider", .serialized, .processGlobalState)
struct PlaceholderActionAdmissionTests {
    /// Every producer that admits a message action through
    /// `AccountManager.admittedOrdinaryActionTargets`.
    enum Action: String, CaseIterable, Sendable {
        case agentDelete, userMove, markUnread, flag
        case applyLabel, removeLabel, removeUserLabel, replyFlag

        /// The actions that take several rows in one gesture.
        static let multiRow: [Action] = [.agentDelete, .userMove, .markUnread, .flag]
    }

    enum Placeholder: String, CaseIterable, Sendable {
        case sent, draft
    }

    /// The runtime kinds. Demo is stored as IMAP but admitted by provider id,
    /// so it is its own case.
    enum Kind: String, CaseIterable, Sendable {
        case gmail, outlook, imap, demo

        /// The kinds whose provider talks to a server.
        static let server: [Kind] = [.gmail, .outlook, .imap]

        var accountProvider: AccountProvider {
            switch self {
            case .gmail: .gmail
            case .outlook: .outlook
            case .imap, .demo: .imap
            }
        }

        var runtimeKind: DraftRuntimeIdentityKind {
            switch self {
            case .gmail: .gmail
            case .outlook: .outlook
            case .imap: .imap
            case .demo: .demo
            }
        }

        func accountId(_ suffix: String) -> String {
            self == .demo ? DemoSeed.demoAccountId : "placeholder-\(rawValue)-\(suffix)"
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let kind: Kind
        let placeholder: Placeholder
        let action: Action
        var testDescription: String { "\(kind.rawValue) \(placeholder.rawValue) \(action.rawValue)" }
    }

    /// A user move out of Drafts is refused before admission for every row
    /// (only Trash is allowed there), so that one combination is left out.
    private static func cases(_ actions: [Action]) -> [Case] {
        Kind.server.flatMap { kind in
            Placeholder.allCases.flatMap { placeholder in
                actions
                    .filter { !(placeholder == .draft && $0 == .userMove) }
                    .map { Case(kind: kind, placeholder: placeholder, action: $0) }
            }
        }
    }

    static let everyActionCases = cases(Action.allCases)
    static let multiRowCases = cases(Action.multiRow)

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let kind: Kind
    }

    private static let folders: [(String, FolderRole)] = [
        ("INBOX", .inbox), ("SENT", .sent), ("DRAFT", .drafts), ("TRASH", .trash), ("Projects", .custom),
    ]
    private static let draftsPath = "DRAFT"
    /// The mailbox epoch every IMAP folder reports in these fixtures.
    private static let imapEpoch = 7

    @MainActor
    private func fixture(kind: Kind, suffix: String) throws -> Fixture {
        let accountId = kind.accountId(suffix)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "placeholder-\(kind.rawValue)@example.com", displayName: "Placeholder",
                provider: kind.accountProvider)
            account.id = accountId
            try account.insert(db)
            for (path, role) in Self.folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                if kind == .imap { folder.lastKnownUidValidity = Self.imapEpoch }
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId, kind: kind)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// A row as production leaves it: read (the Sent copy and a draft's row are
    /// both written read), and on IMAP a real row carries the epoch its folder
    /// listing reported. A placeholder never does.
    private func seedHeader(_ fixture: Fixture, messageId: String, folderPath: String) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "placeholder \(messageId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "placeholder",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: folderPath),
            accountId: fixture.accountId,
            folderPath: folderPath,
            isInInbox: false)
        header.rfc822MessageId = "\(UUID().uuidString)@example.com"
        header.headerComplete = true
        header.isRead = true
        if fixture.kind == .imap, !isSyntheticPlaceholderId(messageId) {
            header.observedUidValidity = Self.imapEpoch
        }
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
        return seeded
    }

    /// A provider id for a real row: a UID on IMAP, an opaque id elsewhere.
    private func realProviderId(_ kind: Kind) -> String {
        kind == .imap ? String(Int.random(in: 900_000...999_999)) : "real-\(UUID().uuidString.prefix(8))"
    }

    private func placeholderId(_ placeholder: Placeholder) -> String {
        placeholder == .sent
            ? "sent-\(UUID().uuidString)"
            : PendingOperation.draftPlaceholderMessageId(draftId: UUID().uuidString, instanceEpoch: "epoch-1")
    }

    @MainActor
    private func drainToQuiescence(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            let isEmpty = try await fixture.pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Acting on a placeholder alone

    private struct Labels {
        /// Applied to every seeded row, so removing it is a real change.
        let applied: UserLabel
        /// Applied to no row, so applying it is a real change.
        let fresh: UserLabel
    }

    private func seedLabels(_ fixture: Fixture, on rows: [MessageHeader]) throws -> Labels {
        let labels = Labels(
            applied: UserLabel(accountId: fixture.accountId, providerLabelId: "lbl-applied", name: "Applied", isSystem: false),
            fresh: UserLabel(accountId: fixture.accountId, providerLabelId: "lbl-fresh", name: "Fresh", isSystem: false))
        try fixture.pool.writeWithoutTransaction { db in
            try labels.applied.insert(db)
            try labels.fresh.insert(db)
            for row in rows {
                try MessageUserLabel(messageId: row.id, userLabelId: labels.applied.id).insert(db)
            }
        }
        return labels
    }

    /// Everything an action can change on a row locally.
    private struct RowState: Equatable {
        let folderPath: String
        let isRead: Bool
        let isFlagged: Bool
        let isReplied: Bool
        let labelIds: Set<String>
    }

    private func rowState(_ fixture: Fixture, _ headerId: String) async throws -> RowState? {
        try await fixture.pool.read { db in
            guard let header = try MessageHeader.fetchOne(db, key: headerId) else { return nil }
            let labelIds = try String.fetchAll(
                db, sql: "SELECT userLabelId FROM messageUserLabel WHERE messageId = ?", arguments: [headerId])
            return RowState(
                folderPath: header.folderPath, isRead: header.isRead, isFlagged: header.isFlagged,
                isReplied: header.isReplied, labelIds: Set(labelIds))
        }
    }

    /// Runs `action` on `header` through its production producer. Returns the
    /// agent's admission for the agent delete, `nil` otherwise.
    @MainActor
    private func perform(
        _ action: Action, on header: MessageHeader, labels: Labels, fixture f: Fixture
    ) async throws -> RoleMoveAdmission? {
        var admission: RoleMoveAdmission?
        switch action {
        case .agentDelete:
            admission = await AccountManager.shared.performCoordinatedRoleMove(
                ids: [header.id], role: .trash, expectedIdentities: [:])
        case .userMove:
            await AccountManager.shared.move([header], to: "Projects")
        case .markUnread:
            await AccountManager.shared.markUnread([header])
        case .flag:
            await AccountManager.shared.markFlagged([header], flagged: true)
        case .applyLabel:
            _ = await UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header)).applyLabel(labels.fresh)
        case .removeLabel:
            _ = await UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: header)).removeLabel(labels.applied)
        case .removeUserLabel:
            let folder = try #require(try await f.pool.read { db in
                try Folder.fetchOne(db, key: header.folderId)
            })
            let vm = InboxViewModel(folders: [folder])
            await vm.removeUserLabel(labels.applied, from: MessageSnapshot(from: header))
        case .replyFlag:
            // A reply to `header` has been sent and appended: the outbox
            // completion flags the original as replied.
            var outbox = OutboxMessage(
                accountId: f.accountId,
                draft: DraftMessage(
                    to: ["sender@example.com"], subject: "Re: \(header.subject)", body: "reply",
                    inReplyTo: "<\(header.rfc822MessageId ?? "")>"),
                originalMessageHeaderId: header.id,
                isForward: false)
            outbox.status = OutboxStatus.sending.rawValue
            outbox.sentAt = Date()
            outbox.appendedToSent = true
            let sent = outbox
            try await f.pool.writeWithoutTransaction { db in try sent.insert(db) }
            _ = try await f.pool.write { db in
                try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
            }
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        return admission
    }

    /// No provider is registered here, so every op an action queues stays in the
    /// queue, and the queue is exactly what would reach the provider.
    @Test("An action on a placeholder alone queues nothing and changes nothing; the same action on a real row lands",
          arguments: everyActionCases)
    @MainActor
    func placeholderAloneIsRefused(_ testCase: Case) async throws {
        let folderPath = testCase.placeholder == .sent ? "SENT" : Self.draftsPath
        let placeholderId = placeholderId(testCase.placeholder)
        try #require(isSyntheticPlaceholderId(placeholderId))
        let realId = realProviderId(testCase.kind)

        let f = try fixture(
            kind: testCase.kind,
            suffix: "alone-\(testCase.placeholder.rawValue)-\(testCase.action.rawValue)")
        let placeholder = try seedHeader(f, messageId: placeholderId, folderPath: folderPath)
        let real = try seedHeader(f, messageId: realId, folderPath: folderPath)
        let labels = try seedLabels(f, on: [placeholder, real])

        let placeholderBefore = try await rowState(f, placeholder.id)
        let admission = try await perform(testCase.action, on: placeholder, labels: labels, fixture: f)

        let queued = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(queued.isEmpty,
                "an action on a placeholder queued \(queued.map { "\($0.type) \($0.messageIds)" })")
        let placeholderAfter = try await rowState(f, placeholder.id)
        #expect(placeholderAfter == placeholderBefore,
                "the placeholder row changed locally: \(String(describing: placeholderBefore)) -> \(String(describing: placeholderAfter))")
        if let admission {
            #expect(admission.pendingIds.contains(placeholder.id),
                    "the agent was not told the placeholder is pending: \(admission.diagnosticSummary)")
            #expect(!admission.admittedIds.contains(placeholder.id), "\(admission.diagnosticSummary)")
            #expect(!admission.failedIds.contains(placeholder.id), "\(admission.diagnosticSummary)")
        }

        // Control: the same action on a real row is admitted, so the refusal
        // above is the placeholder's, not the action's.
        let realBefore = try await rowState(f, real.id)
        let realAdmission = try await perform(testCase.action, on: real, labels: labels, fixture: f)
        let realAfter = try await rowState(f, real.id)
        #expect(realAfter != realBefore, "precondition: the action did not change the real row")
        let realOps = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(realOps.contains { $0.messageIds.contains(realId) },
                "precondition: the action on the real row queued nothing: \(realOps.map { "\($0.type) \($0.messageIds)" })")
        #expect(!realOps.contains { $0.messageIds.contains(placeholderId) })
        if let realAdmission {
            #expect(realAdmission.admittedIds.contains(real.id), "\(realAdmission.diagnosticSummary)")
        }
        await finish(f)
    }

    // MARK: - A placeholder and a real message in one gesture

    @Test("No action hands a placeholder id to the provider, and the real message in the same action lands",
          arguments: multiRowCases)
    @MainActor
    func placeholderNeverReachesTheProvider(_ testCase: Case) async throws {
        let folderPath = testCase.placeholder == .sent ? "SENT" : Self.draftsPath
        let placeholderId = placeholderId(testCase.placeholder)
        try #require(isSyntheticPlaceholderId(placeholderId))
        let realId = realProviderId(testCase.kind)

        let mock = MockEmailProvider()
        let f = try fixture(
            kind: testCase.kind,
            suffix: "\(testCase.placeholder.rawValue)-\(testCase.action.rawValue)")
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: mock)
        let placeholder = try seedHeader(f, messageId: placeholderId, folderPath: folderPath)
        let real = try seedHeader(f, messageId: realId, folderPath: folderPath)
        let placeholderBefore = try await rowState(f, placeholder.id)

        switch testCase.action {
        case .agentDelete:
            let admission = await AccountManager.shared.performCoordinatedRoleMove(
                ids: [placeholder.id, real.id], role: .trash, expectedIdentities: [:])
            #expect(admission.pendingIds.contains(placeholder.id),
                    "the placeholder was not reported pending: \(admission.diagnosticSummary)")
            #expect(!admission.admittedIds.contains(placeholder.id),
                    "the placeholder was reported as deleted: \(admission.diagnosticSummary)")
            #expect(!admission.failedIds.contains(placeholder.id),
                    "the placeholder was reported as permanently failed: \(admission.diagnosticSummary)")
            #expect(admission.admittedIds.contains(real.id),
                    "precondition: the real message was not admitted: \(admission.diagnosticSummary)")
        case .userMove:
            await AccountManager.shared.move([placeholder, real], to: "Projects")
        case .markUnread:
            await AccountManager.shared.markUnread([placeholder, real])
        case .flag:
            await AccountManager.shared.markFlagged([placeholder, real], flagged: true)
        case .applyLabel, .removeLabel, .removeUserLabel, .replyFlag:
            Issue.record("single-row action in the multi-row matrix")
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)

        let calls = await mock.callLog
        #expect(!calls.contains { $0.contains(placeholderId) },
                "a placeholder id reached the provider: \(calls)")
        #expect(calls.contains { $0.contains(realId) },
                "precondition: the real message in the same action never reached the provider: \(calls)")
        let placeholderAfter = try await rowState(f, placeholder.id)
        #expect(placeholderAfter == placeholderBefore,
                "the placeholder row changed locally: \(String(describing: placeholderBefore)) -> \(String(describing: placeholderAfter))")
        await finish(f)
    }

    // MARK: - A landed draft save re-keys the row, and an action reaches it

    private struct SavedDraft {
        let draftId: String
        let placeholderHeaderId: String
    }

    /// A local draft and its placeholder row, as `queueDraftSave` leaves them
    /// before the server has answered.
    private func seedUnsavedDraft(
        _ fixture: Fixture, epoch: String = "E1", serverDraftId: String? = nil
    ) throws -> SavedDraft {
        let draftId = UUID().uuidString
        var draft = Draft(
            id: draftId, accountId: fixture.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: "body", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: serverDraftId, serverPushStatus: "dirty",
            rfc822MessageId: "old-\(draftId)@example.com", attachmentsDirName: nil)
        draft.instanceEpoch = epoch
        let inserted = draft
        try fixture.pool.writeWithoutTransaction { db in try inserted.insert(db) }
        let placeholder = try seedHeader(
            fixture,
            messageId: PendingOperation.draftPlaceholderMessageId(draftId: draftId, instanceEpoch: epoch),
            folderPath: Self.draftsPath)
        let expectedId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: fixture.accountId, draftsFolderPath: Self.draftsPath,
            draftId: draftId, instanceEpoch: epoch)
        try #require(placeholder.id == expectedId)
        return SavedDraft(draftId: draftId, placeholderHeaderId: placeholder.id)
    }

    private func createdAddress(_ kind: Kind, realId: String) -> DraftCreatedAddress {
        switch kind {
        case .gmail: .gmail(resourceId: "r-\(realId)", containedMessageId: realId)
        case .outlook: .outlook(graphId: realId)
        case .imap: .imap(folder: Self.draftsPath, uidValidity: Self.imapEpoch, uid: Int(realId) ?? 0)
        case .demo: .demo(localId: realId)
        }
    }

    @Test("After a draft save lands, its row carries the server id and an agent delete reaches that id",
          arguments: Kind.server)
    @MainActor
    func landedSaveIsActionable(_ kind: Kind) async throws {
        let f = try fixture(kind: kind, suffix: "landed")
        let saved = try seedUnsavedDraft(f)
        let realId = realProviderId(kind)
        // The placeholder is searchable before the save, as an unsaved draft is.
        let placeholderKey = ContentKey(rawValue: saved.placeholderHeaderId)
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                contentKey: placeholderKey, headerId: saved.placeholderHeaderId,
                messageId: PendingOperation.draftPlaceholderMessageId(draftId: saved.draftId, instanceEpoch: "E1"),
                subject: "subject", from: "Sender <sender@example.com>",
                to: "recipient@example.com", cc: "", bcc: "",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: f.accountId, folderPath: Self.draftsPath))
        ])
        let indexedBefore = try? await SearchIndex.shared.testRowidForHeader(placeholderKey)
        #expect(indexedBefore != nil, "precondition: the placeholder is indexed")

        let mock = MockEmailProvider(saveDraftResult: .created(createdAddress(kind, realId: realId)))
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: mock)

        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: saved.draftId, expectedInstanceEpoch: "E1", provider: mock,
            runtimeKind: kind.runtimeKind, draftsFolderPath: Self.draftsPath)
        #expect(result == .completed)

        let realHeaderId = MessageIdentity.headerId(
            accountId: f.accountId, folderPath: Self.draftsPath, messageId: realId)
        let (placeholderLeft, rekeyed) = try await f.pool.read { db in
            (try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId),
             try MessageHeader.fetchOne(db, key: realHeaderId))
        }
        #expect(placeholderLeft == nil, "the placeholder row survived a landed save")
        let row = try #require(rekeyed, "the landed save left no row under the server id")
        #expect(row.messageId == realId)

        // The saved draft stays searchable, now under its server id.
        let serverKey = ContentKey(rawValue: realHeaderId)
        let indexedAtServer = try? await SearchIndex.shared.testRowidForHeader(serverKey)
        let indexedAtPlaceholder = try? await SearchIndex.shared.testRowidForHeader(placeholderKey)
        #expect(indexedAtServer != nil, "the saved draft dropped out of search")
        #expect(indexedAtPlaceholder == nil, "the search row still names the placeholder")

        if kind == .imap {
            // A re-keyed IMAP row has its UID but no listed epoch until the
            // folder's next sync stamps one; admission waits for that stamp.
            // Stamp it as that sync would, so the action below is admitted.
            try await f.pool.write { db in
                try db.execute(
                    sql: "UPDATE messageHeader SET observedUidValidity = ? WHERE id = ?",
                    arguments: [Self.imapEpoch, realHeaderId])
            }
        }

        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: [realHeaderId], role: .trash, expectedIdentities: [:])
        #expect(admission.admittedIds == [realHeaderId], "\(admission.diagnosticSummary)")
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)

        let calls = await mock.callLog
        #expect(calls.contains { $0.hasPrefix("move(") && $0.contains(realId) },
                "the delete never reached the server's id: \(calls)")
        #expect(!calls.contains { $0.contains("draft-") }, "a placeholder id reached the provider: \(calls)")
        try? await SearchIndex.shared.removeMessages(contentKeys: [serverKey, placeholderKey])
        await finish(f)
    }

    @Test("A Gmail save without a contained message id leaves the placeholder, which an agent delete reports pending")
    @MainActor
    func gmailUnrekeyedPlaceholderStaysPending() async throws {
        let f = try fixture(kind: .gmail, suffix: "unrekeyed")
        let saved = try seedUnsavedDraft(f)
        let resourceId = "r-\(UUID().uuidString.prefix(8))"
        let mock = MockEmailProvider(
            saveDraftResult: .created(.gmail(resourceId: resourceId, containedMessageId: nil)))
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: mock)

        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: saved.draftId, expectedInstanceEpoch: "E1", provider: mock,
            runtimeKind: .gmail, draftsFolderPath: Self.draftsPath)
        #expect(result == .completed)
        let draft = try await f.pool.read { db in try Draft.fetchOne(db, key: saved.draftId) }
        #expect(draft?.serverDraftId == resourceId)

        let realId = realProviderId(.gmail)
        let real = try seedHeader(f, messageId: realId, folderPath: Self.draftsPath)
        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: [saved.placeholderHeaderId, real.id], role: .trash, expectedIdentities: [:])
        #expect(admission.pendingIds.contains(saved.placeholderHeaderId), "\(admission.diagnosticSummary)")
        #expect(!admission.admittedIds.contains(saved.placeholderHeaderId), "\(admission.diagnosticSummary)")
        #expect(!admission.failedIds.contains(saved.placeholderHeaderId), "\(admission.diagnosticSummary)")
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)

        let calls = await mock.callLog
        #expect(!calls.contains { $0.contains("draft-") }, "a placeholder id reached the provider: \(calls)")
        #expect(!calls.contains { $0.hasPrefix("move(") && $0.contains(resourceId) },
                "a draft resource id was used as a message id: \(calls)")
        #expect(calls.contains { $0.contains(realId) },
                "precondition: the real message in the same action never reached the provider: \(calls)")
        let after = try await f.pool.read { db in try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId) }
        #expect(after?.folderPath == Self.draftsPath)
        await finish(f)
    }

    // MARK: - A re-save onto a server row the Drafts sync already listed

    @Test("An Outlook re-save whose server row is already listed drops the placeholder and its content, and an action reaches the server id")
    @MainActor
    func resaveOntoListedServerRowReleasesThePlaceholder() async throws {
        let f = try fixture(kind: .outlook, suffix: "resave")
        let realId = realProviderId(.outlook)
        // The draft was saved before under `realId`, and the Drafts sync listed
        // that server row. The user edited the draft again, so a new epoch's
        // placeholder row stands beside it.
        let listed = try seedHeader(f, messageId: realId, folderPath: Self.draftsPath)
        let saved = try seedUnsavedDraft(f, epoch: "E2", serverDraftId: realId)
        let placeholderKey = ContentKey(rawValue: saved.placeholderHeaderId)
        try await f.pool.write { db in
            try db.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, attachmentsJSON, fetchedAt, icsText)
                VALUES (?, '<p>edited</p>', NULL, ?, NULL)
                """, arguments: [placeholderKey.rawValue, Date()])
        }
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                contentKey: placeholderKey, headerId: saved.placeholderHeaderId,
                messageId: PendingOperation.draftPlaceholderMessageId(draftId: saved.draftId, instanceEpoch: "E2"),
                subject: "subject", from: "Sender <sender@example.com>",
                to: "recipient@example.com", cc: "", bcc: "",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: f.accountId, folderPath: Self.draftsPath))
        ])
        let indexedBefore = try? await SearchIndex.shared.testRowidForHeader(placeholderKey)
        #expect(indexedBefore != nil, "precondition: the placeholder is indexed")

        let mock = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: realId)))
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: mock)
        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: saved.draftId, expectedInstanceEpoch: "E2", provider: mock,
            runtimeKind: .outlook, draftsFolderPath: Self.draftsPath)
        #expect(result == .completed)

        let (draft, placeholderLeft, serverRow, body) = try await f.pool.read { db in
            (try Draft.fetchOne(db, key: saved.draftId),
             try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId),
             try MessageHeader.fetchOne(db, key: listed.id),
             try MessageBody.fetchOne(db, key: placeholderKey))
        }
        #expect(draft?.serverPushStatus == "pushed")
        #expect(draft?.serverDraftId == realId)
        #expect(placeholderLeft == nil, "the placeholder row survived the re-save")
        #expect(serverRow?.messageId == realId, "the listed server row was lost")
        #expect(body == nil, "the placeholder's cached body was left behind")
        let indexedAfter = try? await SearchIndex.shared.testRowidForHeader(placeholderKey)
        #expect(indexedAfter == nil, "the placeholder is still in the search index")

        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: [listed.id], role: .trash, expectedIdentities: [:])
        #expect(admission.admittedIds == [listed.id], "\(admission.diagnosticSummary)")
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)
        let calls = await mock.callLog
        #expect(calls.contains { $0.hasPrefix("move(") && $0.contains(realId) },
                "the delete never reached the server's id: \(calls)")
        #expect(!calls.contains { $0.contains("draft-") }, "a placeholder id reached the provider: \(calls)")

        try? await SearchIndex.shared.removeMessages(contentKeys: [placeholderKey])
        await finish(f)
    }

    // MARK: - The save and the row's re-key are one write

    @Test("A save whose re-key cannot be written records no server copy, and the retry lands both")
    @MainActor
    func saveAndRekeyAreOneWrite() async throws {
        let f = try fixture(kind: .outlook, suffix: "one-write")
        let saved = try seedUnsavedDraft(f)
        let realId = realProviderId(.outlook)
        let mock = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: realId)))

        // Refuse the re-keyed row once, so the write carrying it fails.
        try await f.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_rekey BEFORE INSERT ON messageHeader
                WHEN NEW.messageId = '\(realId)'
                BEGIN SELECT RAISE(ABORT, 'refused re-key'); END
                """)
        }
        await #expect(throws: (any Error).self) {
            _ = try await DraftStore.shared.pushDraftToServer(
                draftId: saved.draftId, expectedInstanceEpoch: "E1", provider: mock,
                runtimeKind: .outlook, draftsFolderPath: Self.draftsPath)
        }

        // THE PROPERTY: the draft never records a server copy while its row
        // still carries the placeholder id.
        let (draft, placeholder) = try await f.pool.read { db in
            (try Draft.fetchOne(db, key: saved.draftId),
             try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId))
        }
        #expect(placeholder != nil, "the placeholder row was lost with the failed write")
        #expect(draft?.serverDraftId == nil,
                "the draft records server copy \(String(describing: draft?.serverDraftId)) while its row is still a placeholder")
        #expect(draft?.serverPushStatus != "pushed")

        try await f.pool.write { db in try db.execute(sql: "DROP TRIGGER refuse_rekey") }
        let retry = try await DraftStore.shared.pushDraftToServer(
            draftId: saved.draftId, expectedInstanceEpoch: "E1", provider: mock,
            runtimeKind: .outlook, draftsFolderPath: Self.draftsPath)
        #expect(retry == .completed)
        let realHeaderId = MessageIdentity.headerId(
            accountId: f.accountId, folderPath: Self.draftsPath, messageId: realId)
        let (landed, rekeyed, placeholderAfter) = try await f.pool.read { db in
            (try Draft.fetchOne(db, key: saved.draftId),
             try MessageHeader.fetchOne(db, key: realHeaderId),
             try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId))
        }
        #expect(landed?.serverDraftId == realId)
        #expect(rekeyed?.messageId == realId)
        #expect(placeholderAfter == nil)
        await finish(f)
    }

    // MARK: - Demo: the mailbox is local, so the placeholder is the message

    @Test("Only the local demo provider can act on a placeholder id, and each account resolves to its provider")
    func placeholderAddressabilityIsAProviderProperty() {
        #expect(DemoProvider.placeholderIdsAreAddressable)
        #expect(!GmailProvider.placeholderIdsAreAddressable)
        #expect(!ExchangeProvider.placeholderIdsAreAddressable)
        #expect(!IMAPProvider.placeholderIdsAreAddressable)
        #expect(!MockEmailProvider.placeholderIdsAreAddressable)

        // Each account kind answers through the provider type that serves it:
        // only the demo account, stored as IMAP, can act on a placeholder.
        func account(_ provider: AccountProvider, demo: Bool = false) -> Account {
            var a = Account(emailAddress: "user@example.com", displayName: "User", provider: provider)
            if demo { a.id = DemoSeed.demoAccountId }
            return a
        }
        for kind: AccountProvider in [.gmail, .outlook, .imap, .icloud, .caldav] {
            #expect(!placeholderIdsAreAddressable(for: account(kind)), "\(kind)")
        }
        #expect(placeholderIdsAreAddressable(for: account(.imap, demo: true)))
    }

    @Test("In Demo Mode the Sent copy of a sent message can be marked, flagged and deleted")
    @MainActor
    func demoSentCopyIsActionable() async throws {
        let f = try fixture(kind: .demo, suffix: "sent")
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: DemoProvider(accountId: f.accountId))

        // Send through the real outbox: the demo has no server, so the
        // optimistic Sent copy is the only copy there will ever be.
        let draftId = UUID().uuidString
        try await f.pool.writeWithoutTransaction { db in
            var draft = Draft(
                id: draftId, accountId: f.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Demo send", body: "hello", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 1)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let account = try #require(try await f.pool.read { db in try Account.fetchOne(db, key: f.accountId) })
        let queued = try await AccountManager.shared.queueSend(
            draft: DraftMessage(to: ["someone@example.com"], subject: "Demo send", body: "hello"),
            from: account, draftId: draftId, instanceEpoch: "E1", holdsForUndo: false)
        var sentCopy: MessageHeader?
        for _ in 0..<200 {
            sentCopy = try await f.pool.read { db in
                try MessageHeader
                    .filter(Column("accountId") == f.accountId && Column("folderPath") == "SENT")
                    .fetchOne(db)
            }
            if sentCopy != nil { break }
            await AccountManager.shared.drainOutbox()
            try await Task.sleep(for: .milliseconds(25))
        }
        let copy = try #require(sentCopy, "the demo send left no Sent copy")
        #expect(copy.messageId == "sent-\(queued.outboxId)")
        #expect(isSyntheticPlaceholderId(copy.messageId), "precondition: the Sent copy is a placeholder id")

        await AccountManager.shared.markUnread([copy])
        await AccountManager.shared.markFlagged([copy], flagged: true)
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)
        let marked = try await rowState(f, copy.id)
        #expect(marked?.isRead == false, "mark unread did not land on the demo Sent copy")
        #expect(marked?.isFlagged == true, "flag did not land on the demo Sent copy")

        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: [copy.id], role: .trash, expectedIdentities: [:])
        #expect(admission.admittedIds == [copy.id], "\(admission.diagnosticSummary)")
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)
        let deleted = try await rowState(f, copy.id)
        #expect(deleted?.folderPath == "TRASH", "the agent delete did not land on the demo Sent copy")
        let left = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(left == 0, "an op on the demo Sent copy never retired")
        await finish(f)
    }

    @Test("In Demo Mode a saved draft's row is the demo copy, and an agent delete lands on it")
    @MainActor
    func demoSavedDraftIsActionable() async throws {
        let f = try fixture(kind: .demo, suffix: "draft")
        let demo = DemoProvider(accountId: f.accountId)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: demo)
        let saved = try seedUnsavedDraft(f)

        let result = try await DraftStore.shared.pushDraftToServer(
            draftId: saved.draftId, expectedInstanceEpoch: "E1", provider: demo,
            runtimeKind: .demo, draftsFolderPath: Self.draftsPath)
        #expect(result == .completed)
        let (draft, placeholderLeft) = try await f.pool.read { db in
            (try Draft.fetchOne(db, key: saved.draftId),
             try MessageHeader.fetchOne(db, key: saved.placeholderHeaderId))
        }
        #expect(placeholderLeft == nil, "the placeholder row survived the demo save")
        let localId = try #require(draft?.serverDraftId, "the demo save recorded no copy")
        let rowId = MessageIdentity.headerId(
            accountId: f.accountId, folderPath: Self.draftsPath, messageId: localId)

        let admission = await AccountManager.shared.performCoordinatedRoleMove(
            ids: [rowId], role: .trash, expectedIdentities: [:])
        #expect(admission.admittedIds == [rowId], "\(admission.diagnosticSummary)")
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainToQuiescence(f)
        let after = try await rowState(f, rowId)
        #expect(after?.folderPath == "TRASH", "the agent delete did not land on the demo draft")
        await finish(f)
    }
}
