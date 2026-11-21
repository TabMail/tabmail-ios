/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #915: after the user's reply, reply-all or forward is SENT, the Outlook original
/// records it the way Outlook's own apps do: `Integer 0x1081` (last verb: 102
/// reply, 103 reply all, 104 forward) and `SystemTime 0x1082` (the send time).
/// `POST /sendMail` never touches the original, so the durable `.markReplied` /
/// `.markForwarded` op writes them.
///
/// Every assertion is an end state on the fake Graph server: which message holds
/// which property values, how many times it was addressed. RED on the pre-#915
/// tree, whose Exchange arm was `case .replied, .forwarded: break`.
@Suite("Exchange records reply / reply-all / forward on the original", .serialized, .processGlobalState)
struct ExchangeLastVerbMarkTests {

    private static let verb = "Integer 0x1081"
    private static let verbTime = "SystemTime 0x1082"
    private static let iconIndex = "Integer 0x1080"

    /// A whole-second time an hour ago, so the stored ISO-8601 value is exact and
    /// differs from "now" (a mark written with the drain time would not match).
    private static func sendTime() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func server() -> StatefulExchangeActionServer {
        StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: "original@example.com", providerMessageId: "original", folderId: "INBOX"),
            .init(rfc822MessageId: "bystander@example.com", providerMessageId: "bystander", folderId: "INBOX"),
        ])
    }

    private static let source = ProviderMessageSource(
        memberIds: ["original"], folderPath: "INBOX", admittedUidValidity: nil)

    // MARK: - Provider

    @Test("Reply, reply-all and forward write 102 / 103 / 104 and the send time on the original only")
    func verbCodesAndTime() async throws {
        for (action, code) in [
            (ProviderMessageAction.replied(all: false, at: Self.sendTime()), "102"),
            (.replied(all: true, at: Self.sendTime()), "103"),
            (.forwarded(at: Self.sendTime()), "104"),
        ] {
            let server = Self.server()
            defer { server.close() }
            let outcome = try await server.provider().performMessageAction(action, at: Self.source)
            #expect(outcome.dispositionedMemberIds == ["original"])
            let stored = server.extendedProperties(providerMessageId: "original")
            #expect(stored?[Self.verb] == code)
            #expect(stored?[Self.verbTime] == Self.iso(Self.sendTime()))
            #expect(server.extendedProperties(providerMessageId: "bystander")?.isEmpty == true)
            #expect(server.mutationLog() == ["PATCH original"])
        }
    }

    /// Values are the MAPI ones (PidTagIconIndex 0x105 replied mail, 0x106
    /// forwarded mail), spelled here as decimal Graph strings, independent of
    /// the app's constants. Without the icon, OWA's list row shows no arrow
    /// (live check #915 B1).
    @Test("The PATCH names exactly the last verb, its time and the list icon, per verb")
    func patchBodyShape() async throws {
        let at = Self.sendTime()
        for (action, code, icon) in [
            (ProviderMessageAction.replied(all: false, at: at), "102", "261"),
            (.replied(all: true, at: at), "103", "261"),
            (.forwarded(at: at), "104", "262"),
        ] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages/original", method: "PATCH", response: .json(raw: #"{"id":"original"}"#))
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "fake-graph-token" }, session: http.session)
            _ = try await provider.performMessageAction(action, at: Self.source)

            let calls = http.recordedCalls()
            #expect(calls.count == 1)
            guard calls.count == 1 else { return }
            #expect(calls[0].method == "PATCH")
            let body = try #require(calls[0].body)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(json.keys) == ["singleValueExtendedProperties"])
            let properties = try #require(json["singleValueExtendedProperties"] as? [[String: String]])
            #expect(properties == [
                ["id": Self.verb, "value": code],
                ["id": Self.verbTime, "value": Self.iso(at)],
                ["id": Self.iconIndex, "value": icon],
            ])
        }
    }

    @Test("Running the mark twice leaves the server exactly as running it once")
    func idempotentOnRetry() async throws {
        let server = Self.server()
        defer { server.close() }
        let action = ProviderMessageAction.replied(all: true, at: Self.sendTime())
        _ = try await server.provider().performMessageAction(action, at: Self.source)
        let once = server.extendedProperties(providerMessageId: "original")
        _ = try await server.provider().performMessageAction(action, at: Self.source)
        #expect(server.extendedProperties(providerMessageId: "original") == once)
        #expect(once?[Self.verb] == "103")
    }

    @Test("A transient Graph failure throws (the op is retried) and writes nothing")
    func transientFailureIsRetryable() async throws {
        let server = Self.server()
        defer { server.close() }
        server.failNextPatch()
        await #expect(throws: (any Error).self) {
            _ = try await server.provider().performMessageAction(
                .forwarded(at: Self.sendTime()), at: Self.source)
        }
        #expect(server.extendedProperties(providerMessageId: "original")?.isEmpty == true)
        _ = try await server.provider().performMessageAction(.forwarded(at: Self.sendTime()), at: Self.source)
        #expect(server.extendedProperties(providerMessageId: "original")?[Self.verb] == "104")
    }

    // MARK: - End to end: completed send → durable op → drain → Graph

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let accountId = "exchange-915"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(emailAddress: "owner@example.com", displayName: "Owner", provider: .outlook)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func original(_ fixture: Fixture) -> MessageHeader {
        var value = MessageHeader(
            messageId: "original", subject: "Original", from: "Sender",
            fromAddress: "sender@example.com", to: "owner@example.com", date: Date(),
            snippet: "original",
            folderId: MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "INBOX"),
            accountId: fixture.accountId, folderPath: "INBOX", isInInbox: true)
        value.rfc822MessageId = "original@example.com"
        value.headerComplete = true
        return value
    }

    private func completedSend(
        _ fixture: Fixture, originalId: String, isForward: Bool, isReplyAll: Bool, sentAt: Date
    ) -> OutboxMessage {
        var value = OutboxMessage(
            accountId: fixture.accountId,
            draft: DraftMessage(
                to: ["sender@example.com"], subject: isForward ? "Fwd: Original" : "Re: Original",
                body: "text", inReplyTo: "<original@example.com>"),
            originalMessageHeaderId: originalId,
            isForward: isForward)
        value.isReplyAll = isReplyAll
        value.status = OutboxStatus.sending.rawValue
        value.sentAt = sentAt
        value.appendedToSent = true
        return value
    }

    @Test("A completed reply-all / reply / forward marks the Outlook original with its send time")
    @MainActor
    func completedSendMarksTheOriginal() async throws {
        for (isForward, isReplyAll, code) in [(false, true, "103"), (false, false, "102"), (true, false, "104")] {
            let server = Self.server()
            defer { server.close() }
            let f = try fixture()
            await AccountManager.shared.registerProviderForTesting(
                accountId: f.accountId, provider: server.provider())
            let parent = original(f)
            let sentAt = Self.sendTime()
            let sent = completedSend(
                f, originalId: parent.id, isForward: isForward, isReplyAll: isReplyAll, sentAt: sentAt)
            try await f.pool.writeWithoutTransaction { db in
                try parent.insert(db)
                try sent.insert(db)
            }
            // Before completion: the original carries no mark.
            #expect(server.extendedProperties(providerMessageId: "original")?.isEmpty == true)

            _ = try await f.pool.write { db in
                try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
            }
            await AccountManager.shared.drainPendingQueue()

            let stored = server.extendedProperties(providerMessageId: "original")
            #expect(stored?[Self.verb] == code, "isForward=\(isForward) isReplyAll=\(isReplyAll)")
            #expect(stored?[Self.verbTime] == Self.iso(sentAt), "the send time, not the drain time")
            #expect(server.extendedProperties(providerMessageId: "bystander")?.isEmpty == true)
            let left = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(left == 0)
            await finish(f)
        }
    }

    /// Reply, then archive in TabMail with the archive queued first: the move
    /// re-addresses the queued mark to the moved message's new Graph id, so the
    /// mark lands on the archived original.
    @Test("An in-app archive queued before the mark carries the mark to the moved original")
    @MainActor
    func inAppMoveCarriesTheMark() async throws {
        let server = Self.server()
        defer { server.close() }
        let f = try fixture()
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        let parent = original(f)
        let sentAt = Self.sendTime()
        let sent = completedSend(f, originalId: parent.id, isForward: false, isReplyAll: true, sentAt: sentAt)
        let archive = PendingOperation(
            type: .move, messageIds: ["original"], accountId: f.accountId,
            folderPath: "INBOX", destinationPath: "Archive")
        try await f.pool.writeWithoutTransaction { db in
            try parent.insert(db)
            try sent.insert(db)
            var queued = archive
            try queued.insert(db)
        }
        _ = try await f.pool.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
        }
        await AccountManager.shared.drainPendingQueue()

        let moved = server.snapshots(rfc822MessageId: "original@example.com")
        #expect(moved.count == 1)
        guard moved.count == 1 else { await finish(f); return }
        #expect(moved[0].folderId == "Archive")
        #expect(moved[0].providerMessageId != "original", "precondition: the move reallocated the id")
        let stored = server.extendedProperties(providerMessageId: moved[0].providerMessageId)
        #expect(stored?[Self.verb] == "103")
        #expect(stored?[Self.verbTime] == Self.iso(sentAt))
        let left = try await f.pool.read { db in try PendingOperation.fetchCount(db) }
        #expect(left == 0)
        await finish(f)
    }

    /// `IOS-GRAPH-006` (accepted): another client moves the original before the
    /// mark drains. The mark names a dead id, Graph answers 404, and the op leaves
    /// the queue as an authoritative no-op: no other message is written, nothing
    /// is re-sent, and the local replied flag is never cleared.
    @Test("An original moved by another client before the mark drains: 404 no-op, nothing else written")
    @MainActor
    func externallyMovedOriginalIsANoOp() async throws {
        let server = Self.server()
        defer { server.close() }
        let f = try fixture()
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())
        let parent = original(f)
        let sent = completedSend(f, originalId: parent.id, isForward: false, isReplyAll: false, sentAt: Self.sendTime())
        try await f.pool.writeWithoutTransaction { db in
            try parent.insert(db)
            try sent.insert(db)
        }
        _ = try await f.pool.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: sent.id, db: db)
        }
        // Another client archives the original (a separate provider: not the queue).
        _ = try await server.provider().performMessageAction(.move(destination: "Archive"), at: Self.source)
        server.clearMutationLog()

        await AccountManager.shared.drainPendingQueue()

        #expect(server.mutationLog() == ["PATCH original"], "one attempt at the dead id, nothing else")
        for snapshot in server.snapshots(rfc822MessageId: "original@example.com")
            + server.snapshots(rfc822MessageId: "bystander@example.com") {
            #expect(server.extendedProperties(providerMessageId: snapshot.providerMessageId)?.isEmpty == true)
        }
        let state = try await f.pool.read { db in
            (try PendingOperation.fetchCount(db), try MessageHeader.fetchOne(db, key: parent.id)?.isReplied)
        }
        #expect(state.0 == 0)
        // The 404 confirms the old id gone, so the local row may be removed until
        // sync brings the moved message back; it is never re-marked as unreplied.
        #expect(state.1 != false)
        await finish(f)
    }

    // MARK: - Reply-all mode on the draft row

    /// The user's latest compose entry decides reply vs reply-all for one `reply:`
    /// key, in both directions, through the production save merge.
    @Test("A draft save records the compose's reply-all mode, both ways")
    func draftSaveRecordsReplyAllMode() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        func draft(replyAll: Bool, updatedAt: Double) -> Draft {
            var value = Draft(
                id: "reply:acc1:orig@example.com", accountId: "acc1",
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Re: s", body: "b",
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: 1, updatedAt: updatedAt)
            value.isReplyAll = replyAll
            return value
        }
        try db.write { db in
            _ = try DraftStore.applySave(draft(replyAll: true, updatedAt: 1), db: db)
            #expect(try Draft.fetchOne(db, key: "reply:acc1:orig@example.com")?.isReplyAll == true)
            _ = try DraftStore.applySave(draft(replyAll: false, updatedAt: 2), db: db)
            #expect(try Draft.fetchOne(db, key: "reply:acc1:orig@example.com")?.isReplyAll == false)
            _ = try DraftStore.applySave(draft(replyAll: true, updatedAt: 3), db: db)
            #expect(try Draft.fetchOne(db, key: "reply:acc1:orig@example.com")?.isReplyAll == true)
        }
    }

    // MARK: - Provider boundary (ADR-IOS-060)

    /// The tag literals are defined once, in `Shared/API/GraphAPI.swift` (shared
    /// with the change reader, #890); no other file may spell them.
    @Test("The last-verb property tags live only in GraphAPI and the Exchange provider")
    func lastVerbTagsStayInsideExchangeProvider() throws {
        let root = DiagnosticPrintGateTests.repositoryRoot()
        var files = try DiagnosticPrintGateTests.appTargetSources()
        #expect(files.count > 100, "the scan must see the app target")
        let shared = root.appendingPathComponent("Shared")
        let enumerator = try #require(FileManager.default.enumerator(at: shared, includingPropertiesForKeys: nil))
        var sharedCount = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            files.append(.init(relativePath: relative, source: try String(contentsOf: url, encoding: .utf8)))
            sharedCount += 1
        }
        #expect(sharedCount > 0, "the scan must see Shared/")
        let holders = files
            .filter { $0.source.contains("0x1081") || $0.source.contains("0x1082") || $0.source.contains("0x1080") }
            .map(\.relativePath)
        #expect(holders.contains("Shared/API/GraphAPI.swift"), "non-vacuity: GraphAPI defines them")
        #expect(holders.allSatisfy {
            $0 == "Shared/API/GraphAPI.swift" || $0.hasPrefix("TabMail/Providers/ExchangeProvider")
        }, "outside GraphAPI and the Exchange provider: \(holders)")
    }

    /// #915: ComposeView hands its reply-all kind to the in-compose agent, whose
    /// every autosave stores it. The parameter defaults to false, so only this
    /// fence catches a dropped argument.
    @Test("ComposeView passes its reply-all kind to the in-compose agent")
    func composePassesReplyAllToTheAgent() throws {
        let file = try #require(try DiagnosticPrintGateTests.appTargetSources()
            .first { $0.relativePath == "TabMail/Views/Compose/ComposeView.swift" })
        let code = DiagnosticPrintGateTests.codeOnly(file.source)
        let calls = code.components(separatedBy: "DynamicIslandChat(").dropFirst()
        #expect(calls.count == 1, "expected one in-compose agent, found \(calls.count)")
        for call in calls {
            let args = String(call.prefix(4000))
            let end = args.range(of: "isExpanded:")
            let head = end.map { String(args[..<$0.lowerBound]) } ?? args
            #expect(head.contains("draftIsReplyAll: isReplyAll"))
        }
    }

    /// Both Reply All entry points open compose in reply-all mode. The views are
    /// not constructible in a unit test (one is private, one needs a live view
    /// model), so the fence reads each `replyAllComposeView` body.
    @Test("Every Reply All entry point opens compose with isReplyAll: true")
    func replyAllEntryPointsSetTheMode() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        let bodies = files.flatMap { file -> [String] in
            file.source.components(separatedBy: "func replyAllComposeView(for msg: MessageHeader)").dropFirst()
                .map { String($0.prefix(600)) }
        }
        #expect(bodies.count == 2, "expected the inbox and message-detail entry points, found \(bodies.count)")
        for body in bodies {
            let call = try #require(body.range(of: "ComposeView("))
            let close = try #require(body.range(of: ")\n    }", range: call.upperBound..<body.endIndex))
            #expect(body[call.upperBound..<close.lowerBound].contains("isReplyAll: true"))
        }
    }

    /// The agent's compose card opens through one presenter for every host
    /// (`AgentToolRouter.ComposeRequest.composeView(account:onOutcome:)`), which
    /// carries the request's reply-all flag into ComposeView for `.reply`, so an
    /// AI reply-all records 103 (#915).
    @Test("The agent compose presenter passes the request's reply-all flag")
    func agentComposeHostsPassReplyAll() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        let bodies = files.flatMap { file -> [String] in
            // Comments masked: a commented-out argument must not satisfy the fence.
            DiagnosticPrintGateTests.codeOnly(file.source)
                .components(separatedBy: "func composeView(account: Account?, onOutcome: @escaping @MainActor (ComposeOutcome) -> Void) -> ComposeView").dropFirst()
                .map { String($0) }
        }
        #expect(bodies.count == 1, "expected the one agent compose presenter, found \(bodies.count)")
        for body in bodies {
            let reply = try #require(body.range(of: "case .reply:"))
            let forward = try #require(body.range(of: "case .forward:", range: reply.upperBound..<body.endIndex))
            #expect(body[reply.upperBound..<forward.lowerBound].contains("isReplyAll: isReplyAll"))
        }
    }

    // MARK: - Migration v104

    @Test("v104 adds the reply-all and send-time columns with plain-reply defaults")
    func migrationDefaults() throws {
        let db = try TestDatabase.make()
        try db.write { db in
            #expect(try db.columns(in: "draft").contains { $0.name == "isReplyAll" })
            #expect(try db.columns(in: "outboxMessage").contains { $0.name == "isReplyAll" })
            let opColumns = try db.columns(in: "pendingOperation").map(\.name)
            #expect(opColumns.contains("replyAll"))
            #expect(opColumns.contains("sentAt"))

            try Account(emailAddress: "a@example.com", displayName: "A", provider: .outlook).insert(db)
            let accountId = try #require(try Account.fetchOne(db)?.id)
            var op = PendingOperation(
                type: .markReplied, messageIds: ["m"], accountId: accountId, folderPath: "INBOX")
            try op.insert(db)
            // A row written without the new columns (an op queued before v104) reads
            // as a plain reply with no recorded send time.
            try db.execute(sql: "UPDATE pendingOperation SET sentAt = NULL")
            let read = try #require(try PendingOperation.fetchOne(db))
            #expect(read.replyAll == false)
            #expect(read.sentAt == nil)
            #expect(read.verbTime == read.createdAt)
        }
    }
}
