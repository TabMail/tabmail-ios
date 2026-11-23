/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("IOS-CLEANUP-001 destructive cleanup", .serialized, .processGlobalState)
struct DestructiveCleanupReliabilityTests {
    @Test("account-removal DB abort preserves credentials, files, row and waiting compose cards, and cancels prepared debt")
    func accountRemovalRollsBackAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("cleanup.sqlite").path,
            configuration: config
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
        let suiteName = "DestructiveCleanupReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let nseDefaults = UserDefaults(suiteName: "group.ai.tabmail")!
        let previousNSEAccountMap = nseDefaults.string(forKey: "nse.accountMap")
        let previousNSEIMAPAccounts = nseDefaults.string(forKey: "nse.imapAccounts")
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil,
            defaults: SendableRemovedAccountCleanupDefaults(value: defaults)
        )

        var account = Account(
            emailAddress: "abort-\(UUID().uuidString)@example.com",
            displayName: "Abort",
            provider: .gmail
        )
        account.id = "abort-account-\(UUID().uuidString)"
        var outbox = OutboxMessage(
            accountId: account.id,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Keep", body: "Keep")
        )
        let attachmentDirName = outbox.id
        outbox.attachmentsDirName = attachmentDirName
        let attachmentDir = OutboxMessage.attachmentsBaseDir
            .appendingPathComponent(attachmentDirName, isDirectory: true)
        let marker = attachmentDir.appendingPathComponent("marker")
        let passwordKey = KeychainHelper.passwordKey(accountId: account.id)
        let accessKey = KeychainHelper.accessTokenKey(accountId: account.id)
        let refreshKey = KeychainHelper.refreshTokenKey(accountId: account.id)
        let accountSnapshot = account
        let outboxSnapshot = outbox

        let cleanup: () async -> Void = {
            await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
                client: nil,
                defaults: nil
            )
            KeychainHelper.delete(key: passwordKey)
            KeychainHelper.delete(key: accessKey)
            KeychainHelper.delete(key: refreshKey)
            try? FileManager.default.removeItem(at: attachmentDir)
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap {
                nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap")
            } else {
                nseDefaults.removeObject(forKey: "nse.accountMap")
            }
            if let previousNSEIMAPAccounts {
                nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts")
            } else {
                nseDefaults.removeObject(forKey: "nse.imapAccounts")
            }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
            await MainActor.run { AgentToolRouter.shared.resetComposeQueueForTesting() }
        }

        do {
            try await pool.write { conn in
                try accountSnapshot.insert(conn)
                try outboxSnapshot.insert(conn)
            }
            try FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
            try Data("must survive".utf8).write(to: marker)
            try KeychainHelper.save("password", for: passwordKey)
            try KeychainHelper.save("access", for: accessKey)
            try KeychainHelper.save("refresh", for: refreshKey)

            try await pool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_removal
                BEFORE DELETE ON account
                BEGIN SELECT RAISE(ABORT, 'injected account removal failure'); END;
                """)
            }

            // An agent compose card for the account's email, asked in its chat and waiting for it.
            let waitingCard = await MainActor.run { () -> UUID in
                let router = AgentToolRouter.shared
                router.resetComposeQueueForTesting()
                let email = MessageHeader(
                    messageId: "1", subject: "Keep", from: "Alex", fromAddress: "alex@example.com",
                    to: accountSnapshot.emailAddress, date: Date(), snippet: "",
                    folderId: "\(accountSnapshot.id):INBOX", accountId: accountSnapshot.id,
                    folderPath: "INBOX", isInInbox: true)
                let request = AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: email, to: ["alex@example.com"], cc: [], bcc: [],
                    subject: "Re: Keep", body: nil,
                    origin: ComposeOrigin(
                        sessionKey: ChatThreadKey.key(accountId: accountSnapshot.id, threadId: "t-keep"), screen: .chat))
                router.enqueueCompose(request)
                return request.id
            }

            await #expect(throws: (any Error).self) {
                try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
            }

            let cardStillWaits = await MainActor.run {
                AgentToolRouter.shared.composeQueueDepth == 1
                    && AgentToolRouter.shared.firstQueuedRequestForTesting?.id == waitingCard
            }
            #expect(cardStillWaits, "an aborted removal ends no compose card of the account")
            // The account is not fenced off: its chat still takes the waiting card, and a later
            // request of the account is still admitted.
            let afterAbort = await MainActor.run { () -> (taken: UUID?, admitted: Bool, laterOutcome: String?) in
                let router = AgentToolRouter.shared
                let key = ChatThreadKey.key(accountId: accountSnapshot.id, threadId: "t-keep")
                let taken = router.takeCompose(for: AgentToolRouter.ComposeHost(screen: .chat, sessionKeys: [key]))?.id
                router.resetComposeQueueForTesting()
                let outcomes = Outcomes()
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: ["alex@example.com"], cc: [], bcc: [],
                    subject: "Later", body: nil,
                    origin: ComposeOrigin(sessionKey: key, screen: .chat, fromAccountId: accountSnapshot.id),
                    onOutcome: { outcomes.bySubject["Later"] = $0 }))
                return (taken, router.composeQueueDepth == 1, outcomes.bySubject["Later"]?.describeForLLM)
            }
            #expect(afterAbort.taken == waitingCard, "the account's chat still opens its waiting card")
            #expect(afterAbort.admitted && afterAbort.laterOutcome == nil, "a later request of the account still waits for its card")
            #expect(try await pool.read { try Account.fetchCount($0) } == 1)
            #expect(try await pool.read { try OutboxMessage.fetchCount($0) } == 1)
            #expect(KeychainHelper.loadString(key: passwordKey) == "password")
            #expect(KeychainHelper.loadString(key: accessKey) == "access")
            #expect(KeychainHelper.loadString(key: refreshKey) == "refresh")
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Holds a provider's disconnect on the wire until the test releases it.
    private actor ParkedDisconnect {
        private var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func park() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func hasEntered() -> Bool { entered }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// What a compose tool returned, once it has.
    private actor ToolAnswer {
        private(set) var value: String?
        func set(_ result: String) { value = result }
    }

    /// The outcomes compose requests received, by subject.
    @MainActor
    private final class Outcomes {
        var bySubject: [String: ComposeOutcome] = [:]
    }

    /// Polls `condition` for up to five seconds, giving way between checks; stops early when the
    /// test is cancelled. Every wait in a removal test is bounded, so a regression fails instead of
    /// hanging the run.
    @MainActor
    private static func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Task.isCancelled {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// How long a removal test's teardown waits for its removal and its tool to finish.
    private static let cleanupLimit: Duration = .seconds(10)

    /// INVARIANT (ADR-IOS-053): a committed account removal ends every agent compose card that
    /// depends on the account while the account's teardown is still on the wire. The tool waiting
    /// on one hears of the removal before the provider's disconnect returns; a card of the other
    /// account keeps waiting; a request for the removed account that arrives later ends at once.
    /// The removed account is a secondary one, and the waiting card is a new email asked in a chat
    /// that still shows through the surviving account's email, sent from the removed account.
    @Test("a committed removal of a secondary account ends its waiting compose cards before its provider disconnects")
    @MainActor
    func committedRemovalEndsWaitingComposeCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("cleanup.sqlite").path, configuration: config)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
        let suiteName = "DestructiveCleanupReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let nseDefaults = UserDefaults(suiteName: "group.ai.tabmail")!
        let previousNSEAccountMap = nseDefaults.string(forKey: "nse.accountMap")
        let previousNSEIMAPAccounts = nseDefaults.string(forKey: "nse.imapAccounts")
        // The removal's push cleanup reaches no worker: every call fails as if offline.
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: RemovedAccountPushCleanupTests.MockCleanupClient(),
            defaults: SendableRemovedAccountCleanupDefaults(value: defaults))

        var kept = Account(emailAddress: "kept-\(UUID().uuidString)@example.com", displayName: "Kept", provider: .imap)
        kept.isPrimary = true
        let keptAccount = kept
        let gone = Account(emailAddress: "gone-\(UUID().uuidString)@example.com", displayName: "Gone", provider: .imap)
        let provider = MockEmailProvider()
        let parked = ParkedDisconnect()
        await provider.setDisconnectHook { await parked.park() }
        await AccountManager.shared.registerProviderForTesting(accountId: gone.id, provider: provider)
        let router = AgentToolRouter.shared
        router.resetComposeQueueForTesting()

        var removal: Task<Void, any Error>?
        var toolRun: Task<Void, Never>?
        let cleanup: () async -> Void = {
            // Never leave the removal parked or the tool waiting: both finish before teardown.
            await parked.release()
            if let removal, await BoundedWait.result(of: removal, within: Self.cleanupLimit) == nil {
                Issue.record("the removal did not finish after its disconnect was released")
            }
            toolRun?.cancel()
            if let toolRun, await BoundedWait.result(of: toolRun, within: Self.cleanupLimit) == nil {
                Issue.record("the compose tool did not return after it was cancelled")
            }
            await AccountManager.shared.unregisterProviderForTesting(accountId: gone.id)
            router.resetComposeQueueForTesting()
            // The removal's own push cleanup pass runs against the offline client; let it
            // finish before the real client is restored.
            _ = await Self.eventually {
                PendingRemovedAccountPushCleanup.load(from: defaults).allSatisfy { !$0.actions.contains(.localArtifacts) }
            }
            await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(client: nil, defaults: nil)
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap { nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap") } else { nseDefaults.removeObject(forKey: "nse.accountMap") }
            if let previousNSEIMAPAccounts { nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts") } else { nseDefaults.removeObject(forKey: "nse.imapAccounts") }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        do {
            try await pool.write { conn in
                try keptAccount.insert(conn)
                try gone.insert(conn)
            }

            // The merged chat's key is the surviving account's; its new email is sent from the
            // account being removed, bound when the turn started.
            let mergedKey = ChatThreadKey.key(accountId: keptAccount.id, threadId: "t-merged")
            let tool = EmailComposeTool(context: ToolContext(db: pool, translator: MockChatIdTranslator()))
            let invocation = ToolInvocation(
                sessionKey: mergedKey,
                composeOrigin: ComposeOrigin(sessionKey: mergedKey, screen: .chat, fromAccountId: gone.id))
            let result = ToolAnswer()
            toolRun = Task {
                let text = (try? await tool.execute(
                    arguments: [
                        "to": .array([.string("alex@example.com")]),
                        "subject": .string("From the removed account"),
                        "body": .string("Hello"),
                    ],
                    invocation: invocation)) ?? "the tool threw"
                await result.set(text)
            }

            // A card of the surviving account, in the same chat, sent from it.
            let outcomes = Outcomes()
            router.enqueueCompose(AgentToolRouter.ComposeRequest(
                mode: .compose, replyTo: nil, to: ["sam@example.com"], cc: [], bcc: [],
                subject: "From the kept account", body: "Hello",
                origin: ComposeOrigin(sessionKey: mergedKey, screen: .chat, fromAccountId: keptAccount.id),
                onOutcome: { outcomes.bySubject["From the kept account"] = $0 }))

            let bothWait = await Self.eventually { router.composeQueueDepth == 2 }
            #expect(bothWait, "the tool's card and the other account's card wait for their chat")

            removal = Task { try await AccountManager.shared.removeAccount(gone, warnedSavedFiles: 0) }
            let disconnecting = await Self.eventually { await parked.hasEntered() }
            #expect(disconnecting, "the removal reaches the provider's disconnect")

            // The disconnect stays held until released below: the answer has to arrive first.
            let answered = await Self.eventually { await result.value != nil }
            #expect(answered, "the tool still waits while the removed account's provider disconnects")
            let removedFailure = ComposeOutcome.failed(AgentToolRouter.removedAccountReason).describeForLLM
            let toolSaw = await result.value
            #expect(toolSaw == removedFailure)
            let accountsLeft = try await pool.read { try Account.fetchCount($0) }
            #expect(accountsLeft == 1, "the removal has committed")

            #expect(router.composeQueueDepth == 1)
            let waitingSubject = router.firstQueuedRequestForTesting?.subject
            #expect(waitingSubject == "From the kept account", "the surviving account's card keeps waiting")
            let keptOutcome = outcomes.bySubject["From the kept account"]
            #expect(keptOutcome == nil)

            router.enqueueCompose(AgentToolRouter.ComposeRequest(
                mode: .compose, replyTo: nil, to: ["alex@example.com"], cc: [], bcc: [],
                subject: "Later, from the removed account", body: "Hello",
                origin: ComposeOrigin(sessionKey: mergedKey, screen: .chat, fromAccountId: gone.id),
                onOutcome: { outcomes.bySubject["Later, from the removed account"] = $0 }))
            let late = outcomes.bySubject["Later, from the removed account"]?.describeForLLM
            #expect(late == removedFailure, "a later request for the removed account ends at once")
            #expect(router.composeQueueDepth == 1)

            await parked.release()
            if let removal {
                switch await BoundedWait.result(of: removal, within: Self.cleanupLimit) {
                case .failure(let error)?: Issue.record("the removal failed after its commit: \(error)")
                case nil: Issue.record("the removal did not finish after its disconnect was released")
                case .success?: break
                }
            }
            let survivor = try await pool.read { try Account.fetchOne($0, key: keptAccount.id) }
            #expect(survivor != nil)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }


    /// INVARIANT (#718): account removal deletes no saved put-back file the user was not warned
    /// of. The files are counted again in the delete's own transaction; more than the warning said
    /// refuses the removal with the new count and changes nothing. As many as it said passes the
    /// count (the injected abort, which fires only at the delete, is what stops it then).
    @Test("account removal refuses, changing nothing, when more saved put-back files exist than the user was warned of")
    func accountRemovalRecountsSavedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("cleanup.sqlite").path, configuration: config)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
        let suiteName = "DestructiveCleanupReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let nseDefaults = UserDefaults(suiteName: "group.ai.tabmail")!
        let previousNSEAccountMap = nseDefaults.string(forKey: "nse.accountMap")
        let previousNSEIMAPAccounts = nseDefaults.string(forKey: "nse.imapAccounts")
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil, defaults: SendableRemovedAccountCleanupDefaults(value: defaults))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap { nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap") } else { nseDefaults.removeObject(forKey: "nse.accountMap") }
            if let previousNSEIMAPAccounts { nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts") } else { nseDefaults.removeObject(forKey: "nse.imapAccounts") }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        var account = Account(emailAddress: "saved-\(UUID().uuidString)@example.com", displayName: "Saved", provider: .outlook)
        account.id = "saved-files-account-\(UUID().uuidString)"
        let bytes = Data("own notes".utf8)
        let file = PutBackFile(occurrence: "occ-1", name: "notes.txt", contentType: "text/plain", isInline: false, contentId: nil,
                               sha256: SavedFileName.of(bytes))
        let recordData = try JSONSerialization.data(
            withJSONObject: [SeriesEditRecord.argumentKey: SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: [file], write: .sent, seriesEtag: "W/\"ser-1-0\"").jsonObject])
        let op = PendingCalendarOperation(
            operationType: .edit, accountId: account.id, eventId: "ser-1", calendarId: "primary",
            arguments: try JSONDecoder().decode([String: JSONValue].self, from: recordData), eventTitle: "Planning")
        let snapshot = account
        try await pool.write { conn in
            try snapshot.insert(conn)
            try op.insert(conn)
        }
        // Saved by a drain after the user saw a warning of none.
        _ = try CalendarPutBackFiles.save(bytes, opId: op.id)

        await #expect(throws: AccountRemovalSavedFilesGrew(savedFiles: 1)) {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
        }
        #expect(try await pool.read { try Account.fetchCount($0) } == 1)
        #expect(try await pool.read { try PendingCalendarOperation.fetchCount($0) } == 1)
        #expect(CalendarPutBackFiles.holdsBytes(op.id), "the saved file went")
        #expect(PendingRemovedAccountPushCleanup.load(from: defaults).isEmpty)

        try await pool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_removal
                BEFORE DELETE ON account
                BEGIN SELECT RAISE(ABORT, 'injected account removal failure'); END;
                """)
        }
        do {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 1)
            Issue.record("the injected abort did not fire")
        } catch {
            #expect(!(error is AccountRemovalSavedFilesGrew), "warned of as many files as are saved, the removal was still refused: \(error)")
        }
        #expect(CalendarPutBackFiles.holdsBytes(op.id), "the saved file went with an aborted removal")
    }

    /// INVARIANT (#979, ADR-IOS-117): the real account removal owns its chats' unsent words. A
    /// refused removal keeps them (shown, stored, and new words still written); a committed one
    /// forgets them and writes none again.
    @Test("account removal keeps the chat words when refused and forgets them, never writing again, when it commits")
    @MainActor
    func accountRemovalOwnsTheChatWords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("cleanup.sqlite").path, configuration: config)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
        let suiteName = "DestructiveCleanupReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let nseDefaults = UserDefaults(suiteName: "group.ai.tabmail")!
        let previousNSEAccountMap = nseDefaults.string(forKey: "nse.accountMap")
        let previousNSEIMAPAccounts = nseDefaults.string(forKey: "nse.imapAccounts")
        await PushNotificationService.shared._setRemovedAccountCleanupDependenciesForTesting(
            client: nil, defaults: SendableRemovedAccountCleanupDefaults(value: defaults))
        ChatFieldWords.shared = ChatFieldWords(database: { PrioritizedDatabase(pool: pool) })
        // The shared store is reset however the test ends, so no later test reads this one's.
        defer { ChatFieldWords.shared = ChatFieldWords() }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousNSEAccountMap { nseDefaults.set(previousNSEAccountMap, forKey: "nse.accountMap") } else { nseDefaults.removeObject(forKey: "nse.accountMap") }
            if let previousNSEIMAPAccounts { nseDefaults.set(previousNSEIMAPAccounts, forKey: "nse.imapAccounts") } else { nseDefaults.removeObject(forKey: "nse.imapAccounts") }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }

        var account = Account(emailAddress: "words-\(UUID().uuidString)@example.com", displayName: "Words", provider: .outlook)
        account.id = "words-account-\(UUID().uuidString)"
        let bytes = Data("own notes".utf8)
        let file = PutBackFile(occurrence: "occ-1", name: "notes.txt", contentType: "text/plain", isInline: false, contentId: nil,
                               sha256: SavedFileName.of(bytes))
        let recordData = try JSONSerialization.data(
            withJSONObject: [SeriesEditRecord.argumentKey: SeriesEditRecord(seriesId: "ser-1", capture: "{}", files: [file], write: .sent, seriesEtag: "W/\"ser-1-0\"").jsonObject])
        let op = PendingCalendarOperation(
            operationType: .edit, accountId: account.id, eventId: "ser-1", calendarId: "primary",
            arguments: try JSONDecoder().decode([String: JSONValue].self, from: recordData), eventTitle: "Planning")
        let snapshot = account
        try await pool.write { conn in
            try snapshot.insert(conn)
            try op.insert(conn)
        }
        _ = try CalendarPutBackFiles.save(bytes, opId: op.id)
        let typed = ChatThreadKey.key(accountId: account.id, threadId: "typed-before")
        let after = ChatThreadKey.key(accountId: account.id, threadId: "typed-after")
        let words: @Sendable () async throws -> [String: String] = {
            try await pool.read { db in
                Dictionary(uniqueKeysWithValues: try ChatFieldWordsRecord.fetchAll(db).map { ($0.sessionId, $0.words) })
            }
        }
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed before"), to: typed) }
        await ChatFieldWords.shared.written()
        #expect(try await words() == [typed: "Typed before"], "control: the words are kept")

        // Refused (more saved files than warned of): the words stay, and the account's chats write again.
        await #expect(throws: AccountRemovalSavedFilesGrew(savedFiles: 1)) {
            try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 0)
        }
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: typed).words } == "Typed before")
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed after the refusal"), to: after) }
        await ChatFieldWords.shared.written()
        #expect(try await words() == [typed: "Typed before", after: "Typed after the refusal"],
                "the refused removal released its hold")

        // Committed: the words go from disk and the store, and new ones are never written.
        try await AccountManager.shared.removeAccount(account, warnedSavedFiles: 1)
        #expect(try await pool.read { try Account.fetchCount($0) } == 0, "control: the removal committed")
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: typed).words } == "", "forgotten by the store")
        await MainActor.run { ChatFieldWords.shared.apply(.put("Typed after the removal"), to: after) }
        await ChatFieldWords.shared.written()
        #expect(await MainActor.run { ChatFieldWords.shared.fill(for: after).words } == "")
        #expect(try await words().isEmpty, "nothing of the removed account is written")
    }

    @Test("a stale Account value cannot resurrect runtime state after committed removal")
    func staleAccountCannotReconnect() async {
        var account = Account(
            emailAddress: "stale-\(UUID().uuidString)@example.com",
            displayName: "Removed",
            provider: .gmail
        )
        account.id = "removed-runtime-\(UUID().uuidString)"
        let manager = AccountManager.shared

        await manager.disconnectAccount(account, deletingCredentials: [])
        await #expect(throws: ProviderError.self) {
            try await manager.connectAccount(account)
        }

        #expect(await manager.providers[account.id] == nil)
        #expect(await manager.workQueues[account.id] == nil)
        #expect(await manager.calendarProviders[account.id] == nil)
        await #expect(throws: ProviderError.self) {
            try await manager.freshAccessToken(for: account)
        }
    }

    @Test("Reset Message Data rolls every GRDB mutation back on an injected mid-transaction ABORT")
    func accountResetRollsBackAtomically() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")

        try db.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_account_reset
                BEFORE DELETE ON messageBody
                BEGIN SELECT RAISE(ABORT, 'injected account reset failure'); END;
                """)
        }

        #expect(throws: (any Error).self) {
            try db.write { conn in
                try AccountDetailView.resetMessageDataTxn(conn, accountId: "acc1")
            }
        }

        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
        #expect(try db.read { try MessageBody.fetchCount($0) } == 1)
        #expect(try db.read { try Account.fetchCount($0) } == 1)
    }

}
