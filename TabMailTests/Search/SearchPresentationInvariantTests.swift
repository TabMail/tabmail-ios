/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// `IOS-IMAP-001` — **the FIFTH consumer of `MessageHeaderInfo` that reaches the
/// user, and the only one that PRESENTS without MATERIALISING a `MessageHeader`.**
///
/// ## The two system properties pinned here, stated once
///
/// 1. **A message the server reports `\Deleted` is never presented as a live
///    search result.** (RFC 3501 §2.3.2 — the flag means "pending removal".)
/// 2. **No result the user can tap is a no-op.**
///
/// Neither is asserted as a mechanism. The first is asserted on what the SEARCH
/// SHOWS after the values have travelled the real wire through the real producer
/// (`IMAPProvider.mapMessageInfo`), so a re-implementation that filters somewhere
/// else still passes and one that stops filtering still fails. The second is
/// asserted on the OUTCOME of a tap, and `SearchView.ResultTapOutcome` has no
/// silent case at all — a future refactor cannot reintroduce silence without
/// adding one.
///
/// ## Why the census could not find this path (MIS-007 instance 5)
///
/// The census that previously closed this register row enumerated **sites that
/// build a `MessageHeader` from a `MessageHeaderInfo`** — four of them. Under that
/// noun it was complete. `SearchView.searchAccount` maps `MessageHeaderInfo`
/// straight into `SearchResult` and constructs no `MessageHeader` at all, so it was
/// invisible **by construction**, not by oversight. The noun that finds it is
/// *consumers of the source type*: `rg -n 'MessageHeaderInfo' TabMail/ Shared/`.
///
/// ## The scenario, on the exact server class the row is about
///
/// No UIDPLUS ⇒ the `COPYUID`-gated purge can never fire ⇒ a completed move leaves
/// its source copy soft-deleted and present. `IMAPProvider.searchOnConnection`
/// issues its criteria with **no `NOT DELETED` term** (deliberately, and unchanged
/// — see `presentableRemoteResults`), so the server hands the residue back. The
/// user saw **two hits for one email**, and tapping the residue did **nothing**:
/// the residue is the hit with no local row, and `openResult`'s remote branch
/// returned silently on a nil resolve.
///
/// ## A1 — the shipped release is not a template here
///
/// `git show 07a4bb703:TabMail/Views/Inbox/SearchView.swift` and
/// `git show e28dd4edb:…` (`v2final`): neither has `isDeletedOnServer`, a
/// `NOT DELETED` term, or any alert on the remote branch — both return silently on
/// a nil remote resolve exactly as v3 did. `07a4bb703` has **zero** occurrences of
/// `isDeletedOnServer` tree-wide; it avoided the residue with the mailbox-wide
/// `EXPUNGE` that is BANNED here. The shipped architecture for this problem is
/// NONEXISTENT (A1 step 3), so this is new work, and the dead tap is longstanding
/// behaviour rather than a v3 regression.
///
/// `.serialized` — the fake binds a listening socket; parallel cases would contend
/// on ephemeral port allocation.
@Suite("IOS-IMAP-001 — remote search never presents a \\Deleted message", .serialized)
struct SearchDeletedResiduePresentationTests {

    /// Arbitrary non-zero epoch — RFC 3501 §2.3.1.1 types UIDVALIDITY as
    /// `nz-number` and `requireUidValidity` rejects 0 on either side.
    private static let epoch: UInt32 = 94_501

    /// `FakeIMAPServer.defaultCapabilities` minus `UIDPLUS` — the server class this
    /// row is about, where soft-deleted move sources accumulate because the
    /// `COPYUID`-gated purge can never fire.
    private static let nonUidplusCapabilities =
        ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "MOVE", "IDLE"]

    private static func message(_ uid: Int, _ id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: quarterly invoice\r
        Date: Thu, 01 Jan 2026 00:00:00 +0000\r
        Message-ID: <\(id)>\r
        Content-Type: text/plain; charset=utf-8\r
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

    @Test("A soft-deleted residue the server still returns is not shown as a search result")
    func aDeletedRecordIsNotPresentedAsASearchResult() async throws {
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [
                Self.message(31, "search-live-31@example.com"),
                Self.message(32, "search-residue-32@example.com"),
                Self.message(33, "search-live-33@example.com"),
            ]])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        // The move's source copy: soft-deleted, never expunged, still SEARCHable.
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 32)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let infos = try await provider.search(query: "invoice", folder: "INBOX")

        // NON-VACUITY, and it must be two-sided. (a) The SERVER really did hand the
        // residue back — no `NOT DELETED` term was added to the SEARCH and none is
        // being added, so if this ever stops holding the test below would pass for
        // the wrong reason. (b) The one true producer really did mark it, so the
        // filter has something to act on rather than an already-empty set.
        #expect(infos.map(\.messageId).sorted() == ["31", "32", "33"],
                "the SEARCH must still return the soft-deleted residue — the fix is at presentation, not in the criteria")
        #expect(infos.first { $0.messageId == "32" }?.isDeletedOnServer == true,
                "IMAPProvider.mapMessageInfo must carry \\Deleted through to the value the view receives")

        let presented = SearchView.presentableRemoteResults(
            from: infos, accountId: "acc-search", accountEmail: "user@example.com",
            folderPath: "INBOX")

        #expect(!presented.map(\.messageId).contains("32"),
                "a message the server reports \\Deleted must never be presented as a live search result")
        #expect(presented.map(\.messageId).sorted() == ["31", "33"],
                "and its live siblings must still be shown — hiding the residue must not hide the search")
    }

    @Test("Clearing the \\Deleted flag makes the message searchable again — nothing durable was written")
    func clearingTheDeletedFlagRestoresTheResult() async throws {
        let server = FakeIMAPServer(
            capabilities: Self.nonUidplusCapabilities,
            mailboxes: ["INBOX": [Self.message(41, "search-recover-41@example.com")]])
        server.setUidValidity(Int(Self.epoch), for: "INBOX")
        server.setFlags(["\\Deleted"], in: "INBOX", uid: 41)
        try server.start()
        defer { server.stop() }

        let provider = Self.provider(server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let hidden = SearchView.presentableRemoteResults(
            from: try await provider.search(query: "invoice", folder: "INBOX"),
            accountId: "acc-recover", accountEmail: "user@example.com", folderPath: "INBOX")
        #expect(hidden.isEmpty, "while the server reports \\Deleted the message is not presented")

        // Another client un-deletes it. Hiding is a re-evaluated view of the
        // server's CURRENT flags, never durable local state, so recovery needs no
        // migration, no repair pass and no user gesture beyond searching again.
        // This EXECUTES that recovery rather than asserting it.
        server.setFlags([], in: "INBOX", uid: 41)

        let restored = SearchView.presentableRemoteResults(
            from: try await provider.search(query: "invoice", folder: "INBOX"),
            accountId: "acc-recover", accountEmail: "user@example.com", folderPath: "INBOX")
        #expect(restored.map(\.messageId) == ["41"],
                "clearing the flag must relist the message — the hide must not have been durable")
    }
}

/// **No result the user can tap is a no-op.**
///
/// `SearchView.openResult` resolves fail-CLOSED on both branches, and `nil` is far
/// more common than a reader expects: a re-seated local address, and — on the
/// remote branch — *every* hit for a message this device has not downloaded. The
/// remote branch answered that `nil` by returning, so the tap did nothing at all,
/// which is the worst of the three possible behaviours: it is indistinguishable
/// from a broken app, and it teaches the user that search results are not tappable.
///
/// These assert the OUTCOME of a tap, which is the property; `ResultTapOutcome`
/// carries no silent case, so the invariant is structural rather than asserted.
/// Pure — no view, no database, no socket.
@Suite("Search result taps always produce a visible outcome")
struct SearchResultTapOutcomeTests {

    private func remoteResult() -> SearchResult {
        SearchResult(
            source: .remote, accountId: "acc-a", accountEmail: "user@example.com",
            messageId: "77", folderPath: "INBOX", subject: "quarterly invoice",
            from: "Sender", fromAddress: "sender@example.com", date: Date(),
            snippet: "", isRead: false, isFlagged: false, headerId: nil)
    }

    private func localResult(witness: String?) -> SearchResult {
        SearchResult(
            source: .local, accountId: "acc-a", accountEmail: "user@example.com",
            messageId: "77", folderPath: "INBOX", subject: "quarterly invoice",
            from: "Sender", fromAddress: "sender@example.com", date: Date(),
            snippet: "", isRead: false, isFlagged: false,
            headerId: "acc-a:INBOX:77", capturedRfc822MessageId: witness)
    }

    @Test("A remote result with no local row explains itself rather than doing nothing")
    func anUnresolvableRemoteResultIsNeverSilent() {
        let outcome = SearchView.tapOutcome(for: remoteResult(), resolvedHeaderId: nil)
        #expect(outcome == .explainRemoteResultNotOnThisDevice,
                "tapping a remote hit this device has no copy of must tell the user so, never navigate nowhere in silence")
    }

    @Test("A local result whose content witness no longer matches explains itself")
    func anUnresolvableLocalResultIsNeverSilent() {
        let outcome = SearchView.tapOutcome(
            for: localResult(witness: "witness@example.com"), resolvedHeaderId: nil)
        #expect(outcome == .explainStaleLocalResult,
                "a refused local open must stay explained — this arm is the one that already worked and must not regress")
    }

    /// The negative case, stated because the absolute above is otherwise unfalsifiable:
    /// a REFUSAL is not the only outcome, so a fix that simply refused everything
    /// would satisfy the two cases above and fail these two.
    @Test("A resolvable remote result opens — carrying no witness, because its resolve proved none")
    func aResolvableRemoteResultOpensWithoutAnUnprovenWitness() {
        let outcome = SearchView.tapOutcome(
            for: remoteResult(), resolvedHeaderId: "acc-a:INBOX:77")
        #expect(outcome == .open(SearchView.OpenTarget(
            headerId: "acc-a:INBOX:77", provenRfc822MessageId: nil)),
                "the remote resolve validates an address only, so handing MessageDetailView a witness it never checked would be a false proof")
    }

    @Test("A resolvable local result opens carrying the witness its resolve validated")
    func aResolvableLocalResultCarriesItsWitness() {
        let outcome = SearchView.tapOutcome(
            for: localResult(witness: "witness@example.com"),
            resolvedHeaderId: "acc-a:INBOX:77")
        #expect(outcome == .open(SearchView.OpenTarget(
            headerId: "acc-a:INBOX:77", provenRfc822MessageId: "witness@example.com")),
                "the proof is worth nothing to the consumer that mutates unless it travels with the address")
    }
}
