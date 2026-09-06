/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftMail
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
///  - T3.4, as amended by audit rounds 3 and 4 — a source message is only ever
///    soft-deleted or purged on evidence the server itself supplied, and the two
///    legs take DIFFERENT evidence because they cost different things.
///    ⚠️ CORRECTED (`IOS-TEST-003`). This bullet used to read: *"A server that
///    advertises UIDPLUS is held to per-member `COPYUID`, so a member it did not
///    name survives while its named sibling is cleaned, and a server that names
///    none of them cleans nothing."* That was accurate when round 3 landed and is
///    the INVERSE of tip behaviour for the SOFT-DELETE leg on both halves:
///    round 4 (`ede315ed8`) widened the tagged-OK arm to UIDPLUS servers too, so
///    `IMAPProvider.move`'s authorization gate takes its `else` arm whenever
///    `copyProvenUIDs.count != sourceUIDs.count`, calls `liveSourceUIDs` and sets
///    `authorizedUIDs = live`. The corrected statement:
///     • The IRREVERSIBLE purge is held to per-member `COPYUID` —
///       `purgeAuthorizedUIDs = copyProvenUIDs ∩ live`, additionally gated on
///       `serverSupportsUIDPlus` before `server.expunge(messages:)` — so a member
///       the server did not name is never purged while its named sibling is, and a
///       server that names none of them purges nothing.
///     • The REVERSIBLE `\Deleted` STORE is authorized separately, by the COPY's
///       own tagged OK (RFC 3501 §6.4.7 — an unsuccessful COPY MUST restore the
///       destination) ANDed with per-member proof from `liveSourceUIDs` that the
///       source still holds that member. So EVERY requested member the source
///       still holds is soft-deleted whether `COPYUID` named it or not —
///       including on a UIDPLUS server that named none of them.
///    A server that does NOT advertise UIDPLUS can never produce `COPYUID`, so
///    the tagged OK is its only evidence, it purges nothing, and its move
///    completes. Refusing that class outright was a permanent wedge, not a safety
///    property; see `nonUidPlusMoveCompletesWithoutAnyExpunge`. Stated as an end
///    state (which messages exist where, and with which flags), never as "the
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
    /// Force the shipped, app-owned COPY/STORE/UID-EXPUNGE arm. Tests that
    /// exercise atomic MOVE use the fake's default capabilities instead.
    private static let ownedCapabilities = FakeIMAPServer.defaultCapabilities.filter {
        $0 != "MOVE"
    }

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

    /// The UIDs each issued `UID FETCH` NAMES, one set per command, read off
    /// the wire log in issue order.
    ///
    /// The fake logs a command as `VERB ARGS`, so a UID fetch appears verbatim
    /// as `UID FETCH <sequence-set> (UID FLAGS)`. The sequence-set is expanded
    /// arithmetically (RFC 3501 §9: a `seq-range` is inclusive of both
    /// endpoints and order-independent), NOT resolved against the mailbox —
    /// the question these tests ask is how many UIDs one command NAMES, which
    /// is a property of the bytes sent and is unaffected by which of them
    /// happen to exist.
    ///
    /// A component that fails to parse contributes nothing, which cannot pass
    /// silently: every caller also asserts that the union of these sets is
    /// EXACTLY the requested set, so a dropped component fails that assertion.
    private static func uidFetchNamedUIDs(_ server: FakeIMAPServer) -> [Set<Int>] {
        let prefix = "UID FETCH "
        return server.recordedCommands().compactMap { command -> Set<Int>? in
            guard command.uppercased().hasPrefix(prefix) else { return nil }
            let argument = command.dropFirst(prefix.count)
                .split(separator: " ", maxSplits: 1)
                .first.map(String.init) ?? ""
            var named: Set<Int> = []
            for component in argument.split(separator: ",") {
                let parts = component.split(separator: ":")
                let bounds = parts.compactMap { Int($0) }
                guard bounds.count == parts.count, let first = bounds.first,
                      let last = bounds.last else { continue }
                named.formUnion(min(first, last)...max(first, last))
            }
            return named
        }
    }

    // MARK: - RFC 6851 atomic route

    @Test("A MOVE plus UIDPLUS server uses one UID MOVE and no owned fallback command")
    func atomicMoveWithUIDPlusUsesOneCommand() async throws {
        let target = "atomic-uidplus@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(7, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.nextEpoch), for: "Archive")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.move(
            ids: ["7"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(outcome.provenIds == ["7"])
        let destination = try #require(outcome.provenDestinations.first)
        #expect(destination.sourceProviderId == "7")
        #expect(destination.destinationProviderId == "1")
        #expect(destination.destinationUidValidity == Self.nextEpoch)
        #expect(Self.commands(server, containing: "UID MOVE").count == 1)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A MOVE server without UIDPLUS still uses UID MOVE and safely returns no address evidence")
    func atomicMoveWithoutUIDPlusStillUsesMove() async throws {
        let target = "atomic-no-uidplus@example.com"
        let server = FakeIMAPServer(
            capabilities: FakeIMAPServer.defaultCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: ["Work": [Self.message(8, target)], "Archive": []])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.move(
            ids: ["8"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(outcome.provenIds == ["8"])
        #expect(outcome.provenDestinations.isEmpty)
        #expect(Self.commands(server, containing: "UID MOVE").count == 1)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("Retry after UID MOVE commits and loses its response creates exactly one destination copy")
    func atomicRetryAfterPostCommitDisconnectDoesNotDuplicate() async throws {
        let target = "atomic-post-commit-loss@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(9, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.nextEpoch), for: "Archive")
        server.disconnectAfterNextUIDMoveCommit()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: (any Error).self) {
            _ = try await provider.move(
                ids: ["9"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        }
        let retry = try await provider.move(
            ids: ["9"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(retry.provenIds == ["9"])
        #expect(Self.commands(server, containing: "UID MOVE").count == 2)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A committed UID MOVE with malformed COPYUID retires without reissuing the move")
    func atomicMalformedCopyUIDIsSuccessWithoutEvidence() async throws {
        let target = "atomic-malformed-copyuid@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(10, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.reportMoveCOPYUIDWithCardinalityMismatch()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.move(
            ids: ["10"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(outcome.provenIds == ["10"])
        #expect(outcome.provenDestinations.isEmpty)
        #expect(Self.commands(server, containing: "UID MOVE").count == 1)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// GitHub #115. A tagged NO with no `COPYUID` is an absence of evidence:
    /// SwiftMail raises the same `moveFailedAfterPossiblePartialCompletion` for
    /// a refusal that mutated nothing, so the provider must not claim the
    /// members are dispositioned. It throws and the queue requeues. Here the
    /// server DID commit before its NO — the world state in which a retry
    /// could, on a non-conforming server, duplicate — and the property is that
    /// it does not: RFC 3501 §6.4.8 ignores the retry's now-absent UID, so the
    /// destination ends with exactly one copy and the source empty. The number
    /// of `UID MOVE` commands it took is the mechanism and is not asserted.
    @Test("A tagged NO after a committed UID MOVE with no COPYUID is retryable, and the retry lands exactly one destination copy")
    func atomicPossiblePartialCompletionIsRetriedToExactlyOneCopy() async throws {
        let target = "atomic-possible-partial@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(11, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.failUIDMoveAfterPossiblePartialCompletion()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: (any Error).self) {
            _ = try await provider.move(
                ids: ["11"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        }
        let retry = try await provider.move(
            ids: ["11"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(retry.provenIds == ["11"])
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// GitHub #115 round 3 (architecture A-1 / robustness R1). The sibling above
    /// pins WHAT HAPPENS TO THE MAIL after a no-`COPYUID` refusal; this pins
    /// WHAT THE PROVIDER HANDS THE QUEUE, which is a separate contract and was
    /// the defect. The refusal used to leave `IMAPProvider.move` as a raw
    /// `IMAPError`, which matched no typed arm in `AccountManager.executeSingleOp`
    /// and therefore reached the GENERIC catch — the arm that inserts the account
    /// into `failedAccounts`, account-wide suppression the drain reserves for
    /// facts about the CONNECTION. A tagged command refusal is a fact about ONE
    /// command; `ADR-IOS-073` expressly accepts a server that advertises MOVE and
    /// then permanently rejects it, and on such a server the generic arm starves
    /// every disjoint lane on the account, every drain.
    ///
    /// THE PROPERTY: a tagged NO with no `COPYUID` leaves this provider as an
    /// error that `is ProviderEvidenceUnavailable` — the drain's lane-local
    /// disposition (requeue, bump `retryCount`, at most one attempt per drain,
    /// halt only this lane, DO NOT touch `failedAccounts`) — and never as a bare
    /// `IMAPError`, which has no arm of its own. The wire half is asserted
    /// alongside it: the refusal costs zero mutation, so nothing was copied,
    /// soft-deleted or expunged and the source is exactly as it was. Nothing here
    /// asserts which catch arm ran or which error case was constructed.
    ///
    /// The queue-level consequence is pinned by
    /// `NeverDropExitClosureTests.aPermanentlyRefusedAtomicMoveParksOnlyItsOwnLane`.
    ///
    /// RED PROOF (recorded, #115 round 3): on the parent `977958c37` the thrown
    /// value is the raw `IMAPError`, failing both dispositions.
    @Test("A tagged NO with no COPYUID leaves the provider as an evidence-unavailable refusal that mutated nothing")
    func atomicRefusalWithoutCopyUIDIsEvidenceUnavailable() async throws {
        let target = "atomic-refusal-disposition@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(14, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // Answered BEFORE the fake's MOVE handler runs, so the refusal mutated
        // nothing at all — the world state every transport-level refusal
        // produces, and the one the deleted arm never exercised.
        server.failNextCommand(
            containing: "UID MOVE", message: "Move rejected by server policy")
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var thrown: Error?
        do {
            _ = try await provider.move(
                ids: ["14"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        } catch {
            thrown = error
        }

        // NON-VACUITY: the atomic MOVE actually reached the wire, and the
        // injected refusal is what answered it.
        #expect(Self.commands(server, containing: "UID MOVE").count == 1)
        #expect(server.consumedInjectedFailureCount() == 1)

        let refusal = try #require(
            thrown, "a refused UID MOVE must not return as if it had dispositioned its members")
        #expect(
            refusal is ProviderEvidenceUnavailable,
            """
            a refused UID MOVE must reach the drain's lane-local, account-preserving arm. As \
            anything else it lands in the generic catch, which marks the whole ACCOUNT failed and \
            starves every disjoint lane on it — thrown: \(refusal)
            """)
        #expect(
            !(refusal is IMAPError),
            """
            the raw transport error escaped the provider. No arm in the drain matches it, so it \
            falls through to the account-wide failure arm — thrown: \(refusal)
            """)

        // The wire half: a refusal answered before any mutation costs nothing.
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work") == ["<\(target)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.flags(in: "Work", uid: 14).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("A tagged failure after COPYUID-proven partial UID MOVE preserves its verified address and requires source reconciliation")
    func atomicVerifiedPartialCompletionPreservesEvidence() async throws {
        let target = "atomic-verified-partial@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "Work": [Self.message(12, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.nextEpoch), for: "Archive")
        server.failUIDMoveAfterVerifiedPartialCompletion()
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let outcome = try await provider.move(
            ids: ["12"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch)

        #expect(outcome.provenIds == ["12"])
        let destination = try #require(outcome.provenDestinations.first)
        #expect(destination.sourceProviderId == "12")
        #expect(destination.destinationProviderId == "1")
        #expect(destination.destinationUidValidity == Self.nextEpoch)
        #expect(outcome.requiresSourceReconciliation)
        #expect(Self.commands(server, containing: "UID MOVE").count == 1)
        #expect(server.messageIDs(in: "Work").isEmpty)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("An INBOX epoch turnover after legacy flag stripping refuses before UID MOVE")
    func atomicMoveReassertsEpochAfterLegacyStrip() async throws {
        let target = "atomic-strip-turnover@example.com"
        let decoy = "atomic-strip-decoy@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(13, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "UID STORE", mailbox: "INBOX",
            uidValidity: Int(Self.nextEpoch), messages: [Self.message(13, decoy)])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            _ = try await provider.move(
                ids: ["13"], from: "INBOX", to: "Archive",
                admittedUidValidity: Self.epoch)
        }

        #expect(Self.commands(server, containing: "UID MOVE").isEmpty)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "INBOX") == ["<\(decoy)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    @Test("An INBOX turnover after checkout refuses before legacy flag stripping")
    func atomicMoveReassertsEpochBeforeLegacyStrip() async throws {
        let target = "atomic-pre-strip-turnover@example.com"
        let decoy = "atomic-pre-strip-decoy@example.com"
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(14, target)],
            "Archive": [],
        ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT", mailbox: "INBOX",
            uidValidity: Int(Self.nextEpoch), messages: [Self.message(14, decoy)])
        server.expectMutation(rfc822MessageId: target)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        await #expect(throws: ProviderError.self) {
            _ = try await provider.move(
                ids: ["14"], from: "INBOX", to: "Archive",
                admittedUidValidity: Self.epoch)
        }

        #expect(Self.commands(server, containing: "UID STORE").isEmpty)
        #expect(Self.commands(server, containing: "UID MOVE").isEmpty)
        #expect(Self.commands(server, containing: "UID COPY").isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "INBOX") == ["<\(decoy)>"])
        #expect(server.messageIDs(in: "Archive").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.2 / T3.15 — the purge is UID-scoped or absent, never mailbox-wide

    @Test("A UIDPLUS move purges only the named source UID and spares a co-resident deleted message")
    func uidPlusMovePurgesOnlyTheNamedUID() async throws {
        let target = "move-target@example.com"
        let bystander = "move-bystander@example.com"
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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

    /// ⚠ REWRITTEN THREE TIMES — record every prior display name, because a
    /// stale entry on the expected-name list silently reads as ABSENT.
    ///  1. Originally *"A move on a server without UIDPLUS copies and
    ///     soft-deletes but issues no EXPUNGE at all"*.
    ///  2. Then *"A move on a server without UIDPLUS gets no COPYUID and never
    ///     touches the source"*, which asserted one `UID COPY` on the wire and
    ///     the copy landing at the destination but no source mutation.
    ///  3. Then *"A move on a server without UIDPLUS is refused before the COPY
    ///     and mutates nothing at all"*, matching T3.4's capability refusal.
    ///
    /// 🚨 **AUDIT ROUND 3 — NAME 3 WAS A BLESSING TEST AND IS NOW INVERTED.**
    /// It asserted that a non-UIDPLUS move reaches the wire not at all. That
    /// reads as maximal safety and was in fact a permanent, unresolvable wedge:
    /// the missing capability can never appear, so the refusal fired on every
    /// attempt forever, the user's archive could never happen by any route, and
    /// the refusal's drain arm (`.haltLane` at the time, chain deferral today)
    /// starved every later gesture on the same message. `v1.6.38` moved mail on these servers perfectly well. The
    /// gate is deleted; what authorizes the source cleanup on this class of
    /// server is the COPY's own tagged OK, which RFC 3501 §6.4.7 makes a
    /// positive statement that the whole named set copied (an unsuccessful COPY
    /// MUST restore the destination mailbox). Name 1 is therefore close to what
    /// is asserted again below.
    ///
    /// THE PROPERTIES, all end state at the server:
    ///  - the move COMPLETES — the copy is at the destination and the named
    ///    source UID is soft-deleted;
    ///  - **no EXPUNGE of any kind**, so the co-resident soft-deleted bystander
    ///    survives. That is `KNOWN_ISSUES.md` `IOS-IMAP-001`: a server without
    ///    UIDPLUS has no narrower purge than a mailbox-wide `EXPUNGE`, which
    ///    would irreversibly destroy unrelated mail, and incomplete VISIBLE
    ///    cleanup is preferred over that AND over the wedge. This half has been
    ///    asserted by this test under every one of its names and is the one
    ///    thing that never changed;
    ///  - only the NAMED UID is mutated, so the bystander is bit-identical.
    ///
    /// RED PROOF (recorded): with the `supportsUIDPlus` refusal restored, this
    /// fails at the `UID COPY` count and at `messageIDs(in: "Archive")`.
    @Test("A move on a server without UIDPLUS completes by copy plus soft delete and never expunges")
    func nonUidPlusMoveCompletesWithoutAnyExpunge() async throws {
        let target = "soft-target@example.com"
        let bystander = "soft-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.ownedCapabilities.filter { $0 != "UIDPLUS" },
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

        let proven = try await provider.move(
            ids: ["22"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch).provenIds

        // The member is reported complete, so the drain retires it and releases
        // its lane. The queue-level partner is
        // `NeverDropExitClosureTests.aNonUidPlusMoveCompletesAndReleasesItsLane`.
        #expect(proven == ["22"])

        // THE MOVE HAPPENED.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])
        #expect(Self.deletedStores(server).count == 1)
        #expect(server.flags(in: "INBOX", uid: 22).contains("\\Deleted"))

        // NO EXPUNGE OF ANY KIND — IOS-IMAP-001. Not UID-scoped (the server
        // cannot), and emphatically not mailbox-wide.
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(Self.bareExpunges(server).isEmpty)
        // Somebody else's soft-deleted message is still soft-deleted and still
        // there — the property this test has held under every one of its names.
        #expect(server.messageIDs(in: "INBOX").count == 2)
        #expect(server.flags(in: "INBOX", uid: 21).contains("\\Deleted"))
        // No `UID MOVE` either: the provider issues its own instrumented
        // sequence, so SwiftMail's fallback — whose UID branch degrades to a
        // bare, mailbox-wide `expunge()` without UIDPLUS — is never reached.
        #expect(Self.commands(server, containing: "UID MOVE").isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    // MARK: - T3.4 — COPYUID authorizes the PURGE; the tagged OK plus liveness authorizes the soft delete

    /// ⚠ **REWRITTEN TWICE — record every prior display name, because a stale
    /// entry on an expected-name list silently reads as ABSENT.**
    ///  1. *"A move on a server that cannot prove COPYUID leaves the source
    ///     untouched"* (round 1).
    ///  2. *"A UIDPLUS server that withholds COPYUID leaves the source untouched
    ///     and refuses the move"* (rounds 2–3).
    ///
    /// ⚠ **THE COMMENT THAT STOOD HERE WAS INVERTED BY AUDIT ROUND 3 AND IS NOW
    /// INVERTED AGAIN BY ROUND 4 — record both, because each was the reasoning
    /// that produced a wedge.** Round 1–2 said: *"Both shapes must produce the
    /// same refusal, or the gate would be a capability check dressed up as an
    /// evidence check."* Round 3 replied that the two shapes are NOT the same,
    /// because *"a server that advertises UIDPLUS and withholds `COPYUID` has
    /// made a CHOICE it can unmake on the next attempt (RFC 4315 §3 makes
    /// sending it a MAY), so refusing is a bounded wait for evidence."*
    ///
    /// **That second sentence is false, and this test was BLESSING it.** RFC
    /// 4315 §3 makes the response code a SHOULD "with limited exceptions", then
    /// names two: a mailbox the client may COPY or APPEND to but not SELECT or
    /// EXAMINE, where the server "SHOULD NOT send" it "as it would disclose
    /// information about the mailbox"; and a `UIDNOTSTICKY` mail store, where it
    /// "MAY omit" it "as it is not meaningful". Both are properties of the
    /// MAILBOX rather than of the attempt. For such a server the evidence never
    /// arrives, so the "bounded wait" is unbounded:
    /// the op reaches none of the four never-drop exits, its deferral
    /// disposition starves every later gesture on the same message, and — worse
    /// than the capability wedge round 3 deleted — the refusal is raised AFTER
    /// the `UID COPY`, so every drain seats another duplicate at the destination.
    ///
    /// THE PROPERTIES NOW, all end state at the server:
    ///  - the move COMPLETES: the copy is at the destination and the source copy
    ///    is soft-deleted, authorized by the COPY's tagged OK (RFC 3501 §6.4.7)
    ///    ANDed with the member still being in the source when that COPY ran
    ///    (RFC 3501 §6.4.8 / §2.3.1.1 — see `IMAPProvider.liveSourceUIDs`);
    ///  - **NO EXPUNGE of any kind.** The widened evidence authorizes only the
    ///    REVERSIBLE half. `COPYUID` remains the sole authority for an
    ///    irreversible purge, so a server that withholds it leaves the source
    ///    copy `\Deleted`-but-present — the same accepted cost as the
    ///    non-UIDPLUS arm (`IOS-IMAP-001`), and the reason widening is safe even
    ///    against a server that answers OK to a COPY it did not complete;
    ///  - the co-resident soft-deleted bystander is untouched.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at
    /// `deletedStores(server).count == 1` and at `flags(in: "Work", uid: 92)` —
    /// the move threw `noCopyUidEvidence` and mutated nothing.
    @Test("A UIDPLUS server that withholds COPYUID completes the move by soft delete and never purges")
    func withheldCopyUidCompletesWithoutPurgingTheSource() async throws {
        let target = "withheld-target@example.com"
        let bystander = "withheld-bystander@example.com"
        // UIDPLUS IS advertised here: this server CAN name what it copied and
        // declined to, which RFC 4315 §3 permits and which — for a UIDNOTSTICKY
        // store or a COPY-but-not-SELECT mailbox — it will decline forever.
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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

        let proven = try await provider.move(
            ids: ["92"], from: "Work", to: "Archive", admittedUidValidity: Self.epoch).provenIds

        // The member is reported complete, so the drain retires it and releases
        // its lane. The queue-level partner is
        // `NeverDropExitClosureTests.aWithheldCopyUidMoveCompletesAndReleasesItsLane`.
        #expect(proven == ["92"])

        // NON-VACUITY, wire side: exactly one COPY was issued and it landed, so
        // the server really did withhold evidence for work it really did.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(server.messageIDs(in: "Archive") == ["<\(target)>"])

        // THE MOVE HAPPENED — reversibly.
        #expect(Self.deletedStores(server).count == 1)
        #expect(server.flags(in: "Work", uid: 92).contains("\\Deleted"))

        // AND NOTHING WAS DESTROYED. Without `COPYUID` no purge is authorized,
        // so both the moved message and the bystander are still present.
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").count == 2)
        #expect(server.flags(in: "Work", uid: 91).contains("\\Deleted"))
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// ⚠ **RE-SCOPED BY AUDIT ROUND 4. Prior display name: *"A member COPYUID
    /// does not name survives the source cleanup its named sibling receives"*.**
    /// It asserted that an unnamed member is left completely untouched. That was
    /// a BLESSING TEST for the same wedge as the case above, one member down:
    /// the unnamed member was not retired either, so the drain narrowed the row
    /// to it, re-copied it on the next pass (a duplicate at the destination) and
    /// then refused for want of the evidence that server had already declined to
    /// send — forever.
    ///
    /// THE PROPERTY NOW, and it is the one the round-3 name was reaching for:
    /// **`COPYUID` is the authority for the IRREVERSIBLE purge, per member.**
    /// A member it names is expunged from the source; a member it does not name
    /// is soft-deleted on the tagged OK plus its own liveness and is NEVER
    /// expunged. Both moved, so both retire — the difference the withheld
    /// evidence makes is exactly one purge, not one lost intention.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at
    /// `flags(in: "Work", uid: 102).contains("\\Deleted")` — the unnamed member
    /// was left unflagged and its intention was left queued.
    @Test("COPYUID authorizes the purge per member while the members it does not name are only soft-deleted")
    func copyUidAuthorizesThePurgeOnlyForTheMembersItNames() async throws {
        let named = "per-member-named@example.com"
        let unnamed = "per-member-unnamed@example.com"
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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

        let proven = try await provider.move(
            ids: ["101", "102"], from: "Work", to: "Archive",
            admittedUidValidity: Self.epoch).provenIds

        // Both members were dispositioned, so neither is left for a later pass
        // to re-copy.
        #expect(Set(proven) == ["101", "102"])

        // NON-VACUITY, wire side: one COPY carrying both members, and both
        // copies landed — the split below is produced by the evidence, not by a
        // partially-failed copy.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(named)>", "<\(unnamed)>"])
        // THE PROPERTY, as an end state: the member the server named is GONE
        // from the source; the member it did not name is still there and marked
        // `\Deleted`. Exactly one UID EXPUNGE was issued and it took only the
        // named member.
        #expect(server.messageIDs(in: "Work") == ["<\(unnamed)>"])
        #expect(server.flags(in: "Work", uid: 102).contains("\\Deleted"))
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.commands(server, containing: "UID EXPUNGE").count == 1)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// 🚨 **AUDIT ROUND 4 — HOLE 1, at the wire.** Round 3 authorized the source
    /// cleanup of the WHOLE requested set on the COPY's tagged OK, reading RFC
    /// 3501 §6.4.7 (an unsuccessful COPY MUST restore the destination) as proof
    /// that every named message was copied. §6.4.8 says otherwise, verbatim:
    /// *"A non-existent unique identifier is ignored without any error message
    /// generated. Thus, it is possible for a UID FETCH command to return an OK
    /// without any data or a UID COPY or UID STORE to return an OK without
    /// performing any operations."*
    ///
    /// THE FIXTURE IS THE REAL RACE: the user swipes two messages to Archive,
    /// and before the drain runs another client moves one of them out of the
    /// source folder. UIDVALIDITY never changes, so every epoch assertion
    /// passes; the `UID COPY` silently copies one message and returns tagged OK.
    ///
    /// THE PROPERTY: **the source cleanup addresses only the members the source
    /// still holds.** The sibling that WAS present moves and is soft-deleted;
    /// the absent member is not swept into the cleanup on that sibling's OK.
    /// This suite asserts the BYTES the provider sends, so the claim is made
    /// where it is observable — the absent member's own end state is identical
    /// either way (a `UID STORE` naming it is a no-op by the same §6.4.8), which
    /// is precisely why the defect survived: nothing about the outcome
    /// contradicted it, only the authorization did. The never-drop consequence
    /// is asserted from the queue side by
    /// `NeverDropExitClosureTests.aSourceAbsentMemberRetiresWithoutWedgingItsLane`.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider the `\Deleted`
    /// STORE reads `UID STORE 22,23 +FLAGS (\Deleted)` and this fails at the
    /// `!store.contains("23")` expectation.
    @Test("A source cleanup addresses only the members the source still holds")
    func sourceCleanupSkipsAMemberTheSourceNoLongerHolds() async throws {
        let present = "absent-member-present@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.ownedCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "INBOX": [Self.message(22, present)],
                "Archive": [],
            ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutation(rfc822MessageId: present)
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // UID 23 was in INBOX when the user swiped and is not there now.
        let proven = try await provider.move(
            ids: ["22", "23"], from: "INBOX", to: "Archive",
            admittedUidValidity: Self.epoch).provenIds

        // Both members leave the queue: 22 because it moved, 23 because the
        // server itself says it is not in the source folder (exit 2).
        #expect(Set(proven) == ["22", "23"])

        // The present sibling really did move.
        #expect(server.messageIDs(in: "Archive") == ["<\(present)>"])
        #expect(server.flags(in: "INBOX", uid: 22).contains("\\Deleted"))

        // THE PROPERTY: the cleanup names only what the source still holds.
        let stores = Self.deletedStores(server)
        #expect(stores.count == 1)
        guard stores.count == 1 else { return }
        #expect(stores[0].contains("22"))
        #expect(
            !stores[0].contains("23"),
            """
            the source cleanup addressed a UID the source no longer holds. Its own copy was never \
            proven — a tagged OK on a UID COPY says nothing about a UID the server silently ignored \
            (RFC 3501 §6.4.8) — so it must not be swept into a sibling's cleanup: \(stores[0])
            """)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// The whole-op form of the case above, and the shape shipped `v1.6.38`
    /// handled with `idempotentMove`'s `if srcUIDs.isEmpty { … return }`: every
    /// member of the op has already left the source folder.
    ///
    /// THE PROPERTY: the op completes as a no-op that mutates NOTHING anywhere —
    /// no `\Deleted` STORE, no EXPUNGE — and reports every member complete, so
    /// the drain retires it instead of retrying an unsatisfiable move forever.
    /// A `UID COPY` is still issued (the provider learns the members are gone
    /// only from the source itself, and §6.4.8 makes that COPY a server-side
    /// no-op), which is why the destination stays empty.
    ///
    /// RED PROOF (recorded): against the pre-round-4 provider this fails at
    /// `deletedStores(server).isEmpty` — the whole requested set was authorized
    /// and a `\Deleted` STORE went out for a UID the mailbox does not contain.
    @Test("A move whose members have all left the source completes without mutating anything")
    func aWhollyAbsentSourceSetIsATerminalNoOp() async throws {
        let bystander = "wholly-absent-bystander@example.com"
        let server = FakeIMAPServer(
            capabilities: Self.ownedCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "INBOX": [Self.message(21, bystander)],
                "Archive": [],
            ])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let proven = try await provider.move(
            ids: ["23"], from: "INBOX", to: "Archive", admittedUidValidity: Self.epoch).provenIds

        #expect(proven == ["23"])
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Archive").isEmpty)
        // The co-resident message is untouched: nothing here addressed it.
        #expect(server.messageIDs(in: "INBOX") == ["<\(bystander)>"])
        #expect(server.flags(in: "INBOX", uid: 21).isEmpty)
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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

    // MARK: - Audit round 5 — the liveness probe is BOUNDED, and an
    // unanswerable probe retires nobody

    /// The number of members the two large-move cases below request. It must
    /// EXCEED one streaming chunk, and SwiftMail derives that chunk size from
    /// the fetch options (`.uidFlagsOnly`'s own `suggestedChunkSize`, an
    /// internal value this suite deliberately does not restate as a literal —
    /// the invariant is "bounded", not "exactly N").
    ///
    /// ⚠ If `aLargeMoveProbesTheSourceInBoundedChunks` ever fails because ONE
    /// `UID FETCH` covered the whole set, the chunk bound GREW past this
    /// number. Raise this constant. Do not delete the assertion — the property
    /// it pins is that a batch cannot be issued as a single unbounded command.
    private static let oversizedRequestCount = 5_001

    /// The members of that oversized request the source mailbox actually still
    /// holds, deliberately spanning BOTH chunks: three below the chunk bound
    /// and one above it. A probe that consumed only the first chunk would find
    /// three of them and silently retire the fourth.
    private static let oversizedLiveUIDs = [1, 4_999, 5_000, Self.oversizedRequestCount]

    private static func oversizedMoveServer() -> FakeIMAPServer {
        // No UIDPLUS: the server can never send `COPYUID`, so every member is
        // unnamed and the liveness probe runs over the WHOLE requested set —
        // which is the arm the unbounded FETCH lived on.
        FakeIMAPServer(
            capabilities: Self.ownedCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "Work": Self.oversizedLiveUIDs.map { Self.message($0, "oversized-\($0)@example.com") },
                "Archive": [],
            ])
    }

    /// 🚨 **AUDIT ROUND 5 — THE WEDGE, at the wire.** Round 4 issued the
    /// liveness probe as ONE `fetchMessageInfosBulk`, which builds a single
    /// `FetchMessageInfoCommand` for the entire set with no chunking whatever.
    /// The set is unbounded — `AccountManager.move` puts every message sharing
    /// an account and source folder into ONE `PendingOperation`, and
    /// `SettingsView.archiveOldMessages` selects every inbox message older than
    /// the cutoff with no limit — while
    /// `SyncConfig.pendingOperationTimeoutSeconds` bounds the whole provider
    /// operation at 15s. A large archive against a server that withholds
    /// `COPYUID` therefore completed its `UID COPY` and then blew that deadline
    /// inside the probe, throwing out of `move` AFTER the copy. The drain's
    /// generic arm moves the op and its related chain to the queue's tail and
    /// poisons the account for the rest of that drain, so
    /// no source `\Deleted` is ever reached and the next drain REPEATS the
    /// `UID COPY` — a destination duplicate per drain, forever, with every
    /// later intention on that account starved behind it. That is the
    /// never-drop WEDGE corollary.
    ///
    /// THE PROPERTY, stated without naming the mechanism or the chunk size:
    /// **the probe splits an oversized request into several strictly smaller
    /// commands that together name it exactly once.** No single command carries
    /// the whole batch (so no single command's size grows without bound), the
    /// parts are disjoint (nothing is asked twice), and their union is the
    /// request (nothing is dropped — a probe that silently skipped a member
    /// would retire it as absent, which is the defect the sibling case below
    /// pins).
    ///
    /// NO BLESSING TEST HAD TO BE RE-SCOPED: nothing in this suite or elsewhere
    /// in `TabMailTests` asserted the single-bulk-FETCH shape of the probe
    /// (`rg 'fetchMessageInfosBulk' TabMailTests` returns nothing, and the only
    /// other `UID FETCH` wire assertion — `PostSendServerDraftCleanupTests` —
    /// is on the draft-cleanup path, not the move).
    ///
    /// RED PROOF (recorded): with `liveSourceUIDs` reverted to
    /// `fetchMessageInfosBulk`, the probe issues exactly ONE `UID FETCH`
    /// naming all 5,001 UIDs, and this fails at `probes.count > 1` and at the
    /// "no single probe names the whole request" expectation.
    @Test("A move larger than one fetch chunk probes the source in several bounded commands")
    func aLargeMoveProbesTheSourceInBoundedChunks() async throws {
        let server = Self.oversizedMoveServer()
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutations(Self.oversizedLiveUIDs.map { "oversized-\($0)@example.com" })
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let ids = (1...Self.oversizedRequestCount).map(String.init)
        let proven = try await provider.move(
            ids: ids, from: "Work", to: "Archive", admittedUidValidity: Self.epoch).provenIds

        // NON-VACUITY: the move really ran and really reached the probe arm —
        // one COPY, and the members the source held really landed.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(proven.count == ids.count)
        #expect(
            Set(server.messageIDs(in: "Archive"))
                == Set(Self.oversizedLiveUIDs.map { "<oversized-\($0)@example.com>" }))

        let probes = Self.uidFetchNamedUIDs(server)
        // THE PROPERTY, part 1: more than one command. A single command for an
        // unbounded set is the wedge.
        #expect(
            probes.count > 1,
            """
            the liveness probe issued \(probes.count) UID FETCH command(s) for a \(ids.count)-member \
            move. An unbounded batch in ONE command is what exceeds the operation deadline after the \
            COPY has already gone out, which requeues the op and re-COPIES on the next drain
            """)
        // THE PROPERTY, part 2: no single command carries the whole request.
        #expect(probes.allSatisfy { $0.count < ids.count })
        // THE PROPERTY, part 3: the commands PARTITION the request — disjoint,
        // and covering it exactly. A chunked probe that lost or duplicated a
        // member would be a different defect wearing this fix's shape.
        let requested = Set(1...Self.oversizedRequestCount)
        #expect(probes.reduce(into: Set<Int>()) { $0.formUnion($1) } == requested)
        #expect(probes.reduce(0) { $0 + $1.count } == requested.count)

        // AND the results of EVERY chunk are consumed: UID 5001 sits in the
        // last chunk, and it is soft-deleted alongside its earlier-chunk
        // siblings. A probe that read only the first chunk would have retired
        // it as absent and left it unflagged.
        let stores = Self.deletedStores(server)
        #expect(stores.count == 1)
        guard stores.count == 1 else { return }
        for uid in Self.oversizedLiveUIDs {
            #expect(
                server.flags(in: "Work", uid: uid).contains("\\Deleted"),
                "UID \(uid) was live in the source but was not soft-deleted: \(stores[0])")
        }
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// The queue-facing half of the case above: **a completing attempt on an
    /// oversized batch reaches a permitted never-drop exit for EVERY member**,
    /// so the drain retires the op instead of requeueing it.
    ///
    /// The wedge is not "the row disappeared" — the row survives. It is that an
    /// op which stays queued forever, re-issuing its `UID COPY` on every drain,
    /// blocks every later intention in its lane and seats a destination
    /// duplicate each time. The observable that closes it is this one: the move
    /// RETURNS, it reports all `ids`, and exactly one `UID COPY` reached the
    /// wire with exactly one copy per member at the destination.
    ///
    /// Members 2…4,998 and 5,000-odd others are not in the source at all: the
    /// server itself says so (exit 2, `RFC 3501 §6.4.8` — a `UID COPY` naming
    /// them is a silent no-op), which is why they retire with zero mutation.
    /// The four the source still holds moved. No member is left undetermined,
    /// which is the whole of the exit closure at batch scale.
    @Test("An oversized move completes with every member dispositioned and one copy per member")
    func anOversizedMoveClosesEveryMembersExit() async throws {
        let server = Self.oversizedMoveServer()
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        server.expectMutations(Self.oversizedLiveUIDs.map { "oversized-\($0)@example.com" })
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let ids = (1...Self.oversizedRequestCount).map(String.init)
        let proven = try await provider.move(
            ids: ids, from: "Work", to: "Archive", admittedUidValidity: Self.epoch).provenIds

        // EVERY member reached an exit — none is left for a later drain to
        // re-attempt, which is what makes the re-COPY unreachable.
        #expect(Set(proven) == Set(ids))
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        // Exactly one copy per moved member: a requeue-and-re-COPY shows up
        // here as a duplicate long before it shows up anywhere else.
        #expect(server.messageIDs(in: "Archive").count == Self.oversizedLiveUIDs.count)
        #expect(
            Set(server.messageIDs(in: "Archive"))
                == Set(Self.oversizedLiveUIDs.map { "<oversized-\($0)@example.com>" }))
        // The move happened reversibly, and nothing was destroyed: no UIDPLUS,
        // so no purge is authorized at all (IOS-IMAP-001).
        #expect(Self.deletedStores(server).count == 1)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(Self.bareExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").count == Self.oversizedLiveUIDs.count)
        #expect(server.wrongMessageViolations().isEmpty)
    }

    /// 🚨 **AUDIT ROUND 5 — A DROPPED INTENTION, fail-open.** Round 4's probe
    /// loop read `guard let uid = info.uid, requestedValues.contains(uid.value)
    /// else { continue }`, folding an UNPARSEABLE record into the same arm as a
    /// UID the call never asked about. The two are opposites. Filtering a
    /// UID we did not request NARROWS a destructive set; skipping a record we
    /// could not read makes the member it described MISSING from the live set —
    /// and the caller reads absence from that set as the server positively
    /// stating the member has left the source mailbox, retires it as exit 2 and
    /// mutates nothing. The member's move is dropped without ever being
    /// performed.
    ///
    /// RFC 3501 §6.4.8 requires the UID data item in any FETCH response caused
    /// by a UID command, so a nil `uid` is a MALFORMED response — *"we could
    /// not determine the answer"*, which
    /// `Companion/Rules/Active/never-drop-user-intention.md` names explicitly
    /// as not one of the four exits. Absence of evidence is not evidence of
    /// absence.
    ///
    /// THE PROPERTY, as an end state: **an unanswerable probe retires NOBODY
    /// and mutates NOTHING.** Not the member whose record was unreadable, and
    /// not its sibling whose record was perfectly fine either — a record with
    /// no parseable UID does not say which member it describes, so there is no
    /// member to exclude and the whole probe is inconclusive. The op stays
    /// queued (the call throws) and the disposition is the RETRYABLE one.
    ///
    /// RED PROOF (recorded): with the `guard let uid = info.uid` arm reverted
    /// to `continue`, the move RETURNS instead of throwing (failing
    /// `thrown != nil`), soft-deletes UID 201 only, and reports both members
    /// complete — UID 202 retired as "the server says it is gone" on the
    /// strength of a response nobody could read.
    @Test("A probe record with no parseable UID retires nobody and keeps the move retryable")
    func anUnparseableProbeRecordRetiresNobody() async throws {
        let readable = "unparsed-readable@example.com"
        let unreadable = "unparsed-unreadable@example.com"
        // No UIDPLUS, so no `COPYUID` and the probe runs over both members.
        let server = FakeIMAPServer(
            capabilities: Self.ownedCapabilities.filter { $0 != "UIDPLUS" },
            mailboxes: [
                "Work": [Self.message(201, readable), Self.message(202, unreadable)],
                "Archive": [],
            ])
        server.setUidValidity(Int(Self.epoch), for: "Work")
        server.setUidValidity(Int(Self.epoch), for: "Archive")
        // The nonconforming shape: UID 202's FETCH record omits the UID data
        // item RFC 3501 §6.4.8 makes mandatory. The message is present, was
        // copied, and the server simply failed to say which record is which.
        server.suppressFetchUid(in: "Work", uids: [202])
        server.expectMutations([readable, unreadable])
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        var thrown: Error?
        do {
            _ = try await provider.move(
                ids: ["201", "202"], from: "Work", to: "Archive",
                admittedUidValidity: Self.epoch)
        } catch {
            thrown = error
        }

        // NON-VACUITY, wire side: the COPY was issued and both copies landed,
        // so the refusal below is caused by the unreadable probe record and not
        // by a fixture that never got that far.
        #expect(Self.commands(server, containing: "UID COPY").count == 1)
        #expect(Set(server.messageIDs(in: "Archive")) == ["<\(readable)>", "<\(unreadable)>"])
        #expect(!Self.uidFetchNamedUIDs(server).isEmpty)

        // THE PROPERTY: nobody retired, nothing mutated in the source.
        #expect(thrown != nil, "an unanswerable liveness probe must refuse, not complete")
        #expect(Self.deletedStores(server).isEmpty)
        #expect(Self.anyExpunges(server).isEmpty)
        #expect(server.messageIDs(in: "Work").count == 2)
        #expect(server.flags(in: "Work", uid: 201).isEmpty)
        #expect(server.flags(in: "Work", uid: 202).isEmpty)
        #expect(server.wrongMessageViolations().isEmpty)

        // AND the disposition is the retryable one. `ProviderEvidenceUnavailable`
        // is the drain arm that requeues, bumps `retryCount`, attempts the op at
        // most once per drain and — the half that matters — does NOT insert the
        // account into `failedAccounts`. The two typed signals the drain retires
        // or drops on must not appear: nothing here proved an epoch moved, and
        // nothing here is a verdict on an identity.
        if let thrown {
            #expect(
                thrown is ProviderEvidenceUnavailable,
                "an unanswerable probe must reach the retryable, account-preserving drain arm")
            if case ProviderError.uidValidityChanged = thrown {
                Issue.record("a malformed probe response is not a proven turnover and must never be retired as one")
            }
            if case ProviderError.actionIdentityResolutionFailed = thrown {
                Issue.record("a malformed probe response is not a verdict on an identity and must never be dropped as one")
            }
        }
    }

    // MARK: - T3.1 — an epoch change between steps refuses the remaining steps

    @Test("A UIDVALIDITY turnover between the COPY and the source delete refuses the delete")
    func epochTurnoverAfterCopyRefusesTheDelete() async throws {
        let target = "epoch-copy-target@example.com"
        let decoy = "epoch-copy-decoy@example.com"
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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
        let server = FakeIMAPServer(capabilities: Self.ownedCapabilities, mailboxes: [
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

    // MARK: - #115 round 3b — the response code is read STRUCTURALLY

    /// GitHub #115 round 3b. The fragile-contract pin for
    /// `IMAPProvider.leadingResponseCode(inRenderedReason:)`, over the EXACT
    /// strings SwiftMail produces rather than invented ones.
    ///
    /// SwiftMail's `MoveHandler.handleTaggedErrorResponse` builds the payload of
    /// both move-failure cases as `String(describing: response.state)`, and
    /// `TaggedResponse.State` wraps a `ResponseText` whose `debugDescription`
    /// re-encodes the WIRE form `[CODE] text`. The refusal therefore arrives as
    /// `no([TRYCREATE] …)` / `bad([CANNOT] …)`. That rendering is NOT an API
    /// contract, so this test exists to make an upstream change to it fail a
    /// test instead of silently changing behaviour — the observed strings were
    /// captured from `FakeIMAPServer` before the extractor was written.
    ///
    /// THE PROPERTY IS STRUCTURAL: RFC 3501 §7.1 gives
    /// `resp-text = ["[" resp-text-code "]" SP] text`, so a bracketed atom is a
    /// response code only at the very START of the resp-text. The two `nil`
    /// cases are the load-bearing ones — a code named in the middle of the
    /// server's prose, and a plain uncoded refusal — because reading either as
    /// authority would let the server's wording retire a user's intention. The
    /// end-to-end counterpart is
    /// `NeverDropExitClosureTests.aRefusalWhoseHumanTextMentionsACodeLaterStaysQueued`.
    ///
    /// ROUND 4 — the UNCLOSED-BRACKET rows are load-bearing for the same reason,
    /// and they were reproduced against the real NIOIMAP parser: for every one
    /// of them `parseResponseText` accepts the input as plain text with
    /// `ResponseText.code == nil`, so the server stated NO response code at all,
    /// and a reader that took the atom after `[` without requiring the closing
    /// bracket the §7.1 grammar mandates would retire a user's move on a
    /// non-code.
    @Test(
        "The leading response code is read as RFC 3501 §7.1 structure, never as a substring",
        arguments: [
            ("no([TRYCREATE] UID MOVE destination does not exist)", "TRYCREATE"),
            ("bad([CANNOT] Policy forbids this move)", "CANNOT"),
            ("no([NOPERM] Permission denied)", "NOPERM"),
            ("no([UNAVAILABLE] Backend temporarily unavailable)", "UNAVAILABLE"),
            ("no(Move refused, see [TRYCREATE] semantics)", nil),
            ("no(No mailbox selected)", nil),
            ("no([TRYCREATE temporary diagnostic)", nil),
            ("no([CANNOT temporary failure)", nil),
            ("no([NOPERM extra] Temporary failure)", nil),
            ("no([NONEXISTENT UID not found)", nil),
            ("no([TRYCREATE)", nil),
        ] as [(String, String?)])
    func leadingResponseCodeIsReadStructurally(
        rendered: String, expected: String?
    ) {
        #expect(
            IMAPProvider.leadingResponseCode(inRenderedReason: rendered) == expected,
            """
            \(rendered) parsed as \
            \(String(describing: IMAPProvider.leadingResponseCode(inRenderedReason: rendered))) \
            rather than \(String(describing: expected)). A response code is a protocol statement \
            only in RFC 3501 §7.1's leading position; anywhere else it is the server's prose, and \
            reading it as authority retires a user intention on a sentence.
            """)
    }
}
