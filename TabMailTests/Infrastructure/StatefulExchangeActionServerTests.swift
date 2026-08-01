/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// v3 port of `v2final:TabMailTests/Infrastructure/StatefulExchangeActionServerTests.swift`.
///
/// **The conversion (D4).** The reference addresses every action by RFC 822
/// Message-ID, because `v2final`'s `ExchangeProvider` resolved an RFC identity
/// to a Graph resource id through a source-folder `$filter` search
/// (`resolveActionMessageId`) or an exact-id probe (`resolveTokenMember`).
/// **`v3` has no such layer**: `markRead`/`markFlagged`/`move` pass `ids`
/// straight to `patchMessage(id:)` / `moveMessage(id:)`, so `ids` ARE Graph's
/// native `message.id`. Every assertion the reference made through
/// `snapshots(rfc822MessageId:)` is read here through
/// `snapshot(providerMessageId:)`, the v3-only accessor that had zero callers
/// before this suite.
///
/// **The lookup-failure claim, at its true width.** An earlier revision of this
/// header asserted that "no `v3` code path sends a `$filter`". That is FALSE:
/// `ExchangeProvider.listBackfillMessageIds` and
/// `ExchangeProvider.fetchOlderMessages` both emit one (`receivedDateTime`
/// windows). The claim these tests actually make — and the only one they
/// support — is narrower: **no `v3` ACTION / RFC-resolution path sends the
/// RFC-IDENTITY `$filter`** the reference's `resolveActionMessageId` used
/// (`internetMessageId eq '<…>'`). That is the sole shape the fixture's
/// `failNextLookup()` hook consumes: `StatefulExchangeActionServer`'s
/// `/mailFolders/` route extracts the bracketed identity via
/// `rfcIdentity(fromLookupURL:)` and rejects a `$filter` carrying none, so a
/// `receivedDateTime` window never reaches the counter.
///
/// THREE assertions in this file read `consumedLookupFailureCount() == 0`. Two
/// of them — in `duplicateRfcMutatesOnlyTheAddressedResource` and
/// `ordinaryFolderListingsDecodeIdentityFieldsOrderAndPaging` — are ARMED with
/// `failNextLookup()` first. The third is the deliberately UNARMED baseline
/// inside `armedLookupFailureIsConsumedByAnRfcFilterSearch`, whose job is the
/// opposite one: proving the counter starts at zero so that test's own `== 1`
/// cannot be a leftover from fixture construction.
///
/// Arming is what makes a zero mean anything — an unarmed
/// `consumedLookupFailureCount() == 0` cannot fail no matter what the adapter
/// does, which is precisely the vacuity trap this suite exists to avoid. The
/// converse is NOT claimed: tests that assert nothing about the counter do not
/// arm the hook, and FOUR of the seven tests in this file do exactly that —
/// `opaqueDraftIdStaysOnePathSegment`,
/// `moveReallocatesGraphIdWhilePreservingFields`,
/// `transientMutationFailureLeavesStateUnchanged` and
/// `deleteDraftRetriesOnTheInjectedSessionAfter401` drive full action sequences
/// with neither an arm nor a counter assertion. That is a different subject,
/// not a silent gap. (The count was "three" until
/// `deleteDraftRetriesOnTheInjectedSessionAfter401` was added to this same file
/// without updating it — recount this list whenever a test is added.)
/// `armedLookupFailureIsConsumedByAnRfcFilterSearch` is the matching POSITIVE
/// CONTROL: it proves the oracle fires when the RFC filter really is sent, so
/// the zeros are falsifiable rather than structural.
///
/// **⚠ ADAPTER BOUNDARY, NOT SYSTEM BOUNDARY.** Everything this suite proves
/// about duplicate RFC identities is a property of `ExchangeProvider` — the
/// layer where `ids` are already Graph resource ids. It is NOT a property of
/// the system. `AccountManager.markRead`/`markUnread` call
/// `expandWithSiblingsByRfc822` BEFORE anything is queued, and that helper
/// selects every `messageHeader` row sharing the RFC 822 Message-ID for the
/// account — no folder filter, no provider-id qualification — then queues each
/// sibling's native id. So at the SYSTEM boundary a duplicate-RFC gesture still
/// fans out. Tracked as **D-26** in `PLAN_IOS_REFACTOR_V3.md`; the
/// system-boundary proof is still OWED and must be written as a red-first test
/// against `AccountManager`, not lowered to this boundary. `v2final` has the
/// identical helper with identical SQL, so narrowing it is a production
/// behaviour change needing its own tier — do not smuggle it into a test fix.
///
/// **No `.processGlobalState`.** `v2final` leaves both Stateful*ActionServer
/// suites unannotated, and neither swaps `AppDatabase.shared` nor mutates
/// `AccountManager.shared` — each test owns a private `FakeHTTP.Scenario`.
@Suite("Stateful Exchange action transport (provider-id)")
struct StatefulExchangeActionServerTests {
    /// Partial port of the reference's `opaqueDraftResourceLifecycle`. TWO legs
    /// of the reference test are blocked on `v3` PRODUCTION gaps that `v2final`
    /// had already closed. Both are reported rather than worked around; neither
    /// is fixable from a test file.
    ///
    /// **Gap 1 — no Graph path-segment encoder.** The reference seeds
    /// `graph/draft+opaque=` — with a SLASH — and asserts it arrives as one
    /// percent-encoded segment (`graph%2Fdraft%2Bopaque%3D`), via
    /// `v2final`'s `encodedGraphPathSegment` / `graphPathSegmentAllowed`.
    /// `v3`'s `ExchangeProvider` has no encoder at all and interpolates raw ids
    /// into paths, so a slash-bearing id splits into extra path segments. This
    /// test therefore seeds only the reserved characters `v3` does transmit
    /// intact (`+`, `=`).
    ///
    /// **Gap 2 — CLOSED.** `ExchangeProvider.deleteDraft` used to escape the
    /// injected session: it is the one method that bypasses the file's private
    /// `request()` helper, calling the free `performHTTPRequestWithRetry` /
    /// `performHTTPRequest` with no `session:`, so both fell back to
    /// `sharedEphemeralSession` and issued LIVE requests to
    /// `https://graph.microsoft.com` — omitting this leg was the only way to
    /// keep the suite off the public internet, and including it failed with a
    /// real `Error Domain=Exchange Code=401` from Microsoft. `v2final` passed
    /// `session: testSession` at both call sites; `v3` had dropped it. Both are
    /// restored, so the DELETE leg is now exercised below.
    ///
    /// That leg exercises the restoration, but it does NOT by itself pin either
    /// line, and the distinction matters. If the FIRST request lost `session:`,
    /// Microsoft would answer 401 for the fabricated token, control would fall
    /// into the 401-retry leg, and that retry — still injected — would reach
    /// this fixture with the same method and path, delete the draft, and leave
    /// both assertions below green. If the RETRY lost `session:` it would never
    /// run here at all, because the first DELETE succeeds. Pinning each line
    /// separately needs a response script that forces both legs to run:
    /// `deleteDraftRetriesOnTheInjectedSessionAfter401` does that.
    ///
    /// `previousRfc822MessageId:` is IMAP-only — Exchange PATCHes by the durable
    /// Graph id and ignores it — so it is passed nil here.
    @Test("an opaque Graph draft id stays one path segment for body GET, attachments, and PATCH")
    func opaqueDraftIdStaysOnePathSegment() async throws {
        let opaqueId = "graph-draft+opaque="
        let rfc822 = "opaque-draft@example.com"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: rfc822,
            providerMessageId: opaqueId,
            folderId: "Drafts"
        )])
        defer { server.close() }
        let provider = server.provider()

        let opened = try await provider.fetchMessage(id: opaqueId, folder: "Drafts")
        #expect(opened.textBody == "Stateful draft body")

        _ = try await provider.saveDraft(
            DraftMessage(subject: "Updated", body: "Updated body"),
            existingDraftId: opaqueId,
            previousRfc822MessageId: nil,
            draftsFolderPath: "Drafts"
        )

        // The PATCH addressed the SAME resource, read by provider id — not by
        // RFC — so no second draft was created.
        #expect(server.snapshot(providerMessageId: opaqueId) != nil)

        let calls = server.http.recordedCalls()
        #expect(calls.contains {
            $0.method == "GET" && $0.url.contains("/messages/\(opaqueId)?")
        })
        #expect(calls.contains {
            $0.method == "GET" && $0.url.contains("/messages/\(opaqueId)/attachments")
        })
        #expect(calls.contains {
            $0.method == "PATCH" && $0.url.contains("/messages/\(opaqueId)")
        })
        // Updating an existing draft must PATCH, never create a second resource.
        #expect(!calls.contains { $0.method == "POST" })

        // Gap 2's restored leg. `deleteDraft` addresses the same opaque id, and
        // both of its request paths now carry `session: testSession`.
        try await provider.deleteDraft(draftId: opaqueId, draftsFolderPath: "Drafts")
        #expect(
            server.snapshot(providerMessageId: opaqueId) == nil,
            "deleteDraft must remove the addressed resource from THIS fixture — a surviving snapshot means the DELETE never reached the injected session"
        )
        let afterDelete = server.http.recordedCalls()
        #expect(
            afterDelete.contains { $0.method == "DELETE" && $0.url.contains("/messages/\(opaqueId)") },
            "the fake recorded no DELETE for the draft — the request escaped to the live Graph endpoint instead of the injected session"
        )
    }

    /// Port of the reference's `actionFinalState`, converted to the v3 keying —
    /// and the case that motivated `snapshot(providerMessageId:)` in the first
    /// place (C3-X2).
    ///
    /// The reference followed the message across Graph's move-time id
    /// reallocation by RFC, so the churn was invisible to its assertions. Under
    /// D4 the churn IS the point: the op records the pre-move id, and after the
    /// move that handle names nothing. This asserts exactly that, then recovers
    /// the new id the way production would — from the provider's own listing,
    /// never from the RFC map.
    ///
    /// Not ported: the reference's second, inverse move. The fixture allocates
    /// reallocated ids of the form `graph/moved+N=`, and `v3`'s unencoded path
    /// interpolation cannot address a slash-bearing id (see
    /// `opaqueDraftIdStaysOnePathSegment`). Re-addressing a moved Graph message
    /// is blocked on that production gap.
    @Test("a Graph move reallocates the resource id while preserving field state")
    func moveReallocatesGraphIdWhilePreservingFields() async throws {
        let rfc822MessageId = "exchange-stateful@example.com"
        let originalId = "graph-original-1"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: originalId,
            folderId: "source-folder"
        )])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(ids: [originalId], folder: "source-folder")
        try await provider.markFlagged(
            ids: [originalId], flagged: true, folder: "source-folder"
        )

        let beforeMove = server.snapshot(providerMessageId: originalId)
        #expect(beforeMove != nil)
        guard let beforeMove else { return }
        #expect(beforeMove.folderId == "source-folder")
        #expect(beforeMove.isRead)
        #expect(beforeMove.isFlagged)

        try await provider.move(
            ids: [originalId], from: "source-folder", to: "destination-folder"
        )

        // C3-X2: the op's recorded handle is now stale by construction.
        #expect(server.snapshot(providerMessageId: originalId) == nil)

        let movedHeaders = try await provider.fetchMessages(
            folder: "destination-folder", limit: 10, offset: 0
        )
        #expect(movedHeaders.count == 1)
        guard movedHeaders.count == 1 else { return }
        let movedId = movedHeaders[0].messageId
        #expect(movedId != originalId)
        #expect(movedHeaders[0].rfc822MessageId == rfc822MessageId)
        #expect(movedHeaders[0].isRead)
        #expect(movedHeaders[0].isFlagged)

        let moved = server.snapshot(providerMessageId: movedId)
        #expect(moved != nil)
        guard let moved else { return }
        #expect(moved.folderId == "destination-folder")
        #expect(moved.isRead)
        #expect(moved.isFlagged)

        // The source folder is empty — the move relocated, it did not copy.
        let sourceHeaders = try await provider.fetchMessages(
            folder: "source-folder", limit: 10, offset: 0
        )
        #expect(sourceHeaders.isEmpty)

        // Re-addressing the stale pre-move id must not reach the moved
        // resource. Graph answers 404; classifying that throw belongs to the
        // durable queue, not the transport.
        await #expect(throws: ProviderError.self) {
            try await provider.markUnread(ids: [originalId], folder: "destination-folder")
        }
        let stillRead = server.snapshot(providerMessageId: movedId)
        #expect(stillRead != nil)
        guard let stillRead else { return }
        #expect(
            stillRead.isRead,
            "an op addressed to a churned Graph id must not mutate its successor"
        )
    }

    /// §6.5 headline red proof #2, Graph half — and the direct verification
    /// that the server's "RFC map is observation-only" doc comment is TRUE.
    ///
    /// Replaces the reference's duplicate-RFC leg, which asserted the opposite
    /// outcome for the opposite reason: on `v2final` an ambiguous RFC resolved
    /// to two candidates and the resolver refused, so NEITHER copy changed. On
    /// `v3` the op names one resource and exactly that resource must change.
    @Test("a duplicate RFC identity mutates only the addressed Graph resource")
    func duplicateRfcMutatesOnlyTheAddressedResource() async throws {
        let sharedRFC = "exchange-duplicate@example.com"
        let addressed = "graph-duplicate-1"
        let sibling = "graph-duplicate-2"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: sharedRFC, providerMessageId: addressed, folderId: "source-folder"),
            .init(rfc822MessageId: sharedRFC, providerMessageId: sibling, folderId: "source-folder"),
        ])
        defer { server.close() }
        let provider = server.provider()

        // Observation only: two distinct resources really do share one RFC.
        // This is the ONLY place the RFC map is read.
        let before = server.snapshots(rfc822MessageId: sharedRFC)
        #expect(before.count == 2)
        guard before.count == 2 else { return }
        #expect(before.allSatisfy { !$0.isRead && !$0.isFlagged })

        // ARM the lookup-failure hook BEFORE the action sequence. Without this
        // the `== 0` assertion at the end of the test is unfalsifiable — the
        // counter starts at zero and nothing the adapter could do would move
        // it, so the assertion would pass on an adapter that resolved every
        // action by RFC. Armed, an RFC-identity `$filter` from any action path
        // consumes the credit and the assertion goes red.
        // (`armedLookupFailureIsConsumedByAnRfcFilterSearch` is the positive
        // control proving the hook fires when that request really is sent.)
        server.failNextLookup()

        try await provider.markRead(ids: [addressed], folder: "source-folder")
        try await provider.markFlagged(
            ids: [addressed], flagged: true, folder: "source-folder"
        )

        let target = server.snapshot(providerMessageId: addressed)
        #expect(target != nil)
        guard let target else { return }
        #expect(target.isRead)
        #expect(target.isFlagged)

        // The RFC twin must be byte-identical to its seed.
        let untouched = server.snapshot(providerMessageId: sibling)
        #expect(untouched != nil)
        guard let untouched else { return }
        #expect(untouched == StatefulExchangeActionServer.Snapshot(
            providerMessageId: sibling,
            folderId: "source-folder",
            isRead: false,
            isFlagged: false
        ))

        // A move addressed by provider id relocates only that resource, even
        // though its RFC twin sits in the same source folder.
        try await provider.move(
            ids: [addressed], from: "source-folder", to: "destination-folder"
        )
        #expect(server.snapshot(providerMessageId: addressed) == nil)
        #expect(server.snapshot(providerMessageId: sibling)?.folderId == "source-folder")

        let stillTwo = server.snapshots(rfc822MessageId: sharedRFC)
        #expect(stillTwo.count == 2)
        guard stillTwo.count == 2 else { return }
        #expect(stillTwo.filter { $0.folderId == "destination-folder" }.count == 1)
        #expect(stillTwo.filter { $0.folderId == "source-folder" }.count == 1)

        // Armed above and still unconsumed: no v3 Graph ACTION path resolves a
        // target via an RFC-identity `$filter` search.
        #expect(
            server.consumedLookupFailureCount() == 0,
            "no v3 Graph action path may resolve a target via an RFC $filter search"
        )
    }

    /// **A FIXTURE SELF-CHECK for `consumedLookupFailureCount()`** — not a
    /// system property, and not a discharge of the reference's obligation.
    ///
    /// ⚑ NO REFERENCE — INVENTED. `v2final` produced its `== 1` from a REAL
    /// action: `resolveActionMessageId` issued the RFC `$filter` search, so the
    /// reference's control was a statement about the adapter. `v3` deleted that
    /// layer and — unlike Gmail, whose `search(query:folder:…)` forwards a
    /// caller-supplied query into `q=` and so can still reach its counterpart
    /// hook from production — Exchange has NO production driver at all:
    /// `ExchangeProvider.search` puts the caller's query into `$search="…"`,
    /// never into an `internetMessageId` `$filter`. Nothing a caller can ask
    /// for turns into this request. So the driver below is synthetic, and what
    /// it checks is correspondingly narrow: that the FIXTURE's hook, route and
    /// counter are alive. It says nothing about `ExchangeProvider`.
    ///
    /// That narrow check is still worth having. Without any `== 1` anywhere in
    /// the suite, `consumedLookupFailureCount() == 0` is testing a counter
    /// nothing ever increments: a mis-registered route, a renamed query
    /// parameter, or an `rfcIdentity(fromLookupURL:)` that silently stopped
    /// parsing would all leave every zero-assertion in this file green while
    /// proving nothing whatsoever. This drives the same route, extraction and
    /// counter those zeros depend on, so a dead hook fails HERE instead of
    /// quietly certifying the rest of the suite. What remains OWED is a
    /// system-level `== 1`, and no test in this file supplies it.
    ///
    /// The URL is NOT the reference's exact request shape and does not claim to
    /// be. `v2final:TabMail/Providers/ExchangeProvider.swift`'s
    /// `resolveActionMessageId` sent `$select=id,parentFolderId,internetMessageId`,
    /// `$filter=internetMessageId eq '<escapedWireId>'` and `$top=2`;
    /// `rfcFilterLookupURL` sends `$select=id` and the same `$filter`, with no
    /// `$top`. The `$filter` is the only part the hook keys on — the fixture's
    /// `/mailFolders/` route extracts the bracketed identity via
    /// `rfcIdentity(fromLookupURL:)` and rejects a `$filter` carrying none — so
    /// the other parameters are immaterial to what is being checked.
    @Test("the armed lookup failure IS consumed by an RFC $filter search — the oracle fires")
    func armedLookupFailureIsConsumedByAnRfcFilterSearch() async throws {
        let rfc822MessageId = "exchange-positive-control@example.com"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: "graph-positive-control-1",
            folderId: "source-folder"
        )])
        defer { server.close() }

        // Baseline: the counter is zero before anything is armed, so the
        // increment below cannot be a leftover from fixture construction.
        #expect(server.consumedLookupFailureCount() == 0)

        server.failNextLookup()

        let url = StatefulExchangeActionServer.rfcFilterLookupURL(
            folderId: "source-folder",
            rfc822MessageId: rfc822MessageId
        )
        let (_, response) = try await server.http.session.data(from: url)
        #expect(
            (response as? HTTPURLResponse)?.statusCode == 503,
            "the armed lookup failure must surface as the fixture's 503, proving the request matched the RFC-filter route"
        )
        #expect(
            server.consumedLookupFailureCount() == 1,
            "an RFC-identity $filter search MUST consume the armed lookup failure — if it does not, every `== 0` assertion in this suite is vacuous"
        )

        // And the credit is single-shot: a second identical search is served
        // normally, so the counter measures armed consumption, not traffic.
        let (_, secondResponse) = try await server.http.session.data(from: url)
        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.consumedLookupFailureCount() == 1)
    }

    /// Port of the reference's transient-failure leg, keeping only the half
    /// `v3` can reach. `failNextLookup()` gates the RFC-IDENTITY `$filter`
    /// request (`internetMessageId eq '<…>'`) that no `v3` path sends — v3 does
    /// emit `$filter` elsewhere, from `ExchangeProvider.listBackfillMessageIds`
    /// and `fetchOlderMessages`, but those carry `receivedDateTime` windows and
    /// never reach this hook. `failNextMutation()` gates exactly three fixture
    /// handlers — `/messages/` PATCH, DELETE, and POST.
    ///
    /// ⚠ CORRECTED 2026-07-31. The previous revision of this paragraph made two
    /// counted claims, both false, both re-verified against `ExchangeProvider`
    /// before replacement.
    ///
    /// (1) It said those three gates "cover every mutating method
    /// `ExchangeProvider` has". They do not. `send(draft:)` POSTs `/sendMail`, and
    /// `saveDraft`'s create branch POSTs `/mailFolders/drafts/messages` — neither
    /// URL contains the `/messages/` substring the fixture matches on, so neither is
    /// gated at all. (`appendToSentFolder` and `setActionTag` issue no HTTP, so they
    /// are vacuously outside it.)
    ///
    /// (2) It said `markRead`/`markUnread`/`markFlagged` "and ONLY those three"
    /// reach the private `patchMessage(id:body:)`, and that `move` does NOT. Both
    /// halves are wrong. `move(ids:from:to:)` calls `stripLegacyCategories(id:)` on
    /// its `source == inboxFolderId` branch — the MAINLINE inbox-triage path
    /// (archive, delete, move out of INBOX) — and `stripLegacyCategories` ends in
    /// `patchMessage(id:body:)`. `saveDraft`'s update branch PATCHes
    /// `/messages/{id}` as well. Accurately: PATCH is reached by `markRead`,
    /// `markUnread`, `markFlagged`, `saveDraft`'s update branch, and `move` via the
    /// category strip; POST `/messages/{id}/move` by `move`; DELETE by
    /// `deleteDraft`.
    ///
    /// Why (2) matters beyond the wording: a move-from-INBOX issues its strip PATCH
    /// BEFORE its move POST, so an injected failure could be consumed by the PATCH
    /// rather than by the verb a test names. Checked — this leg still pins what it
    /// intends, for three independent reasons. This test drives `markRead`, not
    /// `move`; `failNextMutation()` has no other call site in the tree; and in this
    /// fixture the strip cannot PATCH at all, because `inboxFolderId` is populated
    /// only inside `fetchFolders()`, which these tests never call, so
    /// `source == inboxFolderId` is false — and even with it populated, `graphRow`
    /// seeds `"categories": []`, so `stripLegacyCategories` returns at its `guard`
    /// before reaching `patchMessage`. Its unconditional
    /// `GET /messages/{id}?$select=categories` would not consume the credit either:
    /// the fixture's `/messages/` GET handler does not check the flag. 🚨 **Anyone
    /// adding a `move`-based transient-failure test MUST re-derive this** — it holds
    /// because of this fixture's state, not because of the routing.
    ///
    /// This test drives `markRead`, i.e. the PATCH gate.
    ///
    /// (Two corrections to an earlier revision of this paragraph, recorded
    /// because both were review-invisible. It claimed "all four … action
    /// methods" while enumerating only three of the four plus `deleteDraft`,
    /// silently dropping `markUnread` — a live production action:
    /// `AccountManager.markUnread(_:)` queues a `.markUnread`
    /// `PendingOperation`, and the drain in `AccountManagerQueue.swift` — a
    /// FILE, `extension AccountManager`, not a type — calls
    /// `provider.markUnread`, through this same PATCH. It also named
    /// `updateMessage`, which is declared nowhere in the tree; the method is
    /// `patchMessage(id:body:)`. The coverage conclusion survives both; the
    /// count and the symbol did not.)
    /// A 503 is outside Graph's retryable set
    /// (`HTTPRetryPolicy.graph` retries 429 only), so it surfaces to the caller
    /// and the model must be unchanged.
    @Test("a transient Graph mutation failure leaves state unchanged and retries clean")
    func transientMutationFailureLeavesStateUnchanged() async throws {
        let providerMessageId = "graph-transient-1"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "exchange-transient@example.com",
            providerMessageId: providerMessageId,
            folderId: "source-folder"
        )])
        defer { server.close() }
        let provider = server.provider()

        server.failNextMutation()
        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [providerMessageId], folder: "source-folder")
        }
        let afterFailure = server.snapshot(providerMessageId: providerMessageId)
        #expect(afterFailure != nil)
        guard let afterFailure else { return }
        #expect(!afterFailure.isRead)

        try await provider.markRead(ids: [providerMessageId], folder: "source-folder")
        let afterRetry = server.snapshot(providerMessageId: providerMessageId)
        #expect(afterRetry != nil)
        guard let afterRetry else { return }
        #expect(afterRetry.isRead)
    }

    /// Port of the reference's `ordinaryFolderListings`. Dates are derived from
    /// `Date()` so nothing goes stale.
    ///
    /// The reference carried BOTH `failNextLookup()` legs: it armed the hook,
    /// ran a listing and asserted `== 0`, then ran an RFC-addressed ACTION and
    /// asserted `== 1`. Leg 1 ports verbatim and is restored below — a listing
    /// is demonstrably able to spend or not spend the action-lookup budget, and
    /// the Gmail counterpart
    /// (`ordinaryFolderListingsDecodeMembershipFieldsAndLimits`) does exactly
    /// this. Leg 2 is the half that does not transfer: no `v3` adapter method
    /// issues the RFC-identity `$filter`, so there is nothing for a ported leg
    /// 2 to drive.
    ///
    /// **That obligation is NOT discharged** (an earlier revision of this line
    /// claimed it was, contradicting the block above
    /// `armedLookupFailureIsConsumedByAnRfcFilterSearch`, which is the correct
    /// one). What that test supplies is a FIXTURE SELF-CHECK: it proves the
    /// hook, route and counter are alive, so the `== 0` assertions in this file
    /// are not measuring a counter nothing can ever increment. It drives a
    /// synthetic URL, not `ExchangeProvider`, and therefore says nothing about
    /// the adapter. The reference's adapter/system-level `== 1` remains
    /// OUTSTANDING, and no test in this file supplies it.
    @Test("ordinary Graph folder listings decode identity, fields, order, and paging")
    func ordinaryFolderListingsDecodeIdentityFieldsOrderAndPaging() async throws {
        let newest = Date()
        let older = newest.addingTimeInterval(-60)
        let server = StatefulExchangeActionServer(messages: [
            .init(
                rfc822MessageId: "exchange-list-older@example.com",
                providerMessageId: "graph-list-older",
                folderId: "source-folder",
                receivedAt: older
            ),
            .init(
                rfc822MessageId: "exchange-list-newer@example.com",
                providerMessageId: "graph-list-newer",
                folderId: "source-folder",
                isRead: true,
                isFlagged: true,
                receivedAt: newest
            ),
            .init(
                rfc822MessageId: "exchange-list-other@example.com",
                providerMessageId: "graph-list-other",
                folderId: "other-folder",
                receivedAt: newest
            ),
        ])
        defer { server.close() }
        let provider = server.provider()

        // Reference leg 1: an ordinary listing must not spend the action-lookup
        // budget. Armed, so the `== 0` below can actually fail.
        server.failNextLookup()

        let first = try await provider.fetchMessages(
            folder: "source-folder", limit: 1, offset: 0
        )
        #expect(
            server.consumedLookupFailureCount() == 0,
            "an ordinary folder listing must not consume the action-lookup budget — it issues no RFC-identity $filter search"
        )
        #expect(first.count == 1)
        guard first.count == 1 else { return }
        #expect(first[0].messageId == "graph-list-newer")
        #expect(first[0].rfc822MessageId == "exchange-list-newer@example.com")
        #expect(first[0].isRead)
        #expect(first[0].isFlagged)

        let second = try await provider.fetchMessages(
            folder: "source-folder", limit: 1, offset: 1
        )
        #expect(second.count == 1)
        guard second.count == 1 else { return }
        #expect(second[0].messageId == "graph-list-older")
        #expect(!second[0].isRead)
        #expect(!second[0].isFlagged)

        // A folder listing is scoped — the other folder's resource never leaks.
        let other = try await provider.fetchMessages(
            folder: "other-folder", limit: 10, offset: 0
        )
        #expect(other.count == 1)
        guard other.count == 1 else { return }
        #expect(other[0].messageId == "graph-list-other")
    }

    // MARK: - Injected-session escape detector

    // ⚑ NO REFERENCE — INVENTED. Scope marker for the section below: the test
    // that follows (`deleteDraftRetriesOnTheInjectedSessionAfter401`) has NO
    // counterpart in `v2final`. Verified: the reference's
    // `StatefulExchangeActionServerTests` declares exactly four tests
    // (`opaqueDraftResourceLifecycle`, `actionFinalState`,
    // `staleAmbiguousAndTransient`, `ordinaryFolderListings`) and none of them
    // is a session-escape detector. The reference had no need for one — it
    // passed `session: testSession` at both `deleteDraft` call sites already;
    // this exists because `v3` had dropped them. The
    // `FakeHTTP.ResponseScript` and `servedCallSequence()` it is built on are
    // likewise invented (see their own markers).

    /// **`ExchangeProvider.deleteDraft` must not escape its injected
    /// `URLSession` — on EITHER of its two request lines.**
    ///
    /// `deleteDraft` is the one method that bypasses the file's private
    /// `request()` helper, calling the free `performHTTPRequestWithRetry` /
    /// `performHTTPRequest` directly, and `performHTTPRequest` itself resolves
    /// `session ?? sharedEphemeralSession`, so a missing `session:` is not an
    /// error — it silently sends the request to `https://graph.microsoft.com`.
    /// (The owner is that free function, not a type: nothing named
    /// `HTTPClient` is declared anywhere in the tree —
    /// `Shared/HTTP/HTTPClient.swift` is a FILE that declares `HTTPConfig`,
    /// `HTTPRequestResult` and `HTTPError`, the global `let sharedEphemeralSession`,
    /// and TWO free functions: `performHTTPRequest` and
    /// `performHTTPRequestWithRetry`. ⚠ CORRECTED 2026-07-31 from "plus three free
    /// functions" — six top-level declarations, but only two of them are functions.
    /// The miscounted third was `sharedEphemeralSession`, a global CONSTANT bound to
    /// an immediately-invoked closure, and it is precisely the symbol the sentence
    /// above depends on.)
    /// That is not hypothetical: it is what this suite did before the
    /// restoration, and it failed with a real `Error Domain=Exchange Code=401`
    /// from Microsoft.
    ///
    /// The script answers the first DELETE with 401 and the retry with 204, so
    /// BOTH lines must reach the fake for `deleteDraft` to return:
    ///
    /// * first DELETE escapes → Microsoft's own 401 comes back → the retry runs
    ///   and takes the script's FIRST entry (401) → neither 404 nor a body →
    ///   `deleteDraft` throws;
    /// * retry escapes → the live 401 comes back → same throw.
    ///
    /// Either way `served` is `[401]` instead of `[401, 204]` and the call
    /// sequence loses an entry. (Offline, the escaping request fails at the
    /// transport instead, which throws just the same.) 401 is not in Graph's
    /// `retryableStatusCodes` ([429]), so the transport does not retry it — the
    /// second DELETE is the adapter's own token-refresh leg and nothing else.
    ///
    /// The registration uses the full `"/messages/{id}"` prefix so it wins the
    /// longest-matching-prefix rule against the fixture's own `/messages/`
    /// DELETE route, which would otherwise answer 204 on the first call and
    /// collapse the 401 leg entirely.
    @Test("ExchangeProvider.deleteDraft's initial DELETE and its 401 retry both route through the injected session")
    func deleteDraftRetriesOnTheInjectedSessionAfter401() async throws {
        let providerMessageId = "graph-session-escape-1"
        let server = StatefulExchangeActionServer(messages: [.init(
            rfc822MessageId: "exchange-session-escape@example.com",
            providerMessageId: providerMessageId,
            folderId: "Drafts"
        )])
        defer { server.close() }
        let provider = server.provider()

        let draftDelete = FakeHTTP.ResponseScript([401, 204])
        server.http.register(path: "/messages/\(providerMessageId)", method: "DELETE") { _ in
            .status(draftDelete.next())
        }

        try await provider.deleteDraft(draftId: providerMessageId, draftsFolderPath: "Drafts")

        #expect(
            draftDelete.served == [401, 204],
            "both canned responses must have been served — a missing one means that DELETE escaped to the live Graph endpoint: \(draftDelete.served)"
        )
        #expect(
            server.http.servedCallSequence() == [
                "DELETE /v1.0/me/messages/\(providerMessageId)",
                "DELETE /v1.0/me/messages/\(providerMessageId)",
            ],
            "unexpected served sequence: \(server.http.servedCallSequence())"
        )
    }
}
