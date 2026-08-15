/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Regression coverage for the UI-bound reads called out by IOS-PERF-010/011.
///
/// The result tests pin the user-visible contract while the scheduling tests
/// exhaust a real one-reader GRDB pool. Each async production helper must wait
/// for that reader, yet a heartbeat on `MainActor` must continue to run. A sync
/// `DatabasePool.read` regression still takes the same measured wall time but
/// starves the heartbeat, so the test distinguishes suspension from blocking.
/// Search uses the raw async pool to avoid per-keystroke NSE merge triggers;
/// Settings keeps the prioritized read-through contract for its eventual count.
@Suite("Search and Settings database reads suspend the main actor", .serialized)
@MainActor
struct SearchDatabaseSchedulingTests {

    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])

        func record(_ statement: String) {
            statements.withLock { $0.append(statement) }
        }

        func reset() {
            statements.withLock { $0 = [] }
        }

        func drainSelects() -> [String] {
            statements.withLock { statements in
                defer { statements = [] }
                return statements.filter { $0.contains("SELECT") }
            }
        }
    }

    private struct Env {
        let pool: DatabasePool
        let database: PrioritizedDatabase
        let directory: URL
        let tape: SQLTape
        let inbox: Folder
        let archive: Folder
        let exactHeaders: [MessageHeader]
        let movedHeader: MessageHeader
    }

    @MainActor
    private final class Heartbeat {
        private(set) var ticks = 0
        private var task: Task<Void, Never>?

        func start() {
            task = Task { @MainActor in
                while !Task.isCancelled {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }

    private func makeEnv() throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-db-scheduling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tape = SQLTape()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.maximumReaderCount = 1
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in
                tape.record(event.expandedDescription)
            }
        }

        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        try AppDatabase.runMigrations(on: pool)

        var account = Account(
            emailAddress: "user@example.com",
            displayName: "User",
            provider: .gmail
        )
        account.id = "acc1"
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: account.id)

        let now = Date()
        var exactHeaders: [MessageHeader] = []
        for index in 0..<12 {
            var header = MessageHeader(
                messageId: "exact-\(index)",
                subject: "Needle \(index)",
                from: "Sender \(index)",
                fromAddress: "sender\(index)@example.com",
                to: account.emailAddress,
                date: now.addingTimeInterval(-Double(index) * 60),
                snippet: "substring needle \(index)",
                folderId: inbox.id,
                accountId: account.id,
                folderPath: inbox.path,
                isInInbox: true
            )
            if index < 3 {
                header.date = now.addingTimeInterval(-100 * 24 * 60 * 60 - Double(index))
            }
            exactHeaders.append(header)
        }
        let movedHeader = MessageHeader(
            messageId: "stable-moved-id",
            subject: "Moved result",
            from: "Mover",
            fromAddress: "mover@example.com",
            to: account.emailAddress,
            date: now.addingTimeInterval(-30),
            snippet: "moved snippet",
            folderId: archive.id,
            accountId: account.id,
            folderPath: archive.path,
            isInInbox: false
        )

        try pool.write { db in
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
            for header in exactHeaders { try header.insert(db) }
            try movedHeader.insert(db)
        }
        tape.reset()

        return Env(
            pool: pool,
            database: PrioritizedDatabase(pool: pool),
            directory: directory,
            tape: tape,
            inbox: inbox,
            archive: archive,
            exactHeaders: exactHeaders,
            movedHeader: movedHeader
        )
    }

    private func finish(_ env: Env) {
        try? env.pool.close()
        try? FileManager.default.removeItem(at: env.directory)
    }

    private func ftsResult(for header: MessageHeader, key: String? = nil) -> FTSSearchResult {
        FTSSearchResult(
            contentKey: ContentKey(rawValue: key ?? header.id),
            messageId: header.messageId,
            snippet: "fts: \(header.subject)",
            rank: -1,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
    }

    private func searchResult(
        source: SearchResult.Source,
        accountId: String,
        folderPath: String,
        messageId: String,
        subject: String
    ) -> SearchResult {
        let headerId: String?
        switch source {
        case .local:
            headerId = "\(accountId):\(folderPath):\(messageId)"
        case .remote:
            headerId = nil
        }

        return SearchResult(
            source: source,
            accountId: accountId,
            accountEmail: "user@example.com",
            messageId: messageId,
            folderPath: folderPath,
            subject: subject,
            from: "Sender",
            fromAddress: "sender@example.com",
            date: Date(),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            headerId: headerId,
            capturedRfc822MessageId: "<\(messageId)@example.com>"
        )
    }

    /// Hold the only GRDB reader for a fixed interval, then prove `operation`
    /// waits for that reader without occupying the main actor.
    private func expectResponsiveReaderWait(
        _ label: String,
        pool: DatabasePool,
        operation: @MainActor () async throws -> Void
    ) async throws {
        let heartbeat = Heartbeat()
        heartbeat.start()
        try await Task.sleep(for: .milliseconds(80))

        // The sleep occupies a dedicated GCD test thread, never the main actor or
        // Swift's cooperative executor. The continuation resumes only after the
        // sole reader is held; its closure keeps holding that reader for 350 ms.
        await withCheckedContinuation { (acquired: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                try? pool.read { _ in
                    acquired.resume()
                    Thread.sleep(forTimeInterval: 0.35)
                }
            }
        }
        let ticksBefore = heartbeat.ticks
        let start = CFAbsoluteTimeGetCurrent()
        try await operation()
        let wallMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let ticksDuring = heartbeat.ticks - ticksBefore
        heartbeat.stop()

        print("[SearchDatabaseScheduling] \(label) wall=\(wallMs)ms ticks=\(ticksDuring)")
        #expect(wallMs >= 250, "\(label): test did not create a real reader wait (\(wallMs)ms)")
        #expect(
            ticksDuring >= 8,
            "\(label): main actor was starved during a \(wallMs)ms reader wait (\(ticksDuring) ticks)"
        )
    }

    @Test("FTS resolution batches exact hits and preserves ranked order")
    func ftsResolutionIsBatchedAndOrdered() throws {
        let env = try makeEnv()
        defer { finish(env) }

        let rankedHeaders = Array(env.exactHeaders.prefix(10).reversed())
        let ftsResults = rankedHeaders.map { ftsResult(for: $0) }
        env.tape.reset()
        let resolution = try env.pool.read { db in
            try SearchView.localFTSResolution(
                ftsResults,
                activeFolderIds: [env.inbox.id],
                logging: false,
                db: db
            )
        }
        let relevantSelects = env.tape.drainSelects().filter {
            $0.contains("FROM \"account\"") || $0.contains("FROM \"messageHeader\"")
        }

        #expect(resolution.results.map(\.headerId) == rankedHeaders.map { Optional($0.id) })
        #expect(resolution.results.map(\.accountEmail) == Array(repeating: "user@example.com", count: 10))
        #expect(resolution.rekeyHeals.isEmpty)
        #expect(relevantSelects.count == 2, "expected one account SELECT + one batched header SELECT: \(relevantSelects)")
    }

    @Test("FTS stable-provider drift recovery keeps scope and re-key semantics")
    func stableProviderDriftRecoveryIsPreserved() throws {
        let env = try makeEnv()
        defer { finish(env) }

        let staleKey = MessageIdentity.headerId(
            accountId: "acc1",
            folderPath: env.inbox.path,
            messageId: env.movedHeader.messageId
        )
        let resolution = try env.pool.read { db in
            try SearchView.localFTSResolution(
                [ftsResult(for: env.movedHeader, key: staleKey)],
                activeFolderIds: [env.archive.id],
                logging: false,
                db: db
            )
        }

        #expect(resolution.results.map(\.headerId) == [env.movedHeader.id])
        #expect(resolution.results.first?.snippet == "fts: \(env.movedHeader.subject)")
        #expect(resolution.rekeyHeals == [LocalFTSRekeyHeal(
            old: staleKey,
            new: env.movedHeader.id,
            newMessageId: env.movedHeader.messageId,
            newFolderId: env.archive.id
        )])
        #expect(resolution.healedDrift == 1)
        #expect(resolution.droppedNoHeader == 0)
        #expect(resolution.droppedOutOfScope == 0)
    }

    @Test("Legacy substring search keeps filtering, scope, and result ordering")
    func legacySubstringSemanticsArePreserved() async throws {
        let env = try makeEnv()
        defer { finish(env) }

        let results = await SearchView.legacyLocalSearch(
            "needle",
            folderIds: [env.inbox.id],
            pool: env.pool
        )

        #expect(results.count == env.exactHeaders.count)
        #expect(results.allSatisfy { $0.folderPath == env.inbox.path })
        #expect(results.allSatisfy { $0.accountEmail == "user@example.com" })
        #expect(results.map(\.date) == results.map(\.date).sorted(by: >))
    }

    @Test("Remote-first local merge preserves identity ownership and local rank")
    func remoteFirstLocalMergeIsDeduplicated() {
        let locals = [
            searchResult(source: .local, accountId: "gmail", folderPath: "INBOX",
                         messageId: "global-1", subject: "gmail local inbox"),
            searchResult(source: .local, accountId: "other", folderPath: "INBOX",
                         messageId: "global-1", subject: "other account collision"),
            searchResult(source: .local, accountId: "imap", folderPath: "INBOX",
                         messageId: "7", subject: "imap inbox local"),
            searchResult(source: .local, accountId: "imap", folderPath: "Archive",
                         messageId: "7", subject: "imap other-folder collision"),
            searchResult(source: .local, accountId: "gmail", folderPath: "Sent",
                         messageId: "unrelated", subject: "unrelated local")
        ]
        let remotes = [
            // Account-wide provider result supersedes every local folder copy of
            // the same globally stable message id, but never another account.
            searchResult(source: .remote, accountId: "gmail", folderPath: "",
                         messageId: "global-1", subject: "gmail remote"),
            // IMAP ids are folder-scoped, so only the INBOX twin is superseded.
            searchResult(source: .remote, accountId: "imap", folderPath: "INBOX",
                         messageId: "7", subject: "imap remote")
        ]

        let survivors = SearchView.localResultsNotSupersededByRemote(
            locals,
            remoteResults: remotes
        )

        #expect(survivors.map(\.subject) == [
            "other account collision",
            "imap other-folder collision",
            "unrelated local"
        ])
    }

    @Test("Legacy substring reader wait suspends MainActor")
    func legacySearchSuspendsMainActor() async throws {
        let env = try makeEnv()
        defer { finish(env) }

        try await expectResponsiveReaderWait("legacy search", pool: env.pool) {
            _ = await SearchView.legacyLocalSearch(
                "needle",
                folderIds: [env.inbox.id],
                pool: env.pool
            )
        }
    }

    @Test("FTS result reader wait suspends MainActor")
    func ftsResolutionSuspendsMainActor() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let result = ftsResult(for: env.exactHeaders[0])

        try await expectResponsiveReaderWait("FTS resolution", pool: env.pool) {
            _ = await SearchView.localFTSResolution(
                [result],
                activeFolderIds: [env.inbox.id],
                logging: false,
                pool: env.pool
            )
        }
    }

    @Test("Settings count reader wait suspends MainActor and returns the same count")
    func settingsCountSuspendsMainActor() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var count = -1

        try await expectResponsiveReaderWait("Settings old-message count", pool: env.pool) {
            count = try await PriorityGate.$inPrivilegedContext.withValue(true) {
                try await SettingsView.oldMessageCount(
                    folderIds: [env.inbox.id],
                    archiveCutoff: cutoff,
                    database: env.database
                )
            }
        }

        #expect(count == 3)
    }
}
