/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T2.6/T2.7 — observable claim-time and live-SELECT epoch checkpoints.
///
/// PORT: v2final `claimFrontierOperation` A4, `requireSameUidValidity`,
/// `withActionConnectionSelection`, and the move reassertions in `e70f674f3`
/// / `dad1b52f6`. SUBTRACT: RFC/hybrid compatibility, nil fail-open, demotion,
/// global FIFO, and ambient expectation state. ⚑ NO REFERENCE — INVENTED:
/// v3's provider/account classification and whole-op fail-closed adaptation.
@Suite("T2.6/T2.7 — IMAP action epoch checkpoints", .serialized, .processGlobalState)
struct IMAPActionEpochCheckpointTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture(
        accountId: String = "checkpoint-imap",
        folders: [(String, FolderRole, Int?)] = [("INBOX", .inbox, 10), ("Drafts", .drafts, 10)]
    ) throws -> Fixture {
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
                emailAddress: "checkpoint@example.com", displayName: "Checkpoint", provider: .imap)
            account.id = accountId
            try account.insert(db)
            for (path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func insert(_ operations: [PendingOperation], into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            for var operation in operations { try operation.insert(db) }
        }
    }

    private func operations(_ pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    private static func rfc822(messageId: String) -> String {
        """
        From: Sender <sender@example.com>\r
        To: Receiver <receiver@example.com>\r
        Subject: checkpoint\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        checkpoint body\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    @MainActor
    private func registeredProvider(
        server: FakeIMAPServer, fixture: Fixture
    ) async throws -> IMAPProvider {
        let provider = Self.provider(server)
        try await provider.connect()
        await AccountManager.shared.registerProviderForTesting(
            accountId: fixture.accountId, provider: provider)
        return provider
    }

    private func mutatingStoreCommands(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") || upper.hasPrefix("STORE ")
        }
    }

    @Test("The native action API refuses every missing or invalid admitted epoch before wire")
    func actionAPIRejectsUnadmittedEpochBeforeWire() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 7, id: "target@example.com")]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let provider: any EmailProvider = Self.provider(server)
        try await provider.connect()
        let before = server.recordedCommands()
        let actions: [ProviderMessageAction] = [.read(true), .read(false), .flagged(true), .flagged(false),
                                                .replied, .forwarded, .userLabel(id: "Label_1", add: true),
                                                .userLabel(id: "Label_1", add: false), .move(destination: "Archive")]
        let epochs: [Int?] = [nil, 0, -1, Int(UInt32.max) + 1]
        for epoch in epochs {
            for action in actions {
                do {
                    _ = try await provider.performMessageAction(action, at: .init(
                        memberIds: ["7"], folderPath: "INBOX", admittedUidValidity: epoch))
                    Issue.record("Unadmitted native address must not report completion")
                } catch {
                    #expect(error is ProviderEvidenceUnavailable)
                }
            }
        }
        #expect(server.recordedCommands() == before, "Missing admission evidence must be rejected before even SELECT")
        #expect(!server.flags(in: "INBOX", uid: 7).contains("\\Seen"))
        try await provider.disconnect()
    }

    @Test("The native action API preserves exact source bytes and all IMAP flag commands")
    func actionAPIForwardsExactSourceAndCommands() async throws {
        let source = " Projects "
        let message = Self.message(uid: 7, id: "duplicate@example.com")
        // Omit NAMESPACE to exercise the adapter byte boundary independently of
        // SwiftMail namespace normalization, which trims mailbox names.
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "NAMESPACE" },
            mailboxes: [source: [message, Self.message(uid: 8, id: "tail@example.com")],
                        "Projects": [message]])
        server.setUidValidity(10, for: source)
        server.setUidValidity(10, for: "Projects")
        try server.start()
        defer { server.stop() }
        let provider: any EmailProvider = Self.provider(server)
        try await provider.connect()
        let address = ProviderMessageSource(memberIds: ["7"], folderPath: source, admittedUidValidity: 10)
        for value in [true, false] {
            _ = try await provider.performMessageAction(.read(value), at: address)
            #expect(server.flags(in: source, uid: 7).contains("\\Seen") == value)
            #expect(server.flags(in: "Projects", uid: 7).isEmpty)
            _ = try await provider.performMessageAction(.flagged(value), at: address)
            #expect(server.flags(in: source, uid: 7).contains("\\Flagged") == value)
            #expect(server.flags(in: "Projects", uid: 7).isEmpty)
            let label = try await provider.performMessageAction(.userLabel(id: "Label_1", add: value), at: .init(
                memberIds: ["7", "8"], folderPath: source, admittedUidValidity: 10))
            #expect(label.dispositionedMemberIds == ["7"])
            #expect(server.flags(in: source, uid: 8).isEmpty)
            #expect(server.flags(in: source, uid: 7).contains("Label_1") == value)
            #expect(server.flags(in: "Projects", uid: 7).isEmpty)
        }
        _ = try await provider.performMessageAction(.replied, at: address)
        #expect(server.flags(in: "Projects", uid: 7).isEmpty)
        _ = try await provider.performMessageAction(.forwarded, at: address)
        #expect(server.flags(in: source, uid: 7).contains("\\Answered"))
        #expect(server.flags(in: source, uid: 7).contains("$Forwarded"))
        #expect(server.flags(in: "Projects", uid: 7).isEmpty, "Same UID/RFC in another exact mailbox is a bystander")
        #expect(!server.recordedCommands().contains { $0.uppercased().contains("SEARCH") })
        try await provider.disconnect()
    }

    /// 🚨 CORRECTED (audit round 1, finding A-3). This test previously asserted
    /// `operations(f.pool).isEmpty` — it BLESSED the defect, requiring that an
    /// op with a MISSING or ZERO admitted epoch be deleted alongside the one
    /// with a proven mismatch.
    ///
    /// The three rows exercise the two sides of the closure and must therefore
    /// end in two different states:
    ///
    /// * `nil` and `0` are an ABSENCE of evidence. We do not know whether this
    ///   op's address space moved, and "we could not determine the answer" is
    ///   not one of the four exits. They stay durably queued forever.
    /// * `9` against a live `10` is a PROVEN turnover in the op's own source
    ///   address space — exit 4, and the ONLY arm of checkpoint A permitted to
    ///   delete.
    ///
    /// Asserting all three states in one drain also pins that retirement is
    /// decided PER OP: a proven-dead sibling in the same pass may not take the
    /// undetermined ones with it.
    @Test("Checkpoint A retires only the proven epoch mismatch and leaves unknown-epoch ops queued")
    @MainActor
    func onlyProvenEpochMismatchRetiresAtCheckpointA() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let ops = [
            PendingOperation(type: .markRead, messageIds: ["1"], accountId: f.accountId, folderPath: "INBOX"),
            PendingOperation(type: .markRead, messageIds: ["2"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 0),
            PendingOperation(type: .markRead, messageIds: ["3"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 9),
        ]
        try insert(ops, into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        // No epoch was ever agreed, so nothing may reach the wire either way.
        #expect(await provider.callLog.isEmpty)
        let surviving = try operations(f.pool)
        #expect(surviving.count == 2)
        guard surviving.count == 2 else { await finish(f); return }
        #expect(Set(surviving.flatMap(\.messageIds)) == Set(["1", "2"]))
        await finish(f)
    }

    /// 🚨 CORRECTED (audit round 1, finding A-3) — was `mixedPayloadDropsWhole`,
    /// which asserted the op was deleted. A member that is not a canonical UID
    /// means checkpoint A cannot compare this op against ANY address space, so
    /// it has no evidence to act on. The two properties that matter are that it
    /// performs no I/O and that it does not split the batch; deleting it was
    /// never required by either, and is a silent loss of the user's gesture.
    @Test("A mixed native and RFC IMAP payload stays queued whole, without splitting or provider I/O")
    @MainActor
    func mixedPayloadParksWholeWithoutSplitting() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let op = PendingOperation(
            type: .markRead, messageIds: ["1", "message@example.com"],
            accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(await provider.callLog.isEmpty)
        let surviving = try operations(f.pool)
        #expect(surviving.count == 1)
        guard surviving.count == 1 else { await finish(f); return }
        #expect(surviving[0].messageIds == ["1", "message@example.com"])
        await finish(f)
    }

    /// 🚨 CORRECTED (audit round 1, findings A-3 + A-6) — was
    /// `rfcOnlyMutatingBypassesDropWhole`, which asserted these four ops were
    /// deleted. That is precisely the deterministic drop A-6 fixes at the
    /// producers: a `.markReplied` / `.markForwarded` / label op admitted with an
    /// rfc822 id and no epoch was accepted by the UI and then destroyed by the
    /// next drain.
    ///
    /// The C3 half of the original test is the half worth keeping and is
    /// retained verbatim: with two INBOX messages sharing one Message-ID, a
    /// provider that tried to resolve the RFC id would mutate an arbitrary one
    /// of them. Nothing may reach the wire. But the op must SURVIVE that
    /// refusal — parked, retryable, still the user's intention.
    @Test("RFC-only nil-epoch replied, forwarded, add-label and remove-label operations stay queued with no duplicate-RFC provider I/O")
    @MainActor
    func rfcOnlyMutatingOpsParkWithoutProviderIO() async throws {
        let duplicateRFC = "duplicate-action@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [
                Self.message(uid: 31, id: duplicateRFC),
                Self.message(uid: 32, id: duplicateRFC),
            ],
        ])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        let bypassTypes: [OperationType] = [
            .markReplied, .markForwarded, .addUserLabel, .removeUserLabel,
        ]
        let queued = bypassTypes.map { type in
            PendingOperation(
                type: type,
                messageIds: [duplicateRFC],
                accountId: f.accountId,
                folderPath: "INBOX",
                userLabelId: type == .addUserLabel || type == .removeUserLabel
                    ? "test-label"
                    : nil)
        }
        try insert(queued, into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        let forbiddenCommands = server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper.contains("SEARCH") || upper.contains("STORE")
                || upper.contains(" MOVE ") || upper.contains("EXPUNGE")
        }
        #expect(forbiddenCommands.isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
        // Every one of the four is still the user's intention.
        #expect(try operations(f.pool).count == bypassTypes.count)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A matching native IMAP action passes checkpoint A and reaches checkpoint B")
    @MainActor
    func matchingActionReachesLiveSelect() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 1, id: "target@example.com")]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains { $0.uppercased().contains("SELECT") })
        #expect(mutatingStoreCommands(server).count == 1)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A newly admitted saveDraft op is not consumed by generic checkpoint A")
    @MainActor
    func saveDraftBypassesGenericCheckpoint() async throws {
        let server = FakeIMAPServer(mailboxes: ["Drafts": []])
        server.setUidValidity(10, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        var draft = Draft(
            id: "draft-checkpoint", accountId: f.accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Draft", body: "Body",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
        draft.instanceEpoch = "instance-1"
        let persistedDraft = draft
        try await f.pool.writeWithoutTransaction { db in try persistedDraft.insert(db) }
        try insert([PendingOperation(
            type: .saveDraft,
            messageIds: [draft.id, PendingOperation.draftPlaceholderMessageId(draftId: draft.id, instanceEpoch: draft.instanceEpoch)],
            accountId: f.accountId, folderPath: "Drafts",
            instanceEpoch: draft.instanceEpoch, draftId: draft.id)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains { $0.uppercased().contains("APPEND") })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A newly admitted deleteDraft op is not consumed by generic checkpoint A")
    @MainActor
    func deleteDraftBypassesGenericCheckpoint() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "Drafts": [Self.message(uid: 5, id: "draft-target@example.com")],
        ])
        server.setUidValidity(10, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .deleteDraft, messageIds: ["5"],
            accountId: f.accountId, folderPath: "Drafts",
            draftServerUidValidity: 10,
            draftDeleteAddressKind: .providerResource)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.recordedCommands().contains {
            let upper = $0.uppercased()
            return upper.contains("UID STORE") || upper.contains("UID EXPUNGE")
        })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A UIDVALIDITY change after claim but before mutation produces zero provider writes")
    @MainActor
    func liveEpochChangeRefusesMutation() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 1, id: "new-occupant@example.com")]])
        server.setUidValidity(11, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).isEmpty)
        #expect(!server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A UIDVALIDITY bump between the wrapper SELECT and inner action SELECT produces zero mutation")
    @MainActor
    func epochBumpBetweenSelectsRefusesMutation() async throws {
        let original = Self.message(uid: 1, id: "target@example.com")
        let decoy = Self.message(uid: 1, id: "decoy@example.com")
        let server = FakeIMAPServer(mailboxes: ["INBOX": [original]])
        server.setUidValidity(10, for: "INBOX")
        server.expectMutation(rfc822MessageId: "target@example.com")
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT", mailbox: "INBOX", uidValidity: 11, messages: [decoy])
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["1"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).isEmpty)
        #expect(!server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        #expect(server.wrongMessageViolations().isEmpty)
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("A matching admitted and live UIDVALIDITY performs exactly one targeted STORE without RFC SEARCH")
    @MainActor
    func matchingEpochUsesOneNativeStore() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [Self.message(uid: 7, id: "target@example.com")]])
        server.setUidValidity(10, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let f = try fixture()
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([PendingOperation(
            type: .markRead, messageIds: ["7"], accountId: f.accountId,
            folderPath: "INBOX", observedUidValidity: 10)], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(mutatingStoreCommands(server).count == 1)
        #expect(server.flags(in: "INBOX", uid: 7).contains("\\Seen"))
        #expect(!server.recordedCommands().contains { $0.uppercased().contains("SEARCH") })
        try? await provider.disconnect()
        await finish(f)
    }

    @Test("Concurrent IMAP lanes cannot overwrite one another's admitted UIDVALIDITY")
    @MainActor
    func concurrentLanesKeepPerCallEpochs() async throws {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 1, id: "inbox@example.com")],
            "Other": [Self.message(uid: 2, id: "other@example.com")],
        ])
        server.setUidValidity(10, for: "INBOX")
        server.setUidValidity(21, for: "Other")
        try server.start()
        defer { server.stop() }
        let f = try fixture(folders: [("INBOX", .inbox, 10), ("Other", .custom, 20)])
        let provider = try await registeredProvider(server: server, fixture: f)
        try insert([
            PendingOperation(type: .markRead, messageIds: ["1"], accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10),
            PendingOperation(type: .markRead, messageIds: ["2"], accountId: f.accountId, folderPath: "Other", observedUidValidity: 20),
        ], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(server.flags(in: "INBOX", uid: 1).contains("\\Seen"))
        #expect(!server.flags(in: "Other", uid: 2).contains("\\Seen"))
        try? await provider.disconnect()
        await finish(f)
    }

    /// 🚨 CORRECTED (audit round 1, finding A-3) — the ⚑NEVER SPLIT property is
    /// the point of this test and is unchanged: a refusal must not fan one row
    /// out into per-member children, because a child inherits the parent's
    /// unproven addressing. What changed is the second assertion, which used to
    /// read `isEmpty` — proving the batch was not split by proving it was
    /// DESTROYED. Not-split and not-dropped are both required.
    @Test("An unresolvable member never splits the batch and never drops it")
    @MainActor
    func refusalNeverSplitsAndNeverDrops() async throws {
        let f = try fixture()
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await AccountManager.shared.registerProviderForTesting(accountId: f.accountId, provider: provider)
        let op = PendingOperation(
            type: .markRead, messageIds: ["1", "rfc@example.com"],
            accountId: f.accountId, folderPath: "INBOX", observedUidValidity: 10)
        try insert([op], into: f.pool)

        await AccountManager.shared.drainPendingQueue()

        #expect(await provider.callLog.isEmpty)
        let surviving = try operations(f.pool)
        #expect(surviving.count == 1)
        guard surviving.count == 1 else { await finish(f); return }
        #expect(surviving[0].id == op.id)
        #expect(surviving[0].messageIds.count == 2)
        await finish(f)
    }
}
