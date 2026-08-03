/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// T3.1 / T3.2 / T3.3 / T3.4 / T3.12 / T3.15 — the WIRE contract of the
/// provider-native IMAP move, asserted against the real `FakeIMAPServer` rather
/// than a mock, so every claim here is a claim about the bytes `IMAPProvider`
/// actually sends.
///
/// Each test pins a SYSTEM PROPERTY, never the mechanism that delivers it:
///  - T3.2/T3.15 — no move ever issues a mailbox-wide `EXPUNGE`, so a co-resident
///    message somebody else marked `\Deleted` is never destroyed. v3 has no
///    separate `deleteActionSource`: the source delete leg IS the tail of `move`,
///    so the "delete-source" half of this property is covered by the same two
///    cases (UIDPLUS purges exactly the named UID; no-UIDPLUS purges nothing).
///  - T3.4 — a source message is only ever soft-deleted or purged when the
///    server's own `COPYUID` named it as copied. A server that cannot produce
///    `COPYUID` at all is refused before anything reaches the wire; a server
///    that can is held to per-member evidence, so a member it did not name
///    survives while its named sibling is cleaned. Stated as an end state
///    (which messages exist where, and with which flags), never as "the
///    provider read the response code".
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

    /// ⚠ REWRITTEN TWICE BY T3.4 — record both prior display names, because a
    /// stale entry on the expected-name list silently reads as ABSENT.
    ///  1. Originally *"A move on a server without UIDPLUS copies and
    ///     soft-deletes but issues no EXPUNGE at all"*, asserting
    ///     `deletedStores(server).count == 1` and
    ///     `flags(in: "INBOX", uid: 22).contains("\\Deleted")`. That pinned the
    ///     pre-T3.4 behaviour in which an UNPROVEN copy still authorized a
    ///     source mutation — the very thing T3.4 forbids, kept alive and green.
    ///  2. Then *"A move on a server without UIDPLUS gets no COPYUID and never
    ///     touches the source"*, which asserted one `UID COPY` on the wire and
    ///     the copy landing at the destination. That matched the first cut of
    ///     the gate, which refused only AFTER the COPY.
    ///
    /// The gate now refuses at assertion A1, before the destination probe, the
    /// legacy `tm_*` strip and the COPY, so the property is strictly stronger
    /// and is asserted as such below: **nothing reaches the wire at all.**
    /// A refusal after a successful COPY guarantees a destination duplicate on
    /// every gesture; a refusal before it cannot manufacture one.
    ///
    /// The surviving half of the original — the purge is UID-scoped or absent,
    /// never mailbox-wide, so a co-resident `\Deleted` bystander is spared — is
    /// unchanged and still asserted.
    @Test("A move on a server without UIDPLUS is refused before the COPY and mutates nothing at all")
    func nonUidPlusMoveIsRefusedBeforeAnyWireMutation() async throws {
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

        // COPYUID is a UIDPLUS response code, so this server can never furnish
        // the evidence T3.4 requires. Terminal refusal the drain drops
        // (`IOS-IMAP-004`), not a retry.
        await #expect(throws: ProviderError.self) {
            try await provider.move(
                ids: ["22"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch)
        }

        // NON-VACUITY: the fixture provably reaches the gate rather than
        // failing earlier for an unrelated reason — the action connection got
        // as far as SELECTing the source, which is where A1 (and therefore the
        // gate immediately after it) runs. Its two-sided partner is
        // `uidPlusMovePurgesOnlyTheNamedUID`, the SAME INBOX/Archive/bystander
        // shape with UIDPLUS advertised, which runs the full sequence.
        #expect(Self.commands(server, containing: "SELECT").contains {
            $0.uppercased().contains("INBOX")
        })
        // THE PROPERTY: zero wire mutation. No COPY, so nothing at the
        // destination — the refusal cannot create the duplicate that refusing
        // after the COPY would have.
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        // The source is exactly as it was found.
        #expect(server.messageIDs(in: "INBOX").count == 2)
        #expect(server.flags(in: "INBOX", uid: 22).isEmpty)
        // Somebody else's soft-deleted message is still soft-deleted and still
        // there — the mailbox-wide-EXPUNGE property this test has always held.
        #expect(server.flags(in: "INBOX", uid: 21).contains("\\Deleted"))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.4 — only COPYUID may authorize source cleanup

    @Test("A UIDPLUS server that withholds COPYUID leaves the source untouched and refuses the move")
    func withheldCopyUidRefusesAllSourceCleanup() async throws {
        let target = "withheld-target@example.com"
        let bystander = "withheld-bystander@example.com"
        // UIDPLUS IS advertised here — the difference from the test above is
        // only that this server declines to send the response code, which
        // RFC 4315 §3 permits. Both shapes must produce the same refusal, or
        // the gate would be a capability check dressed up as an evidence check.
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(91, bystander), Self.message(92, target)],
            "Archive": [],
        ])
        server.setFlags(["\\Deleted"], in: "Work", uid: 91)
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.withholdCopyUID(forSourceUIDs: [92])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            try await provider.move(
                ids: ["92"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)
        }

        // NON-VACUITY, wire side: the copy was issued AND landed, so the server
        // really did withhold evidence for work it really did.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        // The property: an unproven copy authorizes nothing. Had the source
        // been purged here, the destination copy would be the only survivor of
        // a move this attempt could not even name.
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").count == 2)
        #expect(server.flags(in: "Work", uid: 92).isEmpty)
        #expect(server.flags(in: "Work", uid: 91).contains("\\Deleted"))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A member COPYUID does not name survives the source cleanup its named sibling receives")
    func copyUidAuthorizesOnlyTheMembersItNames() async throws {
        let named = "per-member-named@example.com"
        let unnamed = "per-member-unnamed@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(101, named), Self.message(102, unnamed)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // The server copies BOTH and reports only one. Withholding is about the
        // evidence, never about the copy.
        server.withholdCopyUID(forSourceUIDs: [102])
        server.expectMutations([named, unnamed])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["101", "102"], from: "Work", to: "Archive",
            admittedUidValidity: Self.epoch)

        // NON-VACUITY, wire side: one COPY carrying both members, and both
        // copies landed — the split below is produced by the evidence, not by a
        // partially-failed copy.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(named)>", "<\(unnamed)>"])
        // The property, stated as an end state: the member the server named is
        // gone from the source; the member it did not name is still there,
        // unflagged. One `\Deleted` STORE and one UID EXPUNGE were issued, and
        // both addressed only the named member.
        #expect(server.messageIDs(in: "Work") == ["<\(unnamed)>"])
        #expect(server.flags(in: "Work", uid: 102).isEmpty)
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("The same two-member move cleans both source UIDs when COPYUID names both")
    func fullCopyUidCleansEveryNamedMember() async throws {
        // Non-vacuity partner for the per-member test above: the SAME fixture,
        // the SAME two ids, differing only in whether the server reports the
        // second member. It proves the survival of UID 102 there is caused by
        // the withheld evidence and not by anything else about the fixture.
        let first = "per-member-control-first@example.com"
        let second = "per-member-control-second@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(101, first), Self.message(102, second)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutations([first, second])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.move(
            ids: ["101", "102"], from: "Work", to: "Archive",
            admittedUidValidity: Self.epoch)

        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(first)>", "<\(second)>"])
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        #expect(Self.bareExpunges(server).isEmpty)
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

    // MARK: - T3.14 — the DESTINATION epoch must be recorded and asserted

    /// ⚑ NO REFERENCE — INVENTED. `v2final` discards the `Mailbox.Selection` at
    /// BOTH of its destination SELECTs, so it never records a destination epoch
    /// and there is no prior art for these three cases.
    ///
    /// THE PROPERTY, stated as an end state and deliberately not as a
    /// mechanism: **the source is destroyed only when the server's own COPYUID
    /// proves the copy landed in the same destination address space this
    /// operation validated before it began.** If the destination's UIDVALIDITY
    /// turned over across the COPY — or was never reported at all — the source
    /// is left exactly as it was found.
    ///
    /// THE DISTINCTION THIS PINS, because conflating the two would break every
    /// legitimate move: a COPY *always* assigns the message a brand-new UID in
    /// the destination, and that is not a renumber. Only the destination
    /// **UIDVALIDITY** changing is. Nothing below compares a destination UID
    /// against anything; the control at the end performs a normal move whose
    /// destination UID is necessarily new, and it completes.
    ///
    /// All three share one fixture — source `Work`/UID 111, empty destination
    /// `Archive`, both at `epoch` — differing only in what the destination
    /// does, so the control is a true two-sided partner for both refusals.

    @Test("A destination UIDVALIDITY turnover between the probe and the COPY refuses all source cleanup")
    func destinationEpochTurnoverAcrossTheCopyRefusesSourceCleanup() async throws {
        let target = "dest-epoch-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(111, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        // The DESTINATION is deleted and re-created the instant our probe SELECT
        // is answered: a brand-new address space (RFC 3501 §2.3.1.1 requires a
        // re-created mailbox to report a new UIDVALIDITY). The SOURCE is
        // untouched throughout, so every source-side assertion still passes and
        // this fixture can only be refused by a DESTINATION-side check.
        //
        // `"Archive"` is the fragment because the destination probe is the first
        // command in the whole session that names it (LOGIN/CAPABILITY/the
        // wrapper `SELECT "Work"` all precede it and none mention it), and the
        // arm is consumed on that first match so the later `UID COPY … Archive`
        // cannot re-fire it. A mis-timed arm cannot pass silently: firing any
        // earlier would make the probe observe the NEW epoch, the COPYUID agree
        // with it, and the move complete — failing every assertion below.
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "Archive", mailbox: "Archive",
            uidValidity: Int(Self.nextEpoch), messages: [])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var thrown: Error?
        do {
            try await provider.move(
                ids: ["111"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        } catch {
            thrown = error
        }

        // NON-VACUITY, wire side: the turnover really happened, and the COPY was
        // really issued and really landed — so the refusal below is caused by
        // the destination epoch and not by a fixture that never got that far.
        #expect(server.uidValidity(for: "Archive") == Int(Self.nextEpoch))
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])

        // THE PROPERTY: zero source mutation. Had the source been purged here,
        // the only surviving instance of the user's message would sit in an
        // address space this operation never validated.
        #expect(thrown != nil, "a destination turnover must refuse, not complete")
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work") == ["<\(target)>"])
        #expect(server.flags(in: "Work", uid: 111).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        // AND the intention survives. `AccountManagerQueue` retires an op on
        // exactly these two typed signals (`if case ProviderError
        // .uidValidityChanged` and `if case ProviderError
        // .actionIdentityResolutionFailed`); everything else requeues and
        // retries. A DESTINATION turnover invalidates nothing the op recorded —
        // its durable `observedUidValidity` is the SOURCE's — and the next
        // attempt observes the new destination epoch and completes, so retiring
        // it here would drop a user gesture under an exit
        // `never-drop-user-intention.md` does not authorize.
        if let thrown {
            if case ProviderError.uidValidityChanged = thrown {
                Issue.record("a destination-side turnover must not raise the drain's retire-now signal — the op recorded no destination address")
            }
            if case ProviderError.actionIdentityResolutionFailed = thrown {
                Issue.record("a destination-side turnover must not raise the drain's drop-now signal — the next attempt converges")
            }
        }
    }

    @Test("A destination SELECT that reports no UIDVALIDITY refuses the move before anything reaches the wire")
    func unknownDestinationEpochRefusesBeforeAnyWireMutation() async throws {
        let target = "dest-unknown-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(111, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // A nonconforming server that omits the REQUIRED `* OK [UIDVALIDITY n]`
        // on the DESTINATION only (RFC 3501 §6.3.1 lists it among SELECT's
        // required untagged responses). SwiftMail then hands back the
        // `UIDValidity(0)` default, which is an ABSENCE OF EVIDENCE and must
        // never be compared as though it were an epoch. Note the mailbox's real
        // epoch is untouched, so the server would still stamp a perfectly
        // well-formed COPYUID — the only thing missing is anything to check it
        // against.
        server.suppressSelectUidValidity(for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var thrown: Error?
        do {
            try await provider.move(
                ids: ["111"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        } catch {
            thrown = error
        }

        // NON-VACUITY: the destination really was SELECTed, so the refusal is
        // the epoch gate and not an earlier unrelated failure.
        #expect(Self.commands(server, containing: "SELECT").contains {
            $0.uppercased().contains("ARCHIVE")
        })

        // THE PROPERTY: nothing reaches the wire at all. Refusing before the
        // COPY cannot manufacture the destination duplicate that refusing after
        // it would, and it leaves the source bit-identical.
        #expect(thrown != nil, "an unknown destination epoch must refuse, not complete")
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work") == ["<\(target)>"])
        #expect(server.flags(in: "Work", uid: 111).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        // Absence of evidence is RETRYABLE FOREVER, never a drop — the same two
        // typed signals the drain retires on must not appear.
        if let thrown {
            if case ProviderError.uidValidityChanged = thrown {
                Issue.record("an UNKNOWN destination epoch is an absence of evidence and must never be retired as a proven turnover")
            }
            if case ProviderError.actionIdentityResolutionFailed = thrown {
                Issue.record("an UNKNOWN destination epoch is an absence of evidence and must never be dropped as an unverifiable identity")
            }
        }
    }

    @Test("A stable destination epoch over the same fixture copies, soft-deletes and purges the source")
    func stableDestinationEpochCompletesTheWholeMove() async throws {
        // Two-sided partner for BOTH refusals above: byte-for-byte the same
        // fixture — same mailboxes, same UID, same epochs — with neither the
        // turnover nor the suppression armed. It proves the refusals are caused
        // by the destination epoch and not by a fixture that cannot mutate, and
        // it proves this item did not simply make every move refuse.
        //
        // It is also the "new destination UID is NOT a renumber" case: UID 111
        // in `Work` becomes UID 1 in `Archive`, a UID this operation has never
        // seen, and the move completes because the destination UIDVALIDITY held.
        let target = "dest-stable-target@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(111, target)],
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
            ids: ["111"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.uidValidity(for: "Archive") == Int(Self.epoch))
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
