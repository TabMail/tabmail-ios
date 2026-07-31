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
/// **`failNextLookup()` is unreachable on `v3`.** The fixture only consumes it
/// on a request carrying `$filter`, and no `v3` code path sends one —
/// `fetchMessages` uses `$select`/`$top`/`$skip`/`$orderby` only. The
/// reference's lookup-failure legs are therefore replaced by
/// `failNextMutation()` coverage, which IS reachable (it gates PATCH/POST/
/// DELETE), plus the duplicate-RFC proof below.
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
    /// **Gap 2 — `deleteDraft` escapes the injected session.** Every other
    /// Exchange path goes through `authedHTTP`, which is built with
    /// `session: testSession`. `v3`'s `deleteDraft` instead calls the free
    /// `performHTTPRequestWithRetry` / `performHTTPRequest` WITHOUT
    /// `session: testSession`, so it falls back to `sharedEphemeralSession` and
    /// issues a LIVE request to `https://graph.microsoft.com`. `v2final` passes
    /// `session: testSession` at both call sites. The DELETE leg is therefore
    /// omitted — including it made this test fail with a real
    /// `Error Domain=Exchange Code=401` from Microsoft.
    ///
    /// Signature adaptation: `v3`'s `saveDraft` has no
    /// `previousRfc822MessageId:` parameter (`v2final`-only).
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

        // Never consumed: no v3 Graph path issues a `$filter` RFC search.
        #expect(
            server.consumedLookupFailureCount() == 0,
            "no v3 Graph action path may resolve a target via an RFC $filter search"
        )
    }

    /// Port of the reference's transient-failure leg, keeping only the half
    /// `v3` can reach. `failNextLookup()` gates a `$filter` request that no
    /// `v3` path sends; `failNextMutation()` gates PATCH/POST/DELETE, which
    /// every action uses. A 503 is outside Graph's retryable set
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

    /// Port of the reference's `ordinaryFolderListings`, minus the two
    /// `failNextLookup()` legs (unreachable on `v3`, see the suite note).
    /// Dates are derived from `Date()` so nothing goes stale.
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

        let first = try await provider.fetchMessages(
            folder: "source-folder", limit: 1, offset: 0
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
}
