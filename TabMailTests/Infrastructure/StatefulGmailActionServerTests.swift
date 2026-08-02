/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// v3 port of `v2final:TabMailTests/Infrastructure/StatefulGmailActionServerTests.swift`.
///
/// **The conversion (D4).** The reference addresses every action by RFC 822
/// Message-ID — `provider.markRead(ids: [rfc822MessageId], …)` — because
/// `v2final`'s `GmailProvider` carried a resolution layer
/// (`resolveActionMessageIds` / `resolveActionMessageId` / `resolveTokenMember`)
/// that turned an RFC identity into a Gmail resource id via an
/// `rfc822msgid:` search. **`v3` has no such layer**: `markRead`/`markFlagged`/
/// `move` pass `ids` straight to `modifyMessage(id:)` →
/// `POST /messages/{id}/modify`, so `ids` ARE Gmail's native `message.id`.
/// Every assertion the reference made through `snapshots(rfc822MessageId:)` is
/// therefore read here through `snapshot(providerMessageId:)`, the v3-only
/// accessor that had zero callers before this suite.
///
/// **The observation-only claim.** Both servers document their RFC map as
/// observation-only — it must never pick a mutation target. `duplicateRfc…`
/// and `staleProviderId…` below are the direct proof: two distinct resources
/// share one RFC, and addressing one by provider id must move only that one.
/// `failNextLookup()` arms a failure that ONLY an `rfc822msgid:` search can
/// consume, so `consumedLookupFailureCount() == 0` after a full action
/// sequence is a wire-level proof that **no `GmailProvider` ACTION method**
/// resolves its target by RFC. That is all FOUR of them, counted:
/// `markRead`, `markUnread`, `markFlagged`, `move` — plus `deleteDraft` (a
/// draft operation, not an action) and the folder listings the action paths
/// depend on. (An earlier revision listed a `delete` method here.
/// `GmailProvider` has none; its only delete-shaped method is `deleteDraft`.)
/// The word ACTION is load-bearing and not a hedge: `GmailProvider.search`
/// DOES emit an `rfc822msgid:` query when a caller hands it one — that is
/// exactly what drives the positive control below — but `search` resolves no
/// action, it returns results to a caller, so it is not a counter-example to
/// the claim.
///
/// FOUR assertion sites in this file read `consumedLookupFailureCount() == 0`.
/// Three of them — in `duplicateRfcMutatesOnlyTheAddressedResource`,
/// `staleProviderIdNeverFallsBackToItsRfcSibling`, and
/// `ordinaryFolderListingsDecodeMembershipFieldsAndLimits` — call
/// `failNextLookup()` FIRST, so each one can actually fail; an unarmed `== 0`
/// cannot fail and proves nothing. The fourth is the deliberately UNARMED
/// baseline inside `armedLookupFailureIsConsumedByAnRfcSearch`, whose
/// `failNextLookup()` call comes immediately below it: its job is to show the
/// counter reads zero BEFORE the arming, so the `== 1` that follows is
/// attributable to the search alone.
/// That same test is the POSITIVE CONTROL that the oracle actually fires.
///
/// **⚠ ADAPTER BOUNDARY, NOT SYSTEM BOUNDARY.** The scope of that proof is
/// `GmailProvider`, the layer at which `ids` are already Gmail resource ids. It
/// is NOT a system property. `AccountManager.markRead`/`markUnread` call
/// `expandWithSiblingsByRfc822` BEFORE anything is queued, and that helper
/// selects every `messageHeader` row sharing the RFC 822 Message-ID for the
/// account — no folder filter, no provider-id qualification — then queues each
/// sibling's native id. So at the SYSTEM boundary a duplicate-RFC gesture still
/// fans out to both copies, and this suite says nothing about that. Tracked as
/// **D-26** in `PLAN_IOS_REFACTOR_V3.md`; the system-boundary proof is still
/// OWED and must be written red-first against `AccountManager`, never lowered
/// to this boundary to make it pass. `v2final` has the identical helper with
/// identical SQL, so narrowing it is a production behaviour change that needs
/// its own tier — it must not be smuggled into a test fix.
///
/// **No `.processGlobalState`.** `v2final` leaves both Stateful*ActionServer
/// suites unannotated, and neither swaps `AppDatabase.shared` nor mutates
/// `AccountManager.shared` — each test owns a private `FakeHTTP.Scenario`.
@Suite("Stateful Gmail action transport (provider-id)")
struct StatefulGmailActionServerTests {
    /// Port of the reference's `actionFinalState`, addressed by provider id.
    ///
    /// Dropped vs the reference: the `setUserLabel(ids:labelId:present:folder:)`
    /// leg. That method exists only on `v2final`'s `GmailProvider`; `v3` has no
    /// Gmail user-label write API at all (`git grep "func setUserLabel"` matches
    /// only `IMAPProvider`). Label mutation is still covered — `move` is
    /// implemented as an add/remove label pair, which is the same
    /// `/messages/{id}/modify` vocabulary.
    @Test("Gmail adapter mutates final move, read, and flag state by provider id")
    func actionFinalStateAddressedByProviderId() async throws {
        let rfc822MessageId = "gmail-stateful@example.com"
        let providerMessageId = "gmail-resource-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: providerMessageId,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        let provider = server.provider()

        try await provider.markRead(ids: [providerMessageId], folder: "INBOX")
        try await provider.markFlagged(
            ids: [providerMessageId], flagged: true, folder: "INBOX"
        )
        try await provider.move(
            ids: [providerMessageId], from: "INBOX", to: GmailProvider.archivePath
        )

        let archived = server.snapshot(providerMessageId: providerMessageId)
        #expect(archived != nil)
        guard let archived else { return }
        #expect(archived.providerMessageId == providerMessageId)
        #expect(archived.isRead)
        #expect(archived.isFlagged)
        #expect(!archived.labels.contains("INBOX"))

        let archivedHeaders = try await provider.fetchMessages(
            folder: GmailProvider.archivePath,
            limit: 10,
            offset: 0
        )
        #expect(archivedHeaders.count == 1)
        guard archivedHeaders.count == 1 else { return }
        #expect(archivedHeaders[0].messageId == providerMessageId)
        #expect(archivedHeaders[0].rfc822MessageId == rfc822MessageId)
        #expect(archivedHeaders[0].isRead)
        #expect(archivedHeaders[0].isFlagged)

        // Gmail — unlike Graph — never reallocates the resource id on a label
        // move, so the op's recorded handle stays addressable across the
        // inverse move. That asymmetry is why C3-X2 is a Graph-only case.
        try await provider.move(
            ids: [providerMessageId], from: GmailProvider.archivePath, to: "INBOX"
        )
        let restored = server.snapshot(providerMessageId: providerMessageId)
        #expect(restored != nil)
        guard let restored else { return }
        #expect(restored.labels.contains("INBOX"))
        #expect(restored.isRead)
        #expect(restored.isFlagged)

        let inboxHeaders = try await provider.fetchMessages(
            folder: "INBOX", limit: 10, offset: 0
        )
        #expect(inboxHeaders.count == 1)
        guard inboxHeaders.count == 1 else { return }
        #expect(inboxHeaders[0].messageId == providerMessageId)
    }

    /// Outcome-level port of the reference's
    /// `undoArchiveResolvesSentLabeledSelfSentMessage`.
    ///
    /// **The reference's defect class does not exist on `v3`.** That test pinned
    /// a bug in `v2final`'s ACTION-scope archive membership query, which
    /// excluded `SENT` and so resolved zero candidates for a self-sent message —
    /// undo-of-archive silently no-opped. `v3` issues no membership query at
    /// all: `move` addresses the resource directly. What survives is the
    /// user-visible outcome — the inverse move restores INBOX without
    /// disturbing SENT — which still guards `move`'s add/remove derivation for
    /// the `archivePath` source (`remove` must stay empty).
    @Test("undo-of-archive restores a SENT-labeled self-sent message to INBOX")
    func archiveRestoreOfSentLabeledMessage() async throws {
        let providerMessageId = "gmail-self-sent-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-self-sent@example.com",
            providerMessageId: providerMessageId,
            labels: ["SENT"]
        )])
        defer { server.close() }
        let provider = server.provider()

        try await provider.move(
            ids: [providerMessageId], from: GmailProvider.archivePath, to: "INBOX"
        )

        let restored = server.snapshot(providerMessageId: providerMessageId)
        #expect(restored != nil)
        guard let restored else { return }
        #expect(
            restored.labels.contains("INBOX"),
            "undo-of-archive must restore a SENT-labeled self-sent message to INBOX"
        )
        #expect(
            restored.labels.contains("SENT"),
            "restoring to INBOX must not strip the SENT label"
        )
    }

    /// §6.5 headline red proof #2, Gmail half — and the direct verification
    /// that the server's "RFC map is observation-only" doc comment is TRUE.
    ///
    /// Replaces the reference's duplicate-RFC leg, which asserted the OPPOSITE
    /// outcome for the opposite reason: on `v2final` an ambiguous RFC resolved
    /// to two candidates and the resolver refused, so NEITHER copy moved. On
    /// `v3` there is nothing to be ambiguous about — the op names one resource,
    /// and exactly that resource must move.
    @Test("a duplicate RFC identity mutates only the addressed Gmail resource")
    func duplicateRfcMutatesOnlyTheAddressedResource() async throws {
        let sharedRFC = "gmail-duplicate@example.com"
        let addressed = "gmail-duplicate-1"
        let sibling = "gmail-duplicate-2"
        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: sharedRFC, providerMessageId: addressed, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: sharedRFC, providerMessageId: sibling, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        let provider = server.provider()

        // Observation only: the fixture really does hold two distinct resources
        // under one RFC. This is the ONLY place the RFC map is read.
        let before = server.snapshots(rfc822MessageId: sharedRFC)
        #expect(before.count == 2)
        guard before.count == 2 else { return }
        #expect(before.allSatisfy { !$0.isRead && !$0.isFlagged })

        // Arm a failure that only an `rfc822msgid:` search can consume.
        server.failNextLookup()

        try await provider.markRead(ids: [addressed], folder: "INBOX")
        try await provider.markFlagged(ids: [addressed], flagged: true, folder: "INBOX")
        try await provider.move(
            ids: [addressed], from: "INBOX", to: GmailProvider.archivePath
        )

        let target = server.snapshot(providerMessageId: addressed)
        #expect(target != nil)
        guard let target else { return }
        #expect(target.isRead)
        #expect(target.isFlagged)
        #expect(!target.labels.contains("INBOX"))

        // The RFC twin must be byte-identical to its seed.
        let untouched = server.snapshot(providerMessageId: sibling)
        #expect(untouched != nil)
        guard let untouched else { return }
        #expect(untouched == StatefulGmailActionServer.Snapshot(
            providerMessageId: sibling,
            labels: ["INBOX", "UNREAD"]
        ))

        // Wire-level oracle: every modify attempt named the addressed resource
        // and nothing else — the RFC map was never used to pick a target.
        let modifiedIds = Set(server.modifyLog().map(\.providerMessageId))
        #expect(modifiedIds == [addressed])

        // No v3 Gmail path resolves an action by RFC search, so the armed
        // lookup failure is still unconsumed.
        #expect(
            server.consumedLookupFailureCount() == 0,
            "no v3 Gmail action path may resolve a target via rfc822msgid: search"
        )
    }

    /// Replaces the reference's "missing RFC identity no-ops" leg.
    ///
    /// On `v2final` a missing RFC resolved to zero candidates and the adapter
    /// returned silently. `v3` has no resolution step, so a gone/never-valid
    /// provider id reaches `POST /messages/{id}/modify` and Gmail's 404 surfaces
    /// as a thrown `ProviderError` — classification of that throw belongs to the
    /// durable queue, not the transport. What this pins is the safety property
    /// that survives the keying change: a provider id that names nothing must
    /// NOT fall back to the RFC map and land on a live sibling.
    @Test("a stale Gmail provider id never falls back to its RFC sibling")
    func staleProviderIdNeverFallsBackToItsRfcSibling() async throws {
        let sharedRFC = "gmail-stale@example.com"
        let live = "gmail-live-1"
        let gone = "gmail-gone-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: sharedRFC,
            providerMessageId: live,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        let provider = server.provider()

        server.failNextLookup()

        await #expect(throws: ProviderError.self) {
            try await provider.markRead(ids: [gone], folder: "INBOX")
        }

        #expect(server.snapshot(providerMessageId: gone) == nil)

        let survivor = server.snapshot(providerMessageId: live)
        #expect(survivor != nil)
        guard let survivor else { return }
        #expect(survivor == StatefulGmailActionServer.Snapshot(
            providerMessageId: live,
            labels: ["INBOX", "UNREAD"]
        ))

        // `allSatisfy` over an EMPTY collection is vacuously TRUE, so the
        // non-emptiness assertion below is load-bearing rather than decorative:
        // an adapter that issued no modify at all — or one that threw before
        // reaching the wire — would satisfy the `allSatisfy` while proving
        // nothing about which resource a stale provider id addresses. The
        // fixture appends to `modifyLog` on ENTRY to the `/messages/{id}/modify`
        // route, before the 404 is decided, so the attempt on a gone id is
        // genuinely recorded and the non-emptiness assertion is satisfiable.
        let modifyAttempts = server.modifyLog()
        #expect(
            !modifyAttempts.isEmpty,
            "the adapter issued no modify at all — this leg constrains nothing about where a stale provider id lands"
        )
        #expect(
            modifyAttempts.allSatisfy { $0.providerMessageId == gone },
            "a modify named a resource other than the stale id: \(modifyAttempts.map(\.providerMessageId))"
        )
        #expect(
            server.consumedLookupFailureCount() == 0,
            "a stale provider id must not trigger an rfc822msgid: fallback search"
        )
    }

    /// Port of the reference's `ordinaryFolderListings`.
    ///
    /// The reference armed `failNextLookup()`, asserted a listing did NOT
    /// consume it (`== 0`), then ran an RFC-addressed ACTION and asserted it DID
    /// (`== 1`). The first half ports verbatim and is restored below. The second
    /// half is unreachable from any adapter method on `v3` — no code path issues
    /// an `rfc822msgid:` search — so the oracle's `== 1` obligation is
    /// discharged by `armedLookupFailureIsConsumedByAnRfcSearch`, which drives
    /// the same route directly. Both halves exist; only the driver changed.
    @Test("ordinary Gmail folder listings decode membership, fields, and limits")
    func ordinaryFolderListingsDecodeMembershipFieldsAndLimits() async throws {
        let inboxRFC = "gmail-list-inbox@example.com"
        let archiveRFC = "gmail-list-archive@example.com"
        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: inboxRFC, providerMessageId: "gmail-list-1", labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: "gmail-list-second@example.com", providerMessageId: "gmail-list-2", labels: ["INBOX"]),
            .init(rfc822MessageId: archiveRFC, providerMessageId: "gmail-list-3", labels: ["STARRED"]),
            .init(rfc822MessageId: "gmail-list-sent@example.com", providerMessageId: "gmail-list-4", labels: ["SENT"]),
        ])
        defer { server.close() }
        let provider = server.provider()

        // Reference leg 1: an ordinary listing must not spend the action-lookup
        // budget. Armed, so the `== 0` below can actually fail.
        server.failNextLookup()

        let inbox = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        #expect(
            server.consumedLookupFailureCount() == 0,
            "an ordinary folder listing must not consume the action-lookup budget — it issues no rfc822msgid: search"
        )
        #expect(inbox.count == 1)
        guard inbox.count == 1 else { return }
        #expect(inbox[0].messageId == "gmail-list-1")
        #expect(inbox[0].rfc822MessageId == inboxRFC)
        #expect(!inbox[0].isRead)
        #expect(!inbox[0].isFlagged)

        // The synthetic All Mail scope excludes inbox/sent/trash/spam/draft, so
        // only the STARRED-only resource lists — the SENT-only one must not.
        let archive = try await provider.fetchMessages(
            folder: GmailProvider.archivePath, limit: 10, offset: 0
        )
        #expect(archive.count == 1)
        guard archive.count == 1 else { return }
        #expect(archive[0].messageId == "gmail-list-3")
        #expect(archive[0].rfc822MessageId == archiveRFC)
        #expect(archive[0].isRead)
        #expect(archive[0].isFlagged)
    }

    /// Adapted stand-in for the reference's three user-label tests
    /// (`userLabelCatalogAuthority`, `createdUserLabelIsImmediatelyKnown`,
    /// `overlappingUserLabelCatalogsKeepNewestKnowledge`).
    ///
    /// **Those three cannot port.** All of them assert on
    /// `GmailUserLabelCatalogState` and `MessageHeaderInfo.userLabelIdsAreAuthoritative`,
    /// neither of which exists anywhere on `v3` (`git grep` returns nothing in
    /// `TabMail/`); the request-generation catalog is a `v2final` production
    /// feature landed after `v1.6.38`. Without it there is no "authoritative"
    /// bit to observe. The reference's assertion
    /// `findLabelIdByName("tm_legacy") == nil` also inverts on `v3`, whose
    /// `findLabelIdByName` is a plain case-insensitive name match with no
    /// legacy filter.
    ///
    /// What DOES port is the half of the `/labels` surface `v3` implements:
    /// catalog discovery classifying user vs legacy `tm_*` labels
    /// (ADR-IOS-036 decay), and label creation. The decay leg additionally
    /// proves the catalog feeds `move()`'s inbox-exit strip — otherwise the
    /// server's `userLabels` / `createdLabelId` seeds have no coverage at all.
    @Test("Gmail label catalog classifies legacy labels and feeds inbox-exit decay")
    func legacyTmLabelDecayUsesTheLabelCatalog() async throws {
        let userLabelId = "Label_42"
        let legacyLabelId = "Label_99"
        let createdLabelId = "Label_43"
        let providerMessageId = "gmail-label-1"
        let server = StatefulGmailActionServer(
            messages: [.init(
                rfc822MessageId: "gmail-label@example.com",
                providerMessageId: providerMessageId,
                labels: ["INBOX", userLabelId, legacyLabelId]
            )],
            userLabels: [
                userLabelId: "Project",
                legacyLabelId: "tm_legacy",
            ],
            createdLabelId: createdLabelId
        )
        defer { server.close() }
        let provider = server.provider()

        let folders = try await provider.fetchFolders()
        #expect(folders.contains { $0.path == userLabelId && $0.name == "Project" })
        #expect(
            !folders.contains { $0.path == legacyLabelId },
            "legacy tm_* labels are hidden from the folder list (ADR-IOS-036)"
        )
        #expect(try await provider.findLabelIdByName("Project") == userLabelId)
        #expect(try await provider.createLabel(name: "Created") == createdLabelId)

        // Inbox exit strips the recorded legacy label in the SAME modify call.
        try await provider.move(
            ids: [providerMessageId], from: "INBOX", to: GmailProvider.archivePath
        )

        let decayed = server.snapshot(providerMessageId: providerMessageId)
        #expect(decayed != nil)
        guard let decayed else { return }
        #expect(!decayed.labels.contains("INBOX"))
        #expect(!decayed.labels.contains(legacyLabelId))
        #expect(
            decayed.labels.contains(userLabelId),
            "a genuine user label must survive inbox exit"
        )

        let log = server.modifyLog()
        #expect(log.count == 1)
        guard log.count == 1 else { return }
        #expect(log[0].providerMessageId == providerMessageId)
        #expect(Set(log[0].removeLabelIds) == ["INBOX", legacyLabelId])
    }

    /// **The positive control for `consumedLookupFailureCount()`** — `v2final`'s
    /// `== 1` half, restored (RULE R0), and driven by a REAL production path.
    ///
    /// FOUR textual assertions in this file read
    /// `consumedLookupFailureCount() == 0`. Three of them —
    /// `duplicateRfcMutatesOnlyTheAddressedResource`,
    /// `staleProviderIdNeverFallsBackToItsRfcSibling`, and
    /// `ordinaryFolderListingsDecodeMembershipFieldsAndLimits` — are ARMED with
    /// `failNextLookup()` first. The fourth is this test's own baseline below,
    /// which is deliberately UNARMED because its job is the opposite one:
    /// asserting the counter starts at zero, so the `== 1` further down cannot
    /// be a leftover from fixture construction.
    ///
    /// Arming those three is still not enough on its own: if the fixture's
    /// `/messages` route stopped matching, or `rfcIdentity(fromSearchQuery:)`
    /// stopped parsing `rfc822msgid:`, or the counter stopped being written,
    /// every one of those zeros would stay green while proving nothing at all.
    /// A `== 0` oracle with no `== 1` anywhere in the suite is a claim about a
    /// counter, not about the adapter.
    ///
    /// **The property this pins.** `GmailProvider.search(query:folder:…)`
    /// preserves its caller's query as the BASE of the Gmail `q=` parameter —
    /// not verbatim: it APPENDS `from:`/`to:`/`after:`/`before:` terms for any
    /// non-nil argument and, ON the archive path (i.e. when
    /// `folder == GmailProvider.archivePath`), `allMailExclusionQuery`,
    /// then percent-encodes the whole thing.
    /// (⚠ CORRECTED 2026-07-31: this read "off the archive path", the exact
    /// opposite of `if folder == GmailProvider.archivePath { q += " " + GmailProvider.allMailExclusionQuery }`.
    /// The synthetic All Mail path is not a real Gmail label ID, so it is expressed
    /// as query exclusions INSTEAD OF `labelIds` — which is why the two clauses have
    /// OPPOSITE polarity and why the identical phrase appearing twice in this file
    /// was so easy to get backwards. Both occurrences are now spelled out rather
    /// than sharing the ambiguous phrase.) What matters for this control is
    /// that the caller's own terms survive into `q`, which they do; the fixture
    /// keys only on an `rfc822msgid:` term being present. The method is reached
    /// in production from `AccountManager.search(query:account:folder:after:before:from:to:)`
    /// (declared in the file `AccountManagerActions.swift`, which is an
    /// `extension AccountManager` — there is no `AccountManagerActions` type,
    /// and an earlier revision cited one) and from `SearchView`. So
    /// `search(query: "rfc822msgid:…")` is a genuine
    /// production driver for this route — the earlier claim that "v3 has no
    /// production path that can produce this control" was wrong. It rested on
    /// `git grep rfc822msgid` finding no LITERAL under `TabMail/`, which proves
    /// only that no v3 code HARDCODES the term, not that no v3 code can send
    /// it.
    ///
    /// **What stays true, and is what the `== 0` oracles defend.** No v3 Gmail
    /// ACTION path resolves a target by RFC: `markRead`/`markFlagged`/`move`
    /// pass `ids` straight to `modifyMessage(id:)`. That narrow claim is the
    /// one the armed zeros above assert, and this control does not weaken it —
    /// it drives the search surface, which is a different method entirely.
    ///
    /// Note the request shapes differ and neither is "the reference's exact
    /// shape". `v2final:TabMail/Providers/GmailProvider.swift`'s
    /// `resolveActionMessageId` sent `q` + `maxResults=2` +
    /// `includeSpamTrash=true` (+ `labelIds=<folder>` when the folder is NOT the
    /// archive path); v3's `search` sends `q` + `maxResults=20` (+
    /// `labelIds=<folder>` when the folder is neither empty nor the archive path —
    /// the guard is `(folder.isEmpty || folder == GmailProvider.archivePath) ? "" : …`,
    /// so an empty folder suppresses it too). Note this is the OPPOSITE polarity to
    /// the `allMailExclusionQuery` clause above, which is appended ON the archive
    /// path — see the correction there. What the fixture's hook keys on — and all it keys on — is
    /// an `rfc822msgid:` term inside `q`, which both shapes carry.
    @Test("the armed lookup failure IS consumed by an rfc822msgid: search — the oracle fires")
    func armedLookupFailureIsConsumedByAnRfcSearch() async throws {
        let rfc822MessageId = "gmail-positive-control@example.com"
        let providerMessageId = "gmail-positive-control-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: rfc822MessageId,
            providerMessageId: providerMessageId,
            labels: ["INBOX", "UNREAD"]
        )])
        defer { server.close() }
        let provider = server.provider()

        // Baseline: nothing about fixture construction pre-loads the counter.
        #expect(server.consumedLookupFailureCount() == 0)

        server.failNextLookup()

        // The armed credit surfaces as the fixture's 503. 503 is outside Gmail's
        // retryable set (`HTTPRetryPolicy.gmail` retries 429/403 only), so it is
        // not silently retried into a success: `AuthedHTTP` throws
        // `HTTPError.networkError(503)` and `GmailProvider.request` rewraps it.
        // The throw shows only that the request was NOT served 2xx — it does
        // NOT show the armed route was hit, because an UNMATCHED request throws
        // identically (FakeHTTP answers 599 → `HTTPError.networkError` → the
        // same rewrap). The load-bearing evidence is the assertion immediately
        // below: `consumedLookupFailureCount()` can only be incremented inside
        // the armed branch, so `== 1` is what distinguishes "matched the
        // `rfc822msgid:` route" from "was not served".
        await #expect(throws: ProviderError.self) {
            _ = try await provider.search(
                query: "rfc822msgid:\(rfc822MessageId)", folder: "INBOX"
            )
        }
        #expect(
            server.consumedLookupFailureCount() == 1,
            "an rfc822msgid: search MUST consume the armed lookup failure — if it does not, every `== 0` assertion in this suite is vacuous"
        )

        // Single-shot: the credit measures armed consumption, not traffic. The
        // identical search now succeeds and resolves the seeded resource, which
        // also proves the 503 above came from the ARMED credit and not from a
        // route that simply cannot serve this query.
        let hits = try await provider.search(
            query: "rfc822msgid:\(rfc822MessageId)", folder: "INBOX"
        )
        #expect(hits.count == 1)
        guard hits.count == 1 else { return }
        #expect(hits[0].messageId == providerMessageId)
        #expect(hits[0].rfc822MessageId == rfc822MessageId)
        #expect(server.consumedLookupFailureCount() == 1)
    }

    // MARK: - Injected-session escape detectors

    // ⚑ NO REFERENCE — INVENTED. Scope marker for the whole section below: the
    // THREE tests that follow (`deleteDraftAndFetchHistoryUseTheInjectedSession`,
    // `deleteDraftRetriesTheDraftDeleteOnTheInjectedSessionAfter401`,
    // `deleteDraftContainedMessageAndItsRetryUseTheInjectedSession`) have NO
    // counterpart in `v2final`. Verified: the reference's
    // `StatefulGmailActionServerTests` declares exactly seven tests
    // (`userLabelCatalogAuthority`, `createdUserLabelIsImmediatelyKnown`,
    // `overlappingUserLabelCatalogsKeepNewestKnowledge`, `actionFinalState`,
    // `undoArchiveResolvesSentLabeledSelfSentMessage`, `staleAmbiguousAndTransient`,
    // `ordinaryFolderListings`) and none of them is a session-escape detector.
    // The reference's exact `trashContainedDraftMessage` passes `session:` on
    // both requests; its old resource-404 fallback did not, but that namespace
    // reinterpretation is SUBTRACTED here. These tests exist because `v3` also
    // dropped session injection from reachable request legs, and keep that
    // regression from returning silently. The `FakeHTTP.ResponseScript` they
    // are built on is likewise invented (see its own marker).

    /// **`GmailProvider` must not escape its injected `URLSession`.**
    ///
    /// `performHTTPRequest` resolves `session ?? sharedEphemeralSession`, so a
    /// missing `session:` is not an error — it silently sends the request to
    /// the LIVE internet. (The owner is the free function, not a type: nothing
    /// named `HTTPClient` is declared anywhere in the tree —
    /// `Shared/HTTP/HTTPClient.swift` is a FILE that declares `HTTPConfig`,
    /// `HTTPRequestResult` and `HTTPError`, the global `let sharedEphemeralSession`,
    /// and TWO free functions: `performHTTPRequest` and
    /// `performHTTPRequestWithRetry`. ⚠ CORRECTED 2026-07-31 from "plus three free
    /// functions" — six top-level declarations, but only two of them are functions.
    /// The miscounted third was `sharedEphemeralSession`, a global CONSTANT bound to
    /// an immediately-invoked closure, and it is precisely the symbol the sentence
    /// above depends on.) `v3` had dropped `session: testSession` from `deleteDraft` and
    /// `fetchHistory`, so both issued real HTTPS requests to
    /// `gmail.googleapis.com` from the unit suite: nondeterministic, slow, and
    /// a data leak from a public repo's test run. The sibling
    /// `ExchangeProvider.deleteDraft` regression is what made this visible (a
    /// real `Code=401` from Microsoft during the port).
    ///
    /// **What THIS case pins, precisely.** `deleteDraft`'s happy path — the
    /// first `/drafts/{id}` DELETE returning 2xx and returning immediately —
    /// plus `fetchHistory`'s `AuthedHTTP` construction. It does NOT pin
    /// `deleteDraft`'s other three request sites, and it structurally cannot:
    /// a 204 here returns before the resource 401 retry or contained-message path is
    /// reached. Worse, this shape cannot even pin the FIRST DELETE on its own —
    /// if that line alone escaped, the live 401 would send control into the
    /// 401-retry, whose request hits the fake with the same method and path and
    /// leaves an identical recorded sequence.
    ///
    /// So the escape detectors are split by control-flow leg, and each leg is
    /// driven by a deterministic response script that makes the leg's own
    /// request observable:
    /// `deleteDraftRetriesTheDraftDeleteOnTheInjectedSessionAfter401` pins the
    /// initial DELETE and its 401 retry;
    /// `deleteDraftContainedMessageAndItsRetryUseTheInjectedSession` pins the
    /// contained-message POST and its 401 retry. Between the three tests all five
    /// changed Gmail lines have a leg that goes red when that one line loses
    /// its `session:`.
    @Test("GmailProvider.deleteDraft's 2xx path and .fetchHistory route through the injected session")
    func deleteDraftAndFetchHistoryUseTheInjectedSession() async throws {
        let providerMessageId = "gmail-session-escape-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-session-escape@example.com",
            providerMessageId: providerMessageId,
            labels: ["DRAFT"]
        )])
        defer { server.close() }
        let provider = server.provider()

        let draftDelete = FakeHTTP.ResponseScript([204])
        server.http.register(path: "/drafts/\(providerMessageId)", method: "DELETE") { _ in
            .status(draftDelete.next())
        }
        server.http.register(
            path: "/history",
            method: "GET",
            response: .json(raw: #"{"historyId":"424242","history":[{"messagesAdded":[{"message":{"id":"gmail-history-added-1","labelIds":["INBOX"]}}]}]}"#)
        )

        try await provider.deleteDraft(identity: .gmail(resourceId: providerMessageId))

        let history = try await provider.fetchHistory(since: "424241")
        #expect(history != nil, "fetchHistory returned nil — the canned delta never arrived, so the request did not reach the fake")
        guard let history else { return }
        #expect(history.newHistoryId == "424242")
        #expect(history.messagesAdded.count == 1)
        #expect(history.messagesAdded.first?.messageId == "gmail-history-added-1")

        #expect(
            draftDelete.served == [204],
            "the 204 was not served exactly once — the DELETE either never reached the fake or the adapter repeated it: \(draftDelete.served)"
        )
        #expect(
            server.http.servedCallSequence() == [
                "DELETE /gmail/v1/users/me/drafts/\(providerMessageId)",
                "GET /gmail/v1/users/me/history",
            ],
            "unexpected served sequence: \(server.http.servedCallSequence())"
        )
    }

    /// Pins `deleteDraft`'s FIRST `/drafts/{id}` DELETE and its 401 retry —
    /// the `performHTTPRequestWithRetry` and the `performHTTPRequest` that
    /// follows `accessToken(true)`.
    ///
    /// The script answers the first DELETE with 401 and the retry with 204, so
    /// BOTH requests must reach the fake for `deleteDraft` to return at all.
    /// Removing `session:` from either line is decisive rather than absorbed:
    ///
    /// * initial DELETE escapes → live Gmail rejects the fabricated token with
    ///   its own 401 → the retry runs and takes the script's FIRST entry (401)
    ///   → `retry.statusCode != 404` → `deleteDraft` throws;
    /// * retry escapes → the live 401 comes back → same throw.
    ///
    /// Either way `served` is `[401]` instead of `[401, 204]` and the call
    /// sequence loses an entry. (If the machine is offline the escaping request
    /// fails at the transport instead, which throws just the same.)
    @Test("deleteDraft's initial DELETE and its 401 retry both route through the injected session")
    func deleteDraftRetriesTheDraftDeleteOnTheInjectedSessionAfter401() async throws {
        let providerMessageId = "gmail-session-escape-retry-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-session-escape-retry@example.com",
            providerMessageId: providerMessageId,
            labels: ["DRAFT"]
        )])
        defer { server.close() }
        let provider = server.provider()

        // 401 is not in `retryableStatusCodes` ([429, 403]), so the transport
        // does not retry it — the second DELETE is the adapter's own
        // token-refresh retry leg and nothing else.
        let draftDelete = FakeHTTP.ResponseScript([401, 204])
        server.http.register(path: "/drafts/\(providerMessageId)", method: "DELETE") { _ in
            .status(draftDelete.next())
        }

        try await provider.deleteDraft(identity: .gmail(resourceId: providerMessageId))

        #expect(
            draftDelete.served == [401, 204],
            "both canned responses must have been served — a missing one means that DELETE escaped to the live Gmail endpoint: \(draftDelete.served)"
        )
        #expect(
            server.http.servedCallSequence() == [
                "DELETE /gmail/v1/users/me/drafts/\(providerMessageId)",
                "DELETE /gmail/v1/users/me/drafts/\(providerMessageId)",
            ],
            "unexpected served sequence: \(server.http.servedCallSequence())"
        )
    }

    /// Pins the typed contained-MESSAGE delete and its 401 retry — the
    /// `performHTTPRequestWithRetry` on `/messages/{id}/trash` and the
    /// `performHTTPRequest` that follows its `accessToken(true)`.
    ///
    /// The address is explicitly in the contained-message namespace, so no
    /// resource DELETE or cross-namespace 404 fallback is involved. Both trash
    /// requests must reach the fake or `deleteDraft` throws:
    ///
    /// * trash POST escapes → live Gmail's 401 → the retry takes the script's
    ///   FIRST entry (401) → neither 404 nor a body → throw;
    /// * trash retry escapes → the live 401 comes back → same throw.
    ///
    /// The fixture models `/messages/` POST as the `/modify` route, so the
    /// trash registration uses the full `"/messages/{id}/trash"` prefix — the
    /// longest matching prefix wins, which keeps this off the modify handler.
    @Test("deleteDraft's contained-message request and 401 retry both route through the injected session")
    func deleteDraftContainedMessageAndItsRetryUseTheInjectedSession() async throws {
        let providerMessageId = "gmail-session-escape-trash-1"
        let server = StatefulGmailActionServer(messages: [.init(
            rfc822MessageId: "gmail-session-escape-trash@example.com",
            providerMessageId: providerMessageId,
            labels: ["DRAFT"]
        )])
        defer { server.close() }
        let provider = server.provider()

        let trash = FakeHTTP.ResponseScript([401, 200])
        server.http.register(path: "/messages/\(providerMessageId)/trash", method: "POST") { _ in
            let status = trash.next()
            return status == 200 ? .json(raw: "{}") : .status(status)
        }

        try await provider.deleteDraft(
            identity: .gmailContainedMessage(messageId: providerMessageId))

        #expect(
            trash.served == [401, 200],
            "both canned trash responses must have been served — a missing one means that POST escaped to the live Gmail endpoint: \(trash.served)"
        )
        #expect(
            server.http.servedCallSequence() == [
                "POST /gmail/v1/users/me/messages/\(providerMessageId)/trash",
                "POST /gmail/v1/users/me/messages/\(providerMessageId)/trash",
            ],
            "unexpected served sequence: \(server.http.servedCallSequence())"
        )
    }
}
