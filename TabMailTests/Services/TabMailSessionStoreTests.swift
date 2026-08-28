/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security
import Testing
@testable import TabMail

private enum SessionFinalityFuzzConfig {
    static var seeds: [UInt64] {
        if let raw = ProcessInfo.processInfo.environment["SESSION_FINALITY_FUZZ_REPLAY_SEED"],
           let seed = parseSeed(raw) {
            return [seed]
        }
        return [0x51_0A_7E, 0xC0FF_EE, 0xDEAD_BEEF, 0x1BAD_B002]
    }

    static var rounds: Int {
        if let raw = ProcessInfo.processInfo.environment["SESSION_FINALITY_FUZZ_ROUNDS"],
           let rounds = Int(raw), rounds > 0 {
            return rounds
        }
        return 2
    }

    private static func parseSeed(_ raw: String) -> UInt64? {
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw) ?? UInt64(raw, radix: 16)
    }
}

@Suite("TabMail session generation store")
struct TabMailSessionStoreTests {
    enum LegacyAuthorityScenario: String, CaseIterable, Sendable {
        case activeSharedOutranksHistorical
        case sharedReadFailureDoesNotFallback
        case malformedSharedDoesNotFallback
    }

    @MainActor
    @Test("late refresh cannot recreate a signed-out generation")
    func persistDoesNotRecreateSignedOutState() throws {
        let harness = makeHarness()
        let active = try harness.store.installNewSession(sessionData(user: "A", token: "old"))
        let generation = try #require(active.generation)

        try harness.store.deactivate()
        #expect(harness.store.updateCapturedGeneration(
            generation,
            data: sessionData(user: "A", token: "late")
        ) == .inactive)
        #expect(harness.store.loadActiveSession() == nil)
        #expect(!harness.backend.hasAccount(TabMailSessionStore.generationPrefix + generation))
    }

    @MainActor
    @Test("A late refresh cannot overwrite a later different-user or same-user generation")
    func lateRefreshCannotClobberLaterGeneration() throws {
        let harness = makeHarness()
        let first = try harness.store.installNewSession(sessionData(user: "A", token: "A1"))
        let firstGeneration = try #require(first.generation)
        let secondBytes = sessionData(user: "B", token: "B1")
        _ = try harness.store.installNewSession(secondBytes)

        #expect(harness.store.updateCapturedGeneration(
            firstGeneration,
            data: sessionData(user: "A", token: "late-A")
        ) == .inactive)
        #expect(harness.store.loadActiveSession()?.data == secondBytes)

        let thirdBytes = sessionData(user: "B", token: "B2")
        let second = try #require(harness.store.loadActiveSession())
        let secondGeneration = try #require(second.generation)
        _ = try harness.store.installNewSession(thirdBytes)
        #expect(harness.store.updateCapturedGeneration(
            secondGeneration,
            data: sessionData(user: "B", token: "late-B1")
        ) == .inactive)
        #expect(harness.store.loadActiveSession()?.data == thirdBytes)
    }

    @MainActor
    @Test("ordinary captured-generation refresh updates in place")
    func ordinaryRefreshPersists() throws {
        let harness = makeHarness()
        let active = try harness.store.installNewSession(sessionData(user: "A", token: "old"))
        let generation = try #require(active.generation)
        let refreshed = sessionData(user: "A", token: "new")

        #expect(harness.store.updateCapturedGeneration(generation, data: refreshed) == .updated)
        #expect(harness.store.loadActiveSession()?.data == refreshed)
    }

    @MainActor
    @Test("install writes pointer and generation with shared AfterFirstUnlock attributes")
    func installationAttributes() throws {
        let harness = makeHarness()
        let active = try harness.store.installNewSession(sessionData(user: "A"))
        let generation = try #require(active.generation)

        for account in [
            TabMailSessionStore.pointerAccount,
            TabMailSessionStore.generationPrefix + generation,
        ] {
            let item = try #require(harness.backend.item(account: account, accessGroup: TabMailSessionStore.accessGroup))
            #expect(item.accessGroup == TabMailSessionStore.accessGroup)
            #expect(item.accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        }
    }

    @Test("generic keychain migration classifies the session namespace through one shared predicate")
    func sessionNamespaceClassification() {
        #expect(TabMailSessionStore.isSessionAccount(TabMailSessionStore.pointerAccount))
        #expect(TabMailSessionStore.isSessionAccount(
            TabMailSessionStore.generationPrefix + UUID().uuidString
        ))
        #expect(!TabMailSessionStore.isSessionAccount("password:mail-account"))
        #expect(!TabMailSessionStore.isSessionAccount("tabmail_session_unrelated"))
    }

    @MainActor
    @Test("legacy migration preserves exact bytes and deletes its exact old shadow")
    func oldOnlyMigrationPreservesBytes() throws {
        let harness = makeHarness()
        let legacy = sessionData(user: "A", token: "legacy")
        harness.backend.insertHistorical(account: TabMailSessionStore.pointerAccount, data: legacy)

        try harness.store.migrateLegacySession(validate: isSession)

        let active = try #require(harness.store.loadActiveSession())
        #expect(active.data == legacy)
        #expect(active.generation != nil)
        #expect(!harness.backend.hasHistoricalPointer())
    }

    @MainActor
    @Test("migration failure before pointer swap leaves legacy bytes readable and retryable")
    func migrationFailureLeavesLegacyReadable() throws {
        let harness = makeHarness()
        let legacy = sessionData(user: "A", token: "legacy")
        harness.backend.insertShared(account: TabMailSessionStore.pointerAccount, data: legacy)
        harness.backend.failNextAdd(status: errSecInteractionNotAllowed)

        #expect(throws: TabMailSessionStore.StoreError.self) {
            try harness.store.migrateLegacySession(validate: isSession)
        }
        #expect(harness.store.loadActiveSession() == .init(data: legacy, location: .legacy))

        try harness.store.migrateLegacySession(validate: isSession)
        #expect(harness.store.loadActiveSession()?.data == legacy)
        #expect(harness.store.loadActiveSession()?.generation != nil)
    }

    @MainActor
    @Test("old-location activation failure preserves the exact historical source for retry")
    func oldLocationActivationFailurePreservesHistoricalSource() throws {
        let harness = makeHarness()
        let legacy = sessionData(user: "A", token: "historical-exact")
        let historicalReference = harness.backend.insertHistorical(
            account: TabMailSessionStore.pointerAccount,
            data: legacy
        )
        harness.backend.failNextAdd(
            account: TabMailSessionStore.pointerAccount,
            status: errSecInteractionNotAllowed
        )

        #expect(throws: TabMailSessionStore.StoreError.self) {
            try harness.store.migrateLegacySession(validate: isSession)
        }
        let survivingSource = try #require(harness.backend.item(reference: historicalReference))
        #expect(survivingSource.persistentReference == historicalReference)
        #expect(survivingSource.data == legacy)
        #expect(harness.backend.item(
            account: TabMailSessionStore.pointerAccount,
            accessGroup: TabMailSessionStore.accessGroup
        ) == nil)
        #expect(harness.backend.sharedPointerGeneration() == nil)

        try harness.relaunchedStore().migrateLegacySession(validate: isSession)
        let active = try #require(harness.store.loadActiveSession())
        #expect(active.data == legacy)
        #expect(active.generation != nil)
        #expect(harness.backend.item(reference: historicalReference) == nil)
    }

    @MainActor
    @Test(
        "shared namespace is authoritative over historical identity",
        arguments: LegacyAuthorityScenario.allCases
    )
    func sharedStateOutranksOldShadow(scenario: LegacyAuthorityScenario) throws {
        let harness = makeHarness()
        let oldA = sessionData(user: "old-A")

        switch scenario {
        case .activeSharedOutranksHistorical:
            let activeB = sessionData(user: "active-B")
            _ = try harness.store.installNewSession(activeB)
            harness.backend.insertHistorical(account: TabMailSessionStore.pointerAccount, data: oldA)

            try harness.store.migrateLegacySession(validate: isSession)

            #expect(harness.store.loadActiveSession()?.data == activeB)
            #expect(!harness.backend.hasHistoricalPointer())

        case .sharedReadFailureDoesNotFallback:
            harness.backend.insertHistorical(account: TabMailSessionStore.pointerAccount, data: oldA)
            harness.backend.failNextSharedRead(status: errSecInteractionNotAllowed)

            #expect(throws: TabMailSessionStore.StoreError.self) {
                try harness.store.migrateLegacySession(validate: isSession)
            }
            #expect(harness.store.loadActiveSession() == nil)
            #expect(harness.backend.hasHistoricalPointer())

        case .malformedSharedDoesNotFallback:
            let malformed = Data("not-a-session-or-pointer".utf8)
            harness.backend.insertShared(account: TabMailSessionStore.pointerAccount, data: malformed)
            harness.backend.insertHistorical(account: TabMailSessionStore.pointerAccount, data: oldA)

            try harness.store.migrateLegacySession(validate: isSession)

            #expect(harness.store.loadActiveSession()?.data == malformed)
            #expect(!harness.backend.hasHistoricalPointer())
        }
    }

    @MainActor
    @Test("historical-shadow delete failure leaves active pointer and emits no inferred success")
    func shadowFailureLeavesPointer() throws {
        let harness = makeHarness()
        let activeBytes = sessionData(user: "B")
        _ = try harness.store.installNewSession(activeBytes)
        let shadow = harness.backend.insertHistorical(
            account: TabMailSessionStore.pointerAccount,
            data: sessionData(user: "A")
        )
        harness.backend.failDelete(reference: shadow)

        let notices = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .tabMailDidSignOut,
            object: nil,
            queue: nil
        ) { _ in notices.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(!TabMailAuthService.completeSession(
            mode: .deactivate,
            sessionStore: harness.store
        ))
        #expect(notices.value == 0)
        #expect(harness.store.loadActiveSession()?.data == activeBytes)

        harness.backend.allowDelete(reference: shadow)
        #expect(TabMailAuthService.completeSession(
            mode: .deactivate,
            notify: false,
            sessionStore: harness.store
        ))
        #expect(harness.relaunchedStore().loadActiveSession() == nil)
        #expect(!harness.backend.hasHistoricalPointer())
        #expect(harness.backend.sessionNamespaceItems().isEmpty)
    }

    @MainActor
    @Test("ambiguous pointer read makes orphan sweep delete nothing")
    func sweepFailsClosedOnReadError() throws {
        let harness = makeHarness()
        let active = try harness.store.installNewSession(sessionData(user: "A"))
        let orphanAccount = TabMailSessionStore.generationPrefix + UUID().uuidString
        harness.backend.insertShared(account: orphanAccount, data: sessionData(user: "orphan"))
        harness.backend.failNextSharedRead(status: errSecInteractionNotAllowed)

        harness.store.sweepInactiveGenerations()

        #expect(harness.backend.hasAccount(orphanAccount))
        #expect(harness.backend.hasAccount(
            TabMailSessionStore.generationPrefix + (try #require(active.generation))
        ))
    }

    @MainActor
    @Test("durable cleanup pending suppresses reads and installation until verified strong cleanup")
    func cleanupPendingFailsClosed() throws {
        let harness = makeHarness()
        _ = try harness.store.installNewSession(sessionData(user: "A"))
        harness.store.markCleanupPending()

        #expect(harness.store.loadActiveSession() == nil)
        #expect(throws: TabMailSessionStore.StoreError.cleanupPending) {
            _ = try harness.store.installNewSession(sessionData(user: "B"))
        }

        try harness.store.deleteAllSessionStorage()
        harness.store.clearCleanupPending()
        #expect(harness.store.loadActiveSession() == nil)
        #expect(harness.backend.sessionNamespaceItems().isEmpty)
    }

    @MainActor
    @Test("failed fresh-install cleanup remains pending across a relaunch even after a database appears")
    func cleanupPendingOutranksLaterDatabaseHeuristic() throws {
        let harness = makeHarness()
        _ = try harness.store.installNewSession(sessionData(user: "stale"))
        harness.backend.failNextEnumeration(status: errSecInteractionNotAllowed)

        let firstLaunch = TabMailApp.prepareSessionStorageForLaunch(
            sessionStore: harness.store,
            launchDefaults: harness.launchDefaults,
            databaseExists: { false }
        )
        #expect(!firstLaunch.hadLaunchedBefore)
        #expect(!firstLaunch.databaseExists)
        #expect(harness.store.isCleanupPending)
        #expect(harness.store.loadActiveSession() == nil)
        #expect(harness.backend.sessionNamespaceItems().isEmpty == false)

        var secondDatabaseProbeSawResidue: Bool?
        let secondLaunch = TabMailApp.prepareSessionStorageForLaunch(
            sessionStore: harness.relaunchedStore(),
            launchDefaults: harness.launchDefaults,
            databaseExists: {
                secondDatabaseProbeSawResidue = !harness.backend.sessionNamespaceItems().isEmpty
                return true
            }
        )

        #expect(secondLaunch.hadLaunchedBefore)
        #expect(secondLaunch.databaseExists)
        #expect(secondDatabaseProbeSawResidue == false)
        #expect(!harness.store.isCleanupPending)
        #expect(harness.backend.sessionNamespaceItems().isEmpty)
    }

    @MainActor
    @Test(
        "bounded seeded real-refresh schedules preserve pointer finality",
        arguments: SessionFinalityFuzzConfig.seeds
    )
    func stateMachineFuzz(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed)

        for round in 0..<SessionFinalityFuzzConfig.rounds {
            let harness = makeHarness()
            let initialBytes = sessionData(user: "A", token: "old-A", expiresAt: 1)
            let initial = try harness.store.installNewSession(initialBytes)
            let capturedGeneration = try #require(initial.generation)

            // Activation fault: an uncommitted candidate cannot disturb A.
            harness.backend.failNextAdd(status: errSecInteractionNotAllowed)
            #expect(throws: TabMailSessionStore.StoreError.self) {
                _ = try harness.store.installNewSession(sessionData(user: "failed-activation"))
            }
            #expect(harness.store.loadActiveSession()?.data == initialBytes)

            // Deactivation fault: a historical shadow must be removed first.
            let shadow = harness.backend.insertHistorical(
                account: TabMailSessionStore.pointerAccount,
                data: sessionData(user: "historical")
            )
            harness.backend.failDelete(reference: shadow)
            #expect(throws: TabMailSessionStore.StoreError.self) { try harness.store.deactivate() }
            #expect(harness.store.loadActiveSession()?.data == initialBytes)
            harness.backend.allowDelete(reference: shadow)

            let response = sessionData(user: "A", token: "late-A-\(round)")
            let held = HeldRefreshTransport(data: response)
            let useNSE = rng.pick(2) == 0
            let coordinator = TabMailTokenCoordinator(
                sessionStore: harness.store,
                dataForRequest: { request in try await held.data(for: request) }
            )
            let refresh = Task<String?, Never> {
                if useNSE {
                    return await NSETokenManager.validAccessToken(
                        sessionStore: harness.store,
                        dataForRequest: { request in try await held.data(for: request) }
                    )
                }
                guard case .success(let token) = await coordinator.validToken() else { return nil }
                return token
            }
            await held.waitUntilStarted()

            let expectedActive: Data?
            switch rng.pick(3) {
            case 0:
                try harness.store.deactivate()
                expectedActive = nil
            case 1:
                let next = sessionData(user: "B", token: "B-\(round)")
                _ = try harness.store.installNewSession(next)
                expectedActive = next
            default:
                try harness.store.deactivate()
                let next = sessionData(user: "A", token: "new-A-\(round)")
                _ = try harness.store.installNewSession(next)
                expectedActive = next
            }

            // Typed pointer/enumeration ambiguity cannot delete or promote.
            let orphan = TabMailSessionStore.generationPrefix + "orphan-\(seed)-\(round)"
            harness.backend.insertShared(account: orphan, data: sessionData(user: "orphan"))
            harness.backend.failNextSharedRead(status: errSecInteractionNotAllowed)
            harness.store.sweepInactiveGenerations()
            #expect(harness.backend.hasAccount(orphan), "seed \(seed), round \(round): read ambiguity deleted")
            #expect(harness.store.loadActiveSession()?.data == expectedActive)
            harness.backend.failNextEnumeration(status: errSecInteractionNotAllowed)
            harness.store.sweepInactiveGenerations()
            #expect(harness.backend.hasAccount(orphan), "seed \(seed), round \(round): enumeration ambiguity deleted")

            await held.release()
            #expect(await refresh.value == "late-A-\(round)")
            #expect(harness.store.loadActiveSession()?.data == expectedActive)
            #expect(!harness.backend.hasAccount(TabMailSessionStore.generationPrefix + capturedGeneration),
                    "seed \(seed), round \(round): inactive response recreated its generation")
            #expect(harness.backend.sharedPointerGeneration() == harness.store.loadActiveSession()?.generation,
                    "seed \(seed), round \(round): pointer/generation diverged")

            harness.store.sweepInactiveGenerations()
            #expect(!harness.backend.hasAccount(orphan), "seed \(seed), round \(round): orphan survived safe sweep")

            // Migration failure is replayable and retains exact legacy bytes.
            let legacyHarness = makeHarness()
            let legacy = sessionData(user: "legacy", token: "legacy-\(round)")
            legacyHarness.backend.insertShared(account: TabMailSessionStore.pointerAccount, data: legacy)
            legacyHarness.backend.failNextAdd(status: errSecInteractionNotAllowed)
            #expect(throws: TabMailSessionStore.StoreError.self) {
                try legacyHarness.store.migrateLegacySession(validate: isSession)
            }
            #expect(legacyHarness.store.loadActiveSession()?.data == legacy)
            try legacyHarness.store.migrateLegacySession(validate: isSession)
            #expect(legacyHarness.store.loadActiveSession()?.data == legacy)
        }
    }

    fileprivate func makeHarness() -> SessionStoreHarness {
        let backend = MemorySessionKeychainBackend()
        let defaultsName = "TabMailSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let launchDefaultsName = "TabMailSessionStoreLaunchTests.\(UUID().uuidString)"
        let launchDefaults = UserDefaults(suiteName: launchDefaultsName)!
        launchDefaults.removePersistentDomain(forName: launchDefaultsName)
        let generations = TestGenerationSequence()
        let store = TabMailSessionStore(
            backend: backend,
            cleanupDefaults: defaults,
            makeGeneration: { generations.next() }
        )
        return SessionStoreHarness(
            store: store,
            backend: backend,
            cleanupDefaults: defaults,
            launchDefaults: launchDefaults,
            generations: generations
        )
    }

    fileprivate func sessionData(
        user: String,
        token: String = "access",
        expiresAt: Int = 9_999_999_999
    ) -> Data {
        Data("""
        {"access_token":"\(token)","refresh_token":"refresh-\(user)","expires_at":\(expiresAt),"user":{"id":"\(user)","email":"\(user)@example.com"}}
        """.utf8)
    }

    private func isSession(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(TabMailSession.self, from: data)) != nil
    }
}

@Suite("Real app and NSE refresh finality")
struct SessionRefreshFinalityTests {
    @MainActor
    @Test("held app refresh may finish but cannot overwrite the next login")
    func heldAppRefreshCannotClobberNextLogin() async throws {
        let fixture = TabMailSessionStoreTests()
        let harness = fixture.makeHarness()
        _ = try harness.store.installNewSession(
            fixture.sessionData(user: "A", token: "old-A", expiresAt: 1)
        )
        let held = HeldRefreshTransport(
            data: fixture.sessionData(user: "A", token: "new-A")
        )
        let coordinator = TabMailTokenCoordinator(
            sessionStore: harness.store,
            dataForRequest: { request in try await held.data(for: request) }
        )

        let refresh = Task { await coordinator.validToken() }
        await held.waitUntilStarted()
        try harness.store.deactivate()
        let userB = fixture.sessionData(user: "B", token: "B")
        _ = try harness.store.installNewSession(userB)
        await held.release()

        guard case .success(let token) = await refresh.value else {
            Issue.record("held app refresh should finish its current invocation")
            return
        }
        #expect(token == "new-A")
        #expect(harness.store.loadActiveSession()?.data == userB)
    }

    @MainActor
    @Test("held compiled NSE refresh may finish but cannot recreate sign-out")
    func heldNSERefreshCannotResurrect() async throws {
        let fixture = TabMailSessionStoreTests()
        let harness = fixture.makeHarness()
        _ = try harness.store.installNewSession(
            fixture.sessionData(user: "A", token: "old-A", expiresAt: 1)
        )
        let held = HeldRefreshTransport(
            data: fixture.sessionData(user: "A", token: "new-A")
        )

        let refresh = Task {
            await NSETokenManager.validAccessToken(
                sessionStore: harness.store,
                dataForRequest: { request in try await held.data(for: request) }
            )
        }
        await held.waitUntilStarted()
        try harness.store.deactivate()
        await held.release()

        #expect(await refresh.value == "new-A")
        #expect(harness.store.loadActiveSession() == nil)
        #expect(harness.backend.sessionNamespaceItems().isEmpty)
    }

    @MainActor
    @Test("NSE uses valid legacy access but never refreshes an expired legacy session")
    func nseLegacyRules() async throws {
        let fixture = TabMailSessionStoreTests()

        let validHarness = fixture.makeHarness()
        let valid = fixture.sessionData(user: "A", token: "valid-legacy")
        validHarness.backend.insertShared(account: TabMailSessionStore.pointerAccount, data: valid)
        let validCalls = LockedCounter()
        let validToken = await NSETokenManager.validAccessToken(
            sessionStore: validHarness.store,
            dataForRequest: { _ in
                validCalls.increment()
                throw URLError(.cannotConnectToHost)
            }
        )
        #expect(validToken == "valid-legacy")
        #expect(validCalls.value == 0)

        let expiredHarness = fixture.makeHarness()
        expiredHarness.backend.insertShared(
            account: TabMailSessionStore.pointerAccount,
            data: fixture.sessionData(user: "A", token: "expired", expiresAt: 1)
        )
        let expiredCalls = LockedCounter()
        let expiredToken = await NSETokenManager.validAccessToken(
            sessionStore: expiredHarness.store,
            dataForRequest: { _ in
                expiredCalls.increment()
                throw URLError(.cannotConnectToHost)
            }
        )
        #expect(expiredToken == nil)
        #expect(expiredCalls.value == 0)
    }

    @MainActor
    @Test("main app never refreshes an expired legacy session when migration fails")
    func mainLegacyFailureMakesNoRefreshRequest() async {
        let fixture = TabMailSessionStoreTests()
        let harness = fixture.makeHarness()
        harness.backend.insertShared(
            account: TabMailSessionStore.pointerAccount,
            data: fixture.sessionData(user: "A", token: "expired", expiresAt: 1)
        )
        harness.backend.failNextAdd(status: errSecInteractionNotAllowed)
        let calls = LockedCounter()
        let coordinator = TabMailTokenCoordinator(
            sessionStore: harness.store,
            dataForRequest: { _ in
                calls.increment()
                throw URLError(.cannotConnectToHost)
            }
        )

        guard case .transientFailure = await coordinator.validToken() else {
            Issue.record("failed migration must fail closed before refresh")
            return
        }
        #expect(calls.value == 0)
        #expect(harness.store.loadActiveSession()?.location == .legacy)
    }

    @MainActor
    @Test("cleanup pending blocks each real login-view provider starter before launch")
    func cleanupPendingBlocksProviderStarts() async {
        let fixture = TabMailSessionStoreTests()
        for provider in [TabMailProvider.google, .microsoft, .apple] {
            let harness = fixture.makeHarness()
            harness.store.markCleanupPending()
            let starts = LockedCounter()
            await #expect(throws: TabMailAuthError.self) {
                try await TabMailLoginView.startProviderSignIn(
                    provider,
                    sessionStore: harness.store,
                    operation: { startedProvider in
                        #expect(startedProvider == provider)
                        starts.increment()
                    }
                )
            }
            #expect(starts.value == 0)
        }
    }

    @MainActor
    @Test("session completion emits no sign-out notification when pointer deletion fails")
    func failedCompletionDoesNotNotify() throws {
        let fixture = TabMailSessionStoreTests()
        let harness = fixture.makeHarness()
        let active = fixture.sessionData(user: "A")
        _ = try harness.store.installNewSession(active)
        let pointer = try #require(harness.backend.item(
            account: TabMailSessionStore.pointerAccount,
            accessGroup: TabMailSessionStore.accessGroup
        ))
        harness.backend.failDelete(reference: pointer.persistentReference)

        let notices = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .tabMailDidSignOut,
            object: nil,
            queue: nil
        ) { _ in notices.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(!TabMailAuthService.completeSession(
            mode: .deactivate,
            sessionStore: harness.store
        ))
        #expect(notices.value == 0)
        #expect(harness.store.loadActiveSession()?.data == active)
    }
}

@Suite("Session wiring census")
struct SessionWiringCensusTests {
    @Test("all production raw session readers route through TabMailSessionStore")
    func rawReaderCensus() throws {
        let root = projectRoot()
        let sourceRoots = ["TabMail", "TabMailNotificationService", "Shared"]
        let forbidden = [
            "KeychainHelper.load(key: \"tabmail_session\")",
            "SharedKeychain.getSession()",
            "SharedKeychain.setSession(",
        ]
        var violations: [String] = []
        for sourceRoot in sourceRoots {
            let directory = root.appendingPathComponent(sourceRoot)
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                if forbidden.contains(where: source.contains) {
                    violations.append(file.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
        }
        #expect(violations.isEmpty, "raw session access bypasses: \(violations)")

        let requiredRoutes: [(path: String, fragment: String)] = [
            ("TabMail/Services/PushNotificationService.swift", "TabMailAuthService.getSession()"),
            ("TabMail/Services/DebugModeManager.swift", "TabMailAuthService.getSession()"),
            ("TabMail/Services/Account/AccountManagerAI.swift", "TabMailAuthService.hasSession()"),
            ("TabMail/Services/TabMailTokenCoordinator.swift", "sessionStore.loadActiveSession()"),
            ("TabMailNotificationService/NSETokenManager.swift", "sessionStore.loadActiveSession()"),
        ]
        for route in requiredRoutes {
            let source = try String(
                contentsOf: root.appendingPathComponent(route.path),
                encoding: .utf8
            )
            #expect(source.contains(route.fragment), "missing session-store route: \(route.path)")
        }
    }

    @MainActor
    @Test("shared auth reader decodes the pointer-backed generation")
    func pointerBackedAuthReader() throws {
        let fixture = TabMailSessionStoreTests()
        let harness = fixture.makeHarness()
        let bytes = fixture.sessionData(user: "pointer-reader", token: "pointer-token")
        _ = try harness.store.installNewSession(bytes)

        let session = try #require(TabMailAuthService.getSession(sessionStore: harness.store))
        #expect(session.userId == "pointer-reader")
        #expect(session.accessToken == "pointer-token")
    }

    @Test("one production sign-out emitter and compiled NSE token test membership")
    func emitterAndMembershipCensus() throws {
        let root = projectRoot()
        let appRoot = root.appendingPathComponent("TabMail")
        let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        var emitters: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("post(name: .tabMailDidSignOut") {
                emitters.append(file.lastPathComponent)
            }
        }
        #expect(emitters == ["TabMailAuthService.swift"])

        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(project.contains("- path: TabMailNotificationService/NSETokenManager.swift"))
        #expect(!project.contains("- path: Shared/Persistence/TabMailSessionStore.swift"))
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor HeldRefreshTransport {
    private let responseData: Data
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(data: Data) {
        responseData = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let response = HTTPURLResponse(
            url: URL(string: "https://auth.tabmail.ai/auth/v1/token")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        responseContinuation?.resume(returning: (responseData, response))
        responseContinuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private struct SessionStoreHarness {
    let store: TabMailSessionStore
    let backend: MemorySessionKeychainBackend
    let cleanupDefaults: UserDefaults
    let launchDefaults: UserDefaults
    let generations: TestGenerationSequence

    func relaunchedStore() -> TabMailSessionStore {
        let generationSequence = generations
        return TabMailSessionStore(
            backend: backend,
            cleanupDefaults: cleanupDefaults,
            makeGeneration: { generationSequence.next() }
        )
    }
}

private final class TestGenerationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return String(format: "00000000-0000-0000-0000-%012llu", value)
    }
}

private final class MemorySessionKeychainBackend: @unchecked Sendable, TabMailSessionKeychainBackend {
    private let lock = NSLock()
    private var items: [Data: TabMailSessionKeychainItem] = [:]
    private var nextReference = 0
    private var nextReadFailure: OSStatus?
    private var nextAddFailure: (account: String?, status: OSStatus)?
    private var nextEnumerationFailure: OSStatus?
    private var failedDeletes: Set<Data> = []

    func readShared(account: String) -> TabMailSessionReadResult {
        lock.withLock {
            if let status = nextReadFailure {
                nextReadFailure = nil
                return .failed(status)
            }
            guard let item = items.values.first(where: {
                $0.account == account && $0.accessGroup == TabMailSessionStore.accessGroup
            }) else { return .notFound }
            return .found(item)
        }
    }

    func addShared(account: String, data: Data) -> TabMailSessionWriteResult {
        lock.withLock {
            if let failure = nextAddFailure,
               failure.account == nil || failure.account == account {
                nextAddFailure = nil
                return .failed(failure.status)
            }
            guard !items.values.contains(where: {
                $0.account == account && $0.accessGroup == TabMailSessionStore.accessGroup
            }) else { return .failed(errSecDuplicateItem) }
            _ = insertLocked(account: account, accessGroup: TabMailSessionStore.accessGroup, data: data)
            return .success
        }
    }

    func updateShared(account: String, data: Data) -> TabMailSessionWriteResult {
        lock.withLock {
            guard let entry = items.first(where: {
                $0.value.account == account && $0.value.accessGroup == TabMailSessionStore.accessGroup
            }) else { return .notFound }
            items[entry.key] = TabMailSessionKeychainItem(
                account: account,
                accessGroup: TabMailSessionStore.accessGroup,
                accessible: kSecAttrAccessibleAfterFirstUnlock as String,
                data: data,
                persistentReference: entry.key
            )
            return .success
        }
    }

    func deleteShared(account: String) -> TabMailSessionWriteResult {
        lock.withLock {
            guard let entry = items.first(where: {
                $0.value.account == account && $0.value.accessGroup == TabMailSessionStore.accessGroup
            }) else { return .notFound }
            guard !failedDeletes.contains(entry.key) else { return .failed(errSecInteractionNotAllowed) }
            items.removeValue(forKey: entry.key)
            return .success
        }
    }

    func enumerateServiceItems() -> TabMailSessionEnumerationResult {
        lock.withLock {
            if let status = nextEnumerationFailure {
                nextEnumerationFailure = nil
                return .failed(status)
            }
            return items.isEmpty ? .notFound : .success(Array(items.values))
        }
    }

    func deletePersistentReference(_ reference: Data) -> TabMailSessionWriteResult {
        lock.withLock {
            guard items[reference] != nil else { return .notFound }
            guard !failedDeletes.contains(reference) else { return .failed(errSecInteractionNotAllowed) }
            items.removeValue(forKey: reference)
            return .success
        }
    }

    @discardableResult
    func insertHistorical(account: String, data: Data) -> Data {
        lock.withLock { insertLocked(account: account, accessGroup: nil, data: data) }
    }

    @discardableResult
    func insertShared(account: String, data: Data) -> Data {
        lock.withLock { insertLocked(account: account, accessGroup: TabMailSessionStore.accessGroup, data: data) }
    }

    func failNextSharedRead(status: OSStatus) {
        lock.withLock { nextReadFailure = status }
    }

    func failNextAdd(status: OSStatus) {
        lock.withLock { nextAddFailure = (nil, status) }
    }

    func failNextAdd(account: String, status: OSStatus) {
        lock.withLock { nextAddFailure = (account, status) }
    }

    func failNextEnumeration(status: OSStatus) {
        lock.withLock { nextEnumerationFailure = status }
    }

    func failDelete(reference: Data) {
        lock.withLock { _ = failedDeletes.insert(reference) }
    }

    func allowDelete(reference: Data) {
        lock.withLock { _ = failedDeletes.remove(reference) }
    }

    func hasAccount(_ account: String) -> Bool {
        lock.withLock { items.values.contains(where: { $0.account == account }) }
    }

    func item(account: String, accessGroup: String?) -> TabMailSessionKeychainItem? {
        lock.withLock {
            items.values.first(where: { $0.account == account && $0.accessGroup == accessGroup })
        }
    }

    func item(reference: Data) -> TabMailSessionKeychainItem? {
        lock.withLock { items[reference] }
    }

    func hasHistoricalPointer() -> Bool {
        lock.withLock {
            items.values.contains(where: {
                $0.account == TabMailSessionStore.pointerAccount && $0.accessGroup != TabMailSessionStore.accessGroup
            })
        }
    }

    func sessionNamespaceItems() -> [TabMailSessionKeychainItem] {
        lock.withLock {
            items.values.filter {
                $0.account == TabMailSessionStore.pointerAccount ||
                    $0.account.hasPrefix(TabMailSessionStore.generationPrefix)
            }
        }
    }

    func sharedPointerGeneration() -> String? {
        lock.withLock {
            guard let item = items.values.first(where: {
                $0.account == TabMailSessionStore.pointerAccount &&
                    $0.accessGroup == TabMailSessionStore.accessGroup
            }),
            let json = try? JSONSerialization.jsonObject(with: item.data) as? [String: Any] else { return nil }
            return json["generation"] as? String
        }
    }

    private func insertLocked(account: String, accessGroup: String?, data: Data) -> Data {
        nextReference += 1
        let reference = Data("ref-\(nextReference)".utf8)
        items[reference] = TabMailSessionKeychainItem(
            account: account,
            accessGroup: accessGroup,
            accessible: kSecAttrAccessibleAfterFirstUnlock as String,
            data: data,
            persistentReference: reference
        )
        return reference
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
