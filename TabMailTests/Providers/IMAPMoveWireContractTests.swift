/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// T3.1 / T3.2 / T3.3 / T3.12 / T3.15 — the WIRE contract of the provider-native
/// IMAP move, asserted against the real `FakeIMAPServer` rather than a mock, so
/// every claim here is a claim about the bytes `IMAPProvider` actually sends.
///
/// Each test pins a SYSTEM PROPERTY, never the mechanism that delivers it:
///  - T3.2/T3.15 — no move ever issues a mailbox-wide `EXPUNGE`, so a co-resident
///    message somebody else marked `\Deleted` is never destroyed. v3 has no
///    separate `deleteActionSource`: the source delete leg IS the tail of `move`,
///    so the "delete-source" half of this property is covered by the same two
///    cases (UIDPLUS purges exactly the named UID; no-UIDPLUS purges nothing).
///  - T3.1 — a UIDVALIDITY change observed between any two mutation steps
///    refuses the remaining steps instead of completing them against a
///    renumbered mailbox.
///  - T3.3 — a destination that LIST proves is gone is a TERMINAL no-op, while a
///    SELECT failure on a mailbox LIST still reports stays retryable.
///  - T3.12 — a cancelled task stops at a step boundary and never completes a
///    second mutation.
///
/// `.serialized` — the fake binds a listening socket; parallel tests would
/// contend on ephemeral port allocation.
@Suite("IMAP move wire contract", .serialized)
struct IMAPMoveWireContractTests {
    /// Arbitrary non-zero epoch. `requireUidValidity` rejects 0 on either side,
    /// so every fixture must report a real `nz-number` UIDVALIDITY.
    private static let epoch: UInt32 = 92_101
    /// The epoch a mailbox turns over to mid-sequence. Must differ from `epoch`.
    private static let nextEpoch: UInt32 = 92_102

    private static func message(_ uid: Int, _ id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: move contract\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain\r
        \r
        body\r

        """)
    }

    private static func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private static func commands(_ server: FakeIMAPServer, containing fragment: String) -> [String] {
        server.recordedCommands().filter { $0.uppercased().contains(fragment) }
    }

    /// Any EXPUNGE at all — UID-scoped or mailbox-wide.
    private static func anyExpunges(_ server: FakeIMAPServer) -> [String] {
        commands(server, containing: "EXPUNGE")
    }

    /// A BARE, mailbox-wide `EXPUNGE` (RFC 3501 §6.4.3). The fake logs a command
    /// as `VERB ARGS`, so a plain expunge is logged as exactly `EXPUNGE` while a
    /// UID-scoped one is `UID EXPUNGE <set>` — the two are distinguishable
    /// without parsing.
    private static func bareExpunges(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper == "EXPUNGE" || upper.hasPrefix("EXPUNGE ")
        }
    }

    /// The source soft-delete specifically. The `tm_*` legacy strip is also a
    /// `UID STORE`, but it is a `-FLAGS` of custom keywords and never carries
    /// `\Deleted`, so this filter cannot confuse the two.
    private static func deletedStores(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper.contains("UID STORE") && upper.contains("\\DELETED")
        }
    }

    // MARK: - T3.2 / T3.15 — the purge is UID-scoped or absent, never mailbox-wide

    @Test("A UIDPLUS move purges only the named source UID and spares a co-resident deleted message")
    func uidPlusMovePurgesOnlyTheNamedUID() async throws {
        let target = "move-target@example.com"
        let bystander = "move-bystander@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(11, bystander), Self.message(12, target)],
            "Archive": [],
        ])
        // Somebody else's soft-deleted message, co-resident in the source. A bare
        // EXPUNGE would take it; a UID EXPUNGE naming only UID 12 cannot.
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 11)
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["12"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(Self.bareExpunges(server).isEmpty)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        // The bystander is still `\Deleted` and still THERE — the whole point.
        #expect(server.messageIDs(in: "INBOX") == ["<\(bystander)>"])
        #expect(server.flags(in: "INBOX", uid: 11).contains("\\Deleted"))
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A move on a server without UIDPLUS copies and soft-deletes but issues no EXPUNGE at all")
    func nonUidPlusMoveNeverExpunges() async throws {
        let target = "soft-target@example.com"
        let bystander = "soft-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "INBOX": [Self.message(21, bystander), Self.message(22, target)],
                "Archive": [],
            ])
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 21)
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["22"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)

        // FAIL CLOSED: no purge is available that is not mailbox-wide, so none
        // is issued. Not a bare EXPUNGE, and not a UID EXPUNGE either (the
        // server would reject that command anyway).
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(Self.deletedStores(server).count == 1)
        #expect(server.messageIDs(in: "INBOX").count == 2)
        #expect(server.flags(in: "INBOX", uid: 22).contains("\\Deleted"))
        #expect(server.flags(in: "INBOX", uid: 21).contains("\\Deleted"))
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.1 — an epoch change between steps refuses the remaining steps

    @Test("A UIDVALIDITY turnover between the COPY and the source delete refuses the delete")
    func epochTurnoverAfterCopyRefusesTheDelete() async throws {
        let target = "epoch-copy-target@example.com"
        let decoy = "epoch-copy-decoy@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(31, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        // The mailbox turns over the instant the COPY completes: a NEW numbering
        // in which UID 31 belongs to a different message entirely. Any further
        // step against UID 31 would mutate the decoy — C3.
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "UID COPY", mailbox: "INBOX",
            uidValidity: Int(Self.nextEpoch), messages: [Self.message(31, decoy)])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.move(
                ids: ["31"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)
        }

        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        // The decoy that inherited UID 31 is untouched and still present.
        #expect(server.messageIDs(in: "INBOX") == ["<\(decoy)>"])
        #expect(!server.flags(in: "INBOX", uid: 31).contains("\\Deleted"))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A UIDVALIDITY turnover between the source delete and the purge refuses the purge")
    func epochTurnoverAfterDeleteRefusesThePurge() async throws {
        let target = "epoch-store-target@example.com"
        let decoy = "epoch-store-decoy@example.com"
        // Source is deliberately NOT "INBOX": the legacy `tm_*` strip is also a
        // `UID STORE`, and it would consume the post-response reset below before
        // the soft-delete ever ran.
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(41, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "UID STORE", mailbox: "Work",
            uidValidity: Int(Self.nextEpoch), messages: [Self.message(41, decoy)])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.move(
                ids: ["41"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)
        }

        // The soft-delete DID run (under the old epoch, legitimately); the purge
        // did not. A UID EXPUNGE here would have destroyed the decoy.
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work") == ["<\(decoy)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.3 — absent is terminal, transient is retryable

    @Test("A destination mailbox LIST proves is gone makes the whole move a terminal no-op")
    func absentDestinationIsATerminalNoOp() async throws {
        let target = "absent-dest-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(51, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        // Deleted remotely between enqueue and drain. The plain, code-less NO
        // shape on purpose: the LIST probe, never the response text, decides.
        server.markMailboxDeleted("Archive", includeNonexistentCode: false)
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // TERMINAL: returns normally. Throwing here would pin the lane forever
        // behind a COPY into a mailbox that cannot be recreated by retrying.
        try await provider.move(
            ids: ["51"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        // Untouched — not even the legacy `tm_*` strip ran, because the
        // destination is probed before any source mutation.
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.flags(in: "INBOX", uid: 51).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A SELECT failure on a mailbox LIST still reports keeps the move retryable")
    func transientSelectFailureStaysRetryable() async throws {
        let target = "transient-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(61, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        // A protocol-level NO on the source SELECT with the mailbox still very
        // much present — the permissions-hiccup shape. This is the mirror image
        // of the case above and must NOT be classified as absence.
        server.failNextCommand(containing: "SELECT")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var thrown: Error?
        do {
            try await provider.move(
                ids: ["61"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "a transient SELECT failure must propagate so the op retries")
        #expect(server.consumedInjectedFailureCount() == 1)
        // The probe ran and answered PRESENT, so nothing was swallowed.
        #expect(Self.commands(server, containing: "LIST").contains {
            $0.uppercased().contains("INBOX")
        })
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "INBOX") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.12 — a cancelled task never completes a second mutation

    @Test("A move cancelled during its checkout stops at a step boundary and never soft-deletes the source")
    func cancelledMoveNeverCompletesTheSecondMutation() async throws {
        let target = "cancel-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(71, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // The action-connection seam fires once, inside the move's OWN task,
        // after the checkout's SELECT and before the body — cancelling from
        // there cancels exactly that task, with no wall-clock race.
        await provider.setActionConnectionTestHookForTesting {
            withUnsafeCurrentTask { current in
                guard let current else { return }
                current.cancel()
            }
        }

        let task = Task {
            try await provider.move(
                ids: ["71"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)
        }
        let outcome = await task.result
        await provider.setActionConnectionTestHookForTesting(nil)

        switch outcome {
        case .success:
            Issue.record("a cancelled move must not run to completion")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        // The FIRST mutation completed; the checkpoint stopped everything after
        // it. That is the property — not "nothing happened", which a cancel
        // landing before any I/O would also satisfy.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.flags(in: "Work", uid: 71).isEmpty)
        #expect(server.messageIDs(in: "Work") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("An uncancelled move over the same fixture completes the full copy, delete and purge sequence")
    func uncancelledControlMoveCompletesEveryStep() async throws {
        // Non-vacuity partner for the cancellation test above: it proves this
        // exact fixture DOES reach all three mutation steps when nothing
        // cancels it, so the assertions there are about the cancel and not
        // about a fixture that never mutates.
        let target = "control-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(81, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["81"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        #expect(Self.bareExpunges(server).isEmpty)
        // No `UID MOVE` on the wire at all — T3.15: the provider issues its own
        // instrumented sequence rather than SwiftMail's unguardable one.
        #expect(Self.commands(server, containing: "UID MOVE").isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }
}
