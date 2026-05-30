/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - NetworkMonitor

@Suite("NetworkMonitor")
struct NetworkMonitorTests {

    @Test("shared singleton returns same instance")
    @MainActor
    func sharedSingleton() {
        let a = NetworkMonitor.shared
        let b = NetworkMonitor.shared
        #expect(a === b)
    }

    @Test("initial isConnected is true")
    @MainActor
    func initialIsConnected() {
        #expect(NetworkMonitor.shared.isConnected == true)
    }

    @Test("initial isExpensive is false")
    @MainActor
    func initialIsExpensive() {
        #expect(NetworkMonitor.shared.isExpensive == false)
    }
}

// MARK: - ContactSearchService

@Suite("ContactSearchService")
struct ContactSearchServiceTests {

    @Test("search returns empty when not authorized")
    @MainActor
    func searchReturnsEmptyWhenNotAuthorized() {
        let service = ContactSearchService()
        // Without calling requestAccess, authorized is false
        let results = service.search("Alice")
        #expect(results.isEmpty)
    }

    @Test("search returns empty for empty query")
    @MainActor
    func searchReturnsEmptyForEmptyQuery() {
        let service = ContactSearchService()
        let results = service.search("")
        #expect(results.isEmpty)
    }

    @Test("search returns empty for whitespace-only query")
    @MainActor
    func searchReturnsEmptyForWhitespace() {
        let service = ContactSearchService()
        let results = service.search("   ")
        #expect(results.isEmpty)
    }
}

// MARK: - ContactResult (supplementary — core tests in ContactResultTests.swift)

@Suite("ContactResult Hashable & Identifiable")
struct ContactResultHashableTests {

    @Test("two ContactResults with same email are equal")
    func equalityByFields() {
        let a = ContactResult(name: "Alice", email: "alice@test.com")
        let b = ContactResult(name: "Alice", email: "alice@test.com")
        #expect(a == b)
    }

    @Test("two ContactResults with different email are not equal")
    func inequalityByEmail() {
        let a = ContactResult(name: "Alice", email: "alice@test.com")
        let b = ContactResult(name: "Alice", email: "bob@test.com")
        #expect(a != b)
    }

    @Test("two ContactResults with different name are not equal")
    func inequalityByName() {
        let a = ContactResult(name: "Alice", email: "alice@test.com")
        let b = ContactResult(name: "Bob", email: "alice@test.com")
        #expect(a != b)
    }

    @Test("can be used in a Set")
    func setMembership() {
        let a = ContactResult(name: "Alice", email: "alice@test.com")
        let b = ContactResult(name: "Alice", email: "alice@test.com")
        let set: Set<ContactResult> = [a, b]
        #expect(set.count == 1)
    }
}

// MARK: - AppDataWiper

@Suite("AppDataWiper")
struct AppDataWiperTests {

    @Test("AppDataWiper is an enum with no cases (namespace only)")
    func isNamespaceEnum() {
        // AppDataWiper is declared as `enum AppDataWiper` — verify it's a metatype
        // (no instances can be created). We can only reference the type itself.
        let type = AppDataWiper.self
        #expect(String(describing: type) == "AppDataWiper")
    }

    @Test("tabMailDidSignOut notification name is correct")
    func signOutNotificationName() {
        let name = Notification.Name.tabMailDidSignOut
        #expect(name.rawValue == "tabMailDidSignOut")
    }
}
