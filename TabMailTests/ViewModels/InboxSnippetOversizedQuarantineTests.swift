/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The THIRD fetch initiator for the oversized-metadata quarantine.
///
/// The stop-gap started by gating the four background admission queries and the user-open
/// path. The inbox snippet loader is neither: it queues any visible row whose snippet is
/// empty and, when tiers 0 and 1 miss, calls `provider.fetchMessage` — the SAME fetch
/// whose metadata response overflowed the IMAP parser and got the row flagged. Because
/// the overflow marks the folder connection unhealthy, every attempt pays a full
/// TCP + TLS + LOGIN + SELECT; and because `reloadMessages` clears `snippetFailed` before
/// re-queueing the visible window, an ungated quarantined row is retried on every reload,
/// forever, for a body this build cannot fetch.
///
/// The INVARIANT pinned here: **a quarantined row never reaches the snippet loader's
/// network tier.** The oracle is the loader's own blacklist, which separates the two
/// outcomes without needing a provider — a gated row is blacklisted, while a row that
/// merely has no provider available is left retryable (tier 2 `continue`s).
///
/// `.serialized, .processGlobalState`: the loader's tier-0 read goes to the process-wide
/// `AppDatabase.rawPool`, so the fixture must live in THAT database or the assertions
/// cannot fail.
/// The production predicate for this error is a description-substring test
/// (`"\(error)".contains("PayloadTooLargeError")`) in `IMAPProvider.withFolderConnection`,
/// both body queues, `BodyFetchProcessor.fetch` and now the snippet loader's catch — so a
/// stub only has to reproduce the description. `PayloadTooLargeError` itself lives in
/// swift-nio-imap and is not constructible here.
private struct StubSnippetPayloadTooLargeError: Error, CustomStringConvertible {
    var description: String { "PayloadTooLargeError: body exceeds the fixed NIO buffer" }
}

@Suite("The inbox snippet loader honours the oversized-metadata quarantine", .serialized, .processGlobalState)
struct InboxSnippetOversizedQuarantineTests {

    /// Temp file-backed pool with all migrations applied, swapped in as
    /// `AppDatabase.shared`. Returns the two seeded headers (one flagged, one not — the
    /// two-sidedness is built into the fixture so both cases run against identical rows)
    /// and a restore closure the caller MUST run in `defer`.
    @MainActor
    private func makeSwappedDB() throws -> (flagged: String, clean: String, folder: Folder, restore: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }

        var account = Account(emailAddress: "snippet@example.com", displayName: "Snippet", provider: .imap)
        account.id = "acc1"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        func header(_ messageId: String, oversized: Bool) -> MessageHeader {
            var h = MessageHeader(
                messageId: messageId,
                subject: "A message with no snippet yet",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: Date(),
                snippet: "",                    // empty — this is what queues it
                folderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            h.headerComplete = true
            h.bodyMetadataOversized = oversized
            return h
        }
        let flagged = header("9001", oversized: true)
        let clean = header("9002", oversized: false)
        try pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try flagged.insert(db)
            try clean.insert(db)
        }

        let restore: () -> Void = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        return (flagged.id, clean.id, folder, restore)
    }

    @Test("A quarantined row is blacklisted before the network tier, and an identical unflagged row is not")
    @MainActor
    func quarantinedRowNeverReachesTheNetworkTier() async throws {
        let (flaggedId, cleanId, folder, restore) = try makeSwappedDB()
        defer { restore() }

        // A REGISTERED provider, so the oracle can be the wire itself. Without one both
        // rows fail identically at tier 2's provider lookup, and a gate that blacklisted
        // the row while STILL appending it to `networkNeeded` would satisfy a
        // blacklist-only assertion while spending exactly the connection the gate exists
        // to save. `callLog` records every `fetchMessage`, so absence there is the
        // property this suite's own header claims. (Found by audit.)
        let provider = MockEmailProvider()
        var blacklisted: Set<String> = []
        await TestProviderRegistry.withRegisteredProvider(accountId: "acc1", provider: provider) {
            let vm = InboxViewModel(folders: [folder])
            blacklisted = await vm.runSnippetBatchForTesting([flaggedId, cleanId])
        }
        let calls = await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }

        #expect(!calls.contains { $0.contains("id:9001") },
                "the flagged row must never reach the wire — that fetch is the one that overflowed the parser, and each attempt costs a full connection teardown")
        // THE CONTROL, and it is what makes the assertion above mean something: the two
        // rows are identical apart from the flag, so an unflagged row MUST reach the wire.
        // A loader that skipped everything would satisfy the assertion above while proving
        // nothing.
        #expect(calls.contains { $0.contains("id:9002") },
                "an identical row without the flag must still be fetched")
        #expect(blacklisted.contains(flaggedId),
                "…and the flagged row is also blacklisted, so this reload does not re-queue it")
    }

    /// The eviction fail-safe, at this initiator too. `BodyAssetMaintenance` deletes the
    /// `messageBody` row while leaving `bodyComplete = 1`; a gate keyed on the flag alone
    /// would refuse to re-fetch a message this build has already fetched successfully.
    @Test("A proven-fetchable row carrying a stale flag is NOT blacklisted")
    @MainActor
    func provenFetchableRowIsNotBlacklisted() async throws {
        let (flaggedId, _, folder, restore) = try makeSwappedDB()
        defer { restore() }

        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                           arguments: [flaggedId])
        }

        let vm = InboxViewModel(folders: [folder])
        let blacklisted = await vm.runSnippetBatchForTesting([flaggedId])

        #expect(!blacklisted.contains(flaggedId),
                "eviction's designed recovery must survive the quarantine — a stale flag may cost a wasted round trip, never a permanently unreachable body")
    }

    /// The initiator that OBSERVES an overflow must record it, not merely remember it for
    /// this process. Tier 2 calls the same `provider.fetchMessage` the body queues do, and
    /// on a scrolling user it is frequently the first path to reach a deep-history message:
    /// `BackfillBodyQueue.admissionSQL` orders `date DESC`, so such a row can wait a long
    /// time for a queue to reach it. Without this the flagged population would be "the rows
    /// a background queue happened to reach first" — the exact property
    /// `MessageHeader.bodyMetadataOversized`'s doc claims it is NOT. And `snippetFailed`
    /// alone does not survive `resetSnippetState()`, which `reloadMessages` calls on every
    /// `.inboxDataDidChange`, so the same doomed fetch repeats on every reload.
    @Test("An overflow observed by the snippet loader is recorded durably, not just blacklisted for the session")
    @MainActor
    func snippetLoaderRecordsTheOverflowItObserves() async throws {
        let (_, cleanId, folder, restore) = try makeSwappedDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(StubSnippetPayloadTooLargeError())

        await TestProviderRegistry.withRegisteredProvider(accountId: "acc1", provider: provider) {
            let vm = InboxViewModel(folders: [folder])
            _ = await vm.runSnippetBatchForTesting([cleanId])
        }
        // Tier 2's mark goes onto `ActiveBodyQueue`'s serialized durable-write chain
        // (shared with the UIDVALIDITY reset's clear), so drain it before reading.
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: cleanId)
        })
        #expect(
            stored.bodyMetadataOversized,
            "the tier that saw the overflow must record it — otherwise the flagged population is whatever a background queue reached first")
        // Recording an observation is not retiring a row.
        #expect(stored.bodyComplete == false, "recording the observation must not mark the body complete")
        #expect(stored.bodyEmptyConfirmed == false, "an oversized body is not a confirmed-empty body")
    }

    /// THE CONTROL. Without it the assertion above is satisfied by a loader that flags on
    /// any tier-2 failure at all, which would durably quarantine rows over an ordinary
    /// transient error — a far worse bug than the one being fixed.
    @Test("A non-overflow tier-2 failure records nothing durable")
    @MainActor
    func ordinaryTierTwoFailureIsNotRecordedAsOversized() async throws {
        let (_, cleanId, folder, restore) = try makeSwappedDB()
        defer { restore() }

        let provider = MockEmailProvider()
        await provider.setFetchMessageThrows(ProviderError.messageNotFound)

        await TestProviderRegistry.withRegisteredProvider(accountId: "acc1", provider: provider) {
            let vm = InboxViewModel(folders: [folder])
            _ = await vm.runSnippetBatchForTesting([cleanId])
        }
        // Tier 2's mark goes onto `ActiveBodyQueue`'s serialized durable-write chain
        // (shared with the UIDVALIDITY reset's clear), so drain it before reading.
        await ActiveBodyQueue.shared.awaitDurableWritesForTesting()

        let stored = try #require(try await AppDatabase.dbPool.read { db in
            try MessageHeader.fetchOne(db, key: cleanId)
        })
        #expect(
            stored.bodyMetadataOversized == false,
            "only a parser overflow may set this flag — a messageNotFound must never durably quarantine a row")
    }
}
