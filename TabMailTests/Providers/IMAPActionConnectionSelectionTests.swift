/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// T1.1 (E1) — the red-first proof that the IMAP **action** path surrenders
/// the `Mailbox.Selection` it already receives instead of discarding it.
///
/// Before this item `withActionConnection` opened with
/// `_ = try await server.selectMailbox(folder)`: the mailbox's live
/// UIDVALIDITY was on the wire, parsed by SwiftMail, and then thrown away, so
/// no action body could ever see it. That single `_ =` is why nothing
/// downstream can verify an epoch. `withActionConnectionSelection` is the
/// Selection-passing core; `withActionConnection` is now a thin wrapper over
/// it.
///
/// **This item makes the epoch OBSERVABLE and nothing more.** There is no
/// epoch comparison, no drop rule and no `uidValidity` consumer in production
/// yet — those are later items — so these tests assert exactly the property
/// the item delivers: *an action body observes the live UIDVALIDITY of its
/// own SELECT*, plus the behavioral no-op for every existing caller.
///
/// **Red-first evidence (recorded 2026-07-30).** With
/// `withActionConnectionSelection`'s SELECT inverted back to the pre-change
/// discard — `_ = try await server.selectMailbox(folder)` followed by handing
/// the body a `selection` that never saw the wire — both
/// `actionBodyObservesLiveUidValidity` and
/// `actionBodyObservesEpochChangeAcrossTwoActions` fail on their
/// `uidValidity` expectations (observed `0`, expected `424242` / `11` then
/// `22`), while `wrapperStillSelectsAndBehavesIdentically` stays green. The
/// discarding shape cannot satisfy these tests; the surrendering shape is the
/// only thing that makes them pass.
///
/// `.serialized` — `FakeIMAPServer` binds a listening socket; parallel cases
/// would contend on ephemeral port allocation (same reason as
/// `FakeIMAPServerOracleTests`).
@Suite("T1.1 — the action connection surrenders its Mailbox.Selection", .serialized)
struct IMAPActionConnectionSelectionTests {

    // MARK: - Fixtures

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: t1.1-fixture\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        t1.1 fixture body.\r

        """
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: id))
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    // MARK: - The property this item delivers

    /// THE headline red-first proof for T1.1: a body running on the action
    /// connection is handed the `Mailbox.Selection` that connection's own
    /// SELECT returned, carrying the mailbox's real UIDVALIDITY.
    ///
    /// `424242` is deliberately not the fake's default (`1`) and not the
    /// zero a default-constructed `Mailbox.Selection` carries, so the
    /// assertion can only be satisfied by a value that came off the wire.
    @Test("an action body observes the live UIDVALIDITY of its own SELECT")
    func actionBodyObservesLiveUidValidity() async throws {
        let liveEpoch = 424_242
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 11, id: "t11-live@example.com")],
        ])
        server.setUidValidity(liveEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        let observed = try await provider.actionConnectionSelectionUidValidityForTesting(folder: "INBOX")
        try? await provider.disconnect()

        #expect(observed == UInt32(liveEpoch))
        // A discarded SELECT leaves a body with no epoch at all; the zero a
        // default `Mailbox.Selection` carries is what "unknown" looks like.
        #expect(observed != 0)
        // The SELECT really happened on the action connection's wire.
        #expect(server.recordedCommands().contains { $0.uppercased().hasPrefix("SELECT") })
    }

    /// The epoch a body observes is read fresh from its own SELECT on every
    /// call — not cached, not a constant, not a mirror written once at
    /// connect time. The mailbox is replaced (UIDVALIDITY 11 → 22, and the
    /// UID repointed at a different message) the instant the first action's
    /// SELECT is acknowledged; the second action must see the new epoch.
    ///
    /// This is the property every later checkpoint depends on: an epoch
    /// assertion is worthless if the value it reads cannot change.
    @Test("a later action body observes the NEW epoch after the mailbox is replaced")
    func actionBodyObservesEpochChangeAcrossTwoActions() async throws {
        let firstEpoch = 11
        let secondEpoch = 22
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: 5, id: "t11-epoch-e1@example.com")],
        ])
        server.setUidValidity(firstEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        // Armed AFTER connect on purpose: `connect()` only creates and logs in
        // the action connection (no SELECT), so the first command matching
        // "SELECT" is the one the action body below issues.
        try await provider.connect()
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT",
            mailbox: "INBOX",
            uidValidity: secondEpoch,
            messages: [Self.message(uid: 5, id: "t11-epoch-e2@example.com")]
        )

        let first = try await provider.actionConnectionSelectionUidValidityForTesting(folder: "INBOX")
        let second = try await provider.actionConnectionSelectionUidValidityForTesting(folder: "INBOX")
        try? await provider.disconnect()

        #expect(first == UInt32(firstEpoch))
        #expect(second == UInt32(secondEpoch))
        // Same UID, different message — the reset was a real epoch
        // replacement, which is what makes the two observations meaningful.
        #expect(server.messageIDs(in: "INBOX") == ["<t11-epoch-e2@example.com>"])
    }

    // MARK: - The behavioral no-op for every existing caller

    /// `withActionConnection` is now a thin wrapper over
    /// `withActionConnectionSelection`, so its ~27 existing callers must be
    /// unchanged on the wire: the folder is still SELECTed before the body
    /// runs, the body's mutation still lands on the message it named, and the
    /// wrong-message oracle stays silent.
    ///
    /// The SELECT count is pinned at 2 for one `markRead`: the wrapper's own
    /// SELECT plus the pre-existing redundant SELECT inside `markRead`'s body
    /// (`IMAPProvider.markRead`, unchanged by this item). Dropping the
    /// wrapper's SELECT during the refactor would show up here as 1.
    @Test("withActionConnection still SELECTs and behaves identically")
    func wrapperStillSelectsAndBehavesIdentically() async throws {
        let targetId = "t11-wrapper@example.com"
        let targetUID = 31
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [Self.message(uid: targetUID, id: targetId)],
        ])
        server.expectMutation(rfc822MessageId: targetId)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(for: server)
        try await provider.connect()
        try await provider.markRead(ids: ["\(targetUID)"], folder: "INBOX")
        try? await provider.disconnect()

        let commands = server.recordedCommands()
        let selectCount = commands.filter { $0.uppercased().hasPrefix("SELECT") }.count
        #expect(selectCount == 2)
        let selectIndex = commands.firstIndex { $0.uppercased().hasPrefix("SELECT") }
        let storeIndex = commands.firstIndex { $0.uppercased().hasPrefix("UID STORE") }
        #expect(selectIndex != nil)
        #expect(storeIndex != nil)
        if let selectIndex, let storeIndex { #expect(selectIndex < storeIndex) }
        #expect(server.wrongMessageViolations().isEmpty)
        #expect(server.flags(in: "INBOX", uid: targetUID).contains("\\Seen"))
    }
}
