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
/// asserted on the EFFECT of a tap — the visible consequence — not merely on the
/// outcome the classifier returns.
///
/// 🚨 CORRECTED 2026-08-04. This paragraph used to read *"`SearchView
/// .ResultTapOutcome` has no silent case at all — a future refactor cannot
/// reintroduce silence without adding one."* **False, and it was the stated reason
/// the wiring went untested.** Swift exhaustiveness forces a case to EXIST, not to
/// DO anything: `case .explainRemoteResultNotOnThisDevice: break` compiles, adds no
/// case, and restores the dead silent tap. That was run, not reasoned — every test
/// in `SearchResultTapOutcomeTests` stayed GREEN through it. See
/// `SearchTapEffectWiringTests` below for what replaced the claim.
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
/// ⚑ THESE ASSERT THE CLASSIFIER ONLY, AND THAT IS NOT THE SYSTEM PROPERTY.
/// The doc here used to claim *"`ResultTapOutcome` carries no silent case, so the
/// invariant is structural rather than asserted"* — false reasoning that justified
/// leaving the wiring uncovered. Swift exhaustiveness forces a case to EXIST, not to
/// DO anything; a `break` in the consumer reintroduces silence with every case still
/// present and every test in this suite still green (observed 2026-08-04).
///
/// This suite is kept because "the classifier decides the right thing" is a real,
/// useful proposition — it is just a strictly weaker one than "the user sees
/// something". `SearchTapEffectWiringTests` below asserts the latter.
/// Pure — no view, no database, no socket.
@Suite("Search result taps always produce a visible outcome")
struct SearchResultTapOutcomeTests {

    private func remoteResult(witness: String? = nil) -> SearchResult {
        SearchResult(
            source: .remote, accountId: "acc-a", accountEmail: "user@example.com",
            messageId: "77", folderPath: "INBOX", subject: "quarterly invoice",
            from: "Sender", fromAddress: "sender@example.com", date: Date(),
            snippet: "", isRead: false, isFlagged: false, headerId: nil,
            capturedRfc822MessageId: witness)
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
    /// 🚨 REWRITTEN, AND THE REASON IS THE WHOLE LESSON (2026-08-04). This case used
    /// to be `aResolvableRemoteResultOpensWithoutAnUnprovenWitness`, asserting
    /// `provenRfc822MessageId: nil` for a remote open with the rationale *"the remote
    /// resolve validates an address only, so handing MessageDetailView a witness it
    /// never checked would be a false proof."*
    ///
    /// **It blessed the defect, and — the dangerous part — it would have stayed
    /// GREEN through the fix**, because its fixture hand-minted a `SearchResult` with
    /// no witness at all, so `nil` in and `nil` out. A blessing test that cannot go
    /// red is invisible to every gate; only reading it finds it. It is rewritten
    /// rather than deleted because its subject — *a resolvable remote result opens* —
    /// is a property that must hold; only its claim about the WITNESS was false
    /// doctrine.
    ///
    /// Why the doctrine was false: a remote result's witness is
    /// `MessageHeaderInfo.rfc822MessageId`, the SERVER's Message-ID for the record
    /// the row rendered. It needs no local row, and it is not "unproven" in any
    /// direction that matters — its only consumer can REFUSE a durable mark-read and
    /// can never select or widen a target (ADR-IOS-068 / D4 permits exactly this
    /// direction). The two cases below are the same tap with and without a witness
    /// to carry, which is what makes each one falsifiable.
    @Test("A resolvable remote result opens carrying the provider's Message-ID as its witness")
    func aResolvableRemoteResultCarriesTheProviderWitness() {
        let outcome = SearchView.tapOutcome(
            for: remoteResult(witness: "<server-side@example.com>"),
            resolvedHeaderId: "acc-a:INBOX:77")
        #expect(outcome == .open(SearchView.OpenTarget(
            headerId: "acc-a:INBOX:77", provenRfc822MessageId: "<server-side@example.com>")),
                "the provider handed us the Message-ID of the record this row rendered; discarding it leaves the open's durable mark-read unwitnessed on a re-seatable address")
    }

    @Test("A resolvable remote result whose provider supplied no Message-ID opens carrying nil")
    func aResolvableRemoteResultWithoutAWitnessOpensCarryingNil() {
        let outcome = SearchView.tapOutcome(
            for: remoteResult(), resolvedHeaderId: "acc-a:INBOX:77")
        #expect(outcome == .open(SearchView.OpenTarget(
            headerId: "acc-a:INBOX:77", provenRfc822MessageId: nil)),
                "an absent witness must stay absent — inventing one is the false proof the original rationale correctly feared, and ExpectedMessageIdentity rejects it into today's fail-open behaviour")
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

/// **THE SYSTEM PROPERTY: the user sees something.**
///
/// 🚨 WHY THIS SUITE EXISTS, AND WHAT IT REPLACES (Testing rule 12 — pin the
/// INVARIANT, not the mechanism). `SearchResultTapOutcomeTests` above asserts what
/// `tapOutcome` RETURNS. That is the classifier. The property the user experiences
/// is one hop later: what the view DOES with that answer. Those are different
/// propositions and only the weaker one was covered, defended by the false claim
/// that an enum without a silent case makes silence impossible.
///
/// **The red proof, run rather than argued.** Replacing the consumer's branch with
/// `case .explainRemoteResultNotOnThisDevice: break` compiles, adds no enum case,
/// and restores the invisible dead tap — and every test in the suite above stayed
/// GREEN through it. A test that cannot go red on the defect it names is not
/// evidence (MIS-014).
///
/// So the branching moved out of the view into `SearchView.effect(of:)`, where the
/// mapping from decision to visible consequence is a VALUE. An outcome that maps to
/// nothing visible now fails `everyOutcomeProducesAVisibleEffect` instead of
/// compiling in silence.
///
/// ⚑ THE HONEST BOUNDARY, stated because the claim this replaces was an
/// unfalsifiable absolute (MIS-019): the final hop — `openResult` assigning these
/// three fields onto `@State` — is still NOT covered here, because it needs a hosted
/// SwiftUI view. What changed is that `openResult` no longer decides anything, so
/// there is no branch left in it to `break` out of; a regression there must now be a
/// visible deletion of an assignment. That is a reduction in exposure, not a proof,
/// and calling it structural would repeat the exact error above.
@Suite("Search taps — the visible effect, not just the classified outcome")
struct SearchTapEffectWiringTests {

    /// Every `ResultTapOutcome`, as a roster a test can iterate.
    ///
    /// 🚨 KEPT HONEST BY A COMPILE ERROR, NOT BY DILIGENCE (MIS-007 — a census
    /// inherits its search shape). `discriminator(of:)` switches this enum
    /// exhaustively, so ADDING A CASE STOPS COMPILING until it is handled, and
    /// `everyOutcomeIsAccountedFor` then fails until this roster carries it too. A
    /// hand-written roster with no such guard silently stops being complete on the
    /// day a case is added — which is precisely how an uncovered path survives.
    private static let allOutcomes: [SearchView.ResultTapOutcome] = [
        .open(SearchView.OpenTarget(headerId: "acc-a:INBOX:77", provenRfc822MessageId: nil)),
        .explainStaleLocalResult,
        .explainRemoteResultNotOnThisDevice,
    ]

    private func discriminator(of outcome: SearchView.ResultTapOutcome) -> String {
        switch outcome {
        case .open: return "open"
        case .explainStaleLocalResult: return "explainStaleLocalResult"
        case .explainRemoteResultNotOnThisDevice: return "explainRemoteResultNotOnThisDevice"
        }
    }

    @Test("The outcome roster covers every case exactly once")
    func everyOutcomeIsAccountedFor() {
        let tags = Self.allOutcomes.map(discriminator(of:))
        #expect(Set(tags).count == tags.count, "the roster must not list one case twice")
        #expect(Set(tags) == ["open", "explainStaleLocalResult", "explainRemoteResultNotOnThisDevice"],
                "a case was added to ResultTapOutcome without being added to allOutcomes — the exhaustive switch in discriminator(of:) is what sent you here")
    }

    @Test("Every tap outcome produces a visible effect — no outcome is a no-op")
    func everyOutcomeProducesAVisibleEffect() {
        for outcome in Self.allOutcomes {
            #expect(SearchView.effect(of: outcome).isVisible,
                    "\(discriminator(of: outcome)) mapped to an effect that navigates nowhere and explains nothing — that IS the dead silent tap, restored")
        }
    }

    @Test("A remote hit this device has no copy of raises its alert and navigates nowhere")
    func remoteUnavailableRaisesExactlyItsOwnAlert() {
        #expect(SearchView.effect(of: .explainRemoteResultNotOnThisDevice)
            == SearchView.TapEffect(navigate: nil,
                                    explainStaleLocalResult: false,
                                    explainRemoteResultNotOnThisDevice: true),
                "the end state, including the falses — a silent regression shows up here as an all-false effect")
    }

    @Test("A stale local result raises its alert and navigates nowhere")
    func staleLocalRaisesExactlyItsOwnAlert() {
        #expect(SearchView.effect(of: .explainStaleLocalResult)
            == SearchView.TapEffect(navigate: nil,
                                    explainStaleLocalResult: true,
                                    explainRemoteResultNotOnThisDevice: false))
    }

    @Test("An open navigates and raises no alert at all")
    func openNavigatesAndExplainsNothing() {
        let target = SearchView.OpenTarget(
            headerId: "acc-a:INBOX:77", provenRfc822MessageId: "witness@example.com")
        #expect(SearchView.effect(of: .open(target))
            == SearchView.TapEffect(navigate: target,
                                    explainStaleLocalResult: false,
                                    explainRemoteResultNotOnThisDevice: false),
                "an open must also CLEAR the alert flags — the assignments in openResult are unconditional so a raised flag cannot survive into the next tap")
    }

    /// The whole chain a tap takes, minus the `@State` assignment: resolve result →
    /// classify → visible effect. This is the proposition the old suite could not
    /// state, because it stopped at the middle term.
    @Test("An unresolvable remote tap ends in a visible explanation, end to end")
    func anUnresolvableRemoteTapEndsVisible() {
        let result = SearchResult(
            source: .remote, accountId: "acc-a", accountEmail: "user@example.com",
            messageId: "77", folderPath: "INBOX", subject: "quarterly invoice",
            from: "Sender", fromAddress: "sender@example.com", date: Date(),
            snippet: "", isRead: false, isFlagged: false, headerId: nil,
            capturedRfc822MessageId: nil)
        let effect = SearchView.effect(
            of: SearchView.tapOutcome(for: result, resolvedHeaderId: nil))
        #expect(effect.isVisible, "a tap that resolves to nothing must still tell the user something")
        #expect(effect.explainRemoteResultNotOnThisDevice)
        #expect(effect.navigate == nil)
    }
}

/// **The `\Deleted` filter, pinned ON THE PATH THE SEARCH ACTUALLY RETURNS THROUGH.**
///
/// 🚨 THE GAP THIS CLOSES. `SearchDeletedResiduePresentationTests` above proves that
/// `presentableRemoteResults` DROPS a residue — a property of a function nobody was
/// proven to call. The filter sat on the tail of a `@MainActor` view method that
/// builds two `Task`s and a timeout, so no test reached it, and deleting the call
/// would have left that suite entirely green. `SearchView.remoteResults` injects the
/// fetch so the real return path is exercised here.
///
/// ⚑ STILL UNPINNED: that `searchAccount` calls `remoteResults` at all. That hop is
/// one `return await` with no branch, but it is not covered, and this suite must not
/// be read as proving it.
@Suite("Search remote path — the filter and the failure handling, where they run")
struct SearchRemotePathWiringTests {

    private struct FetchFailure: Error {}

    private static func info(_ uid: String, deleted: Bool) -> MessageHeaderInfo {
        var info = MessageHeaderInfo(
            messageId: uid, rfc822MessageId: "server-\(uid)@example.com",
            inReplyTo: nil, references: [], threadId: nil,
            subject: "quarterly invoice", from: "Sender",
            fromAddress: "sender@example.com", to: "user@example.com",
            cc: "", bcc: "", replyTo: nil, date: Date(), snippet: "snippet",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
        info.isDeletedOnServer = deleted
        return info
    }

    private static func results(_ infos: [MessageHeaderInfo]) async -> [SearchResult] {
        await SearchView.remoteResults(
            accountId: "acc-wiring", accountEmail: "user@example.com", folderPath: "INBOX",
            fetch: { infos })
    }

    @Test("A residue the server still returns never reaches the view through the real return path")
    func theReturnPathDropsTheResidue() async {
        let presented = await Self.results([
            Self.info("51", deleted: false),
            Self.info("52", deleted: true),
            Self.info("53", deleted: false),
        ])
        #expect(presented.map(\.messageId).sorted() == ["51", "53"],
                "the filter must sit on the path searchAccount returns through, not merely in a function a test calls directly")
    }

    /// NON-VACUITY. The same three records with the flag cleared must all be
    /// presented — otherwise the assertion above could pass because the path drops
    /// everything, or returns nothing at all.
    @Test("With no \\Deleted flag every record is presented — the filter is not just dropping everything")
    func theReturnPathPresentsLiveRecords() async {
        let presented = await Self.results([
            Self.info("51", deleted: false),
            Self.info("52", deleted: false),
            Self.info("53", deleted: false),
        ])
        #expect(presented.map(\.messageId).sorted() == ["51", "52", "53"])
    }

    /// Ties `IOS-SEARCH-003`'s witness to the same real return path: the round-1 fix
    /// is asserted where the search actually produces its results, not only where a
    /// test calls the mapper directly.
    @Test("The provider's Message-ID reaches the view as the result's content witness")
    func theReturnPathCarriesTheWitness() async {
        let presented = await Self.results([Self.info("51", deleted: false)])
        #expect(presented.map(\.capturedRfc822MessageId) == ["server-51@example.com"],
                "a remote open's durable mark-read is unwitnessed unless the witness travels this path")
    }

    @Test("A cancelled search resolves as empty results, never as a thrown search")
    func cancellationResolvesEmpty() async {
        let presented = await SearchView.remoteResults(
            accountId: "acc-wiring", accountEmail: "user@example.com", folderPath: "INBOX",
            fetch: { throw CancellationError() })
        #expect(presented.isEmpty, "a query change or dismiss must degrade to no results, never propagate out of the search")
    }

    @Test("A failed search resolves as empty results rather than propagating")
    func failureResolvesEmpty() async {
        let presented = await SearchView.remoteResults(
            accountId: "acc-wiring", accountEmail: "user@example.com", folderPath: "INBOX",
            fetch: { throw FetchFailure() })
        #expect(presented.isEmpty)
    }
}
