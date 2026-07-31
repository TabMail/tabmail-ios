/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

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
/// sequence is a wire-level proof that no v3 path resolves an action by RFC.
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

        #expect(server.modifyLog().allSatisfy { $0.providerMessageId == gone })
        #expect(
            server.consumedLookupFailureCount() == 0,
            "a stale provider id must not trigger an rfc822msgid: fallback search"
        )
    }

    /// Port of the reference's `ordinaryFolderListings`.
    ///
    /// Dropped: the two `failNextLookup()` / `consumedLookupFailureCount() == 1`
    /// legs, which asserted that a listing does NOT consume the action-lookup
    /// budget while a subsequent action DOES. The second half is unreachable on
    /// `v3` — no code path issues an `rfc822msgid:` search — so it is asserted
    /// in its inverted, v3-meaningful form in `duplicateRfc…` above instead.
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

        let inbox = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
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
}
