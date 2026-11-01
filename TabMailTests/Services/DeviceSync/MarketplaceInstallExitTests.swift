/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The install tap's task ends in one of three ways, and only a save is reported as installed: a failed download is a
/// failed task with both stores unchanged, and a template that was installed while the download waited is kept exactly
/// once. Each runs in the real and the demo mode, with a fresh install as the control.
@MainActor
@Suite("Marketplace install: failed download and overlapping install", .serialized, .processGlobalState)
struct MarketplaceInstallExitTests {
    private enum Failure: Error, Equatable { case offline }
    private let store = PromptStore.shared
    private let id = "marketplace-exit-test"

    private func downloaded() -> TemplateMarketplaceClient.DownloadedTemplate {
        .init(id: id, name: "Install test", instructions: ["Be brief"], exampleReply: "Thanks", enabled: true)
    }

    private func inMode(_ demo: Bool, _ body: () async throws -> Void) async throws {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        let saved = store.templates
        if demo { try await store.enterDemo() }
        store.applySyncedTemplates([])
        do {
            try await body()
        } catch {
            if DemoModeStore.isDemoActive { try await store.leaveDemo() }
            store.applySyncedTemplates(saved)
            throw error
        }
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        store.applySyncedTemplates(saved)
    }

    private func stored() -> [String: Data] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: ["user_templates", "demo.user_templates"].compactMap { key in
            defaults.data(forKey: key).map { (key, $0) }
        })
    }

    @Test("A download failure is a failed install with both stores unchanged; a later successful download installs", arguments: [true, false])
    func failedDownloadNeverReportsInstalled(demo: Bool) async throws {
        try await inMode(demo) {
            let before = stored()
            let pending = store.beginMarketplaceInstall(id: id, download: { _ in throw Failure.offline })
            switch await pending.result {
            case .failure(let error): #expect(error as? Failure == .offline)
            case .success(let outcome): Issue.record("A failed download reported success: \(outcome)")
            }
            #expect(stored() == before, "A failed download must save nothing in either store")
            #expect(!store.visibleTemplates.contains { $0.id == id })
            let control = try await store.beginMarketplaceInstall(id: id, download: { _ in downloaded() }).value
            #expect(control == .installed(id))
            #expect(store.visibleTemplates.filter { $0.id == id }.count == 1)
        }
    }

    private actor DownloadPause {
        private var arrived = false
        private var onArrival: CheckedContinuation<Void, Never>?
        private var onResume: CheckedContinuation<Void, Never>?
        func waitForArrival() async {
            if arrived { return }
            await withCheckedContinuation { onArrival = $0 }
        }
        func stopDownload() async {
            arrived = true
            onArrival?.resume()
            onArrival = nil
            await withCheckedContinuation { onResume = $0 }
        }
        func resumeDownload() {
            onResume?.resume()
            onResume = nil
        }
    }

    @Test("A template installed while a download waits is kept exactly once and the completed download saves nothing", arguments: [true, false])
    func repeatedInstallDoesNotDuplicate(demo: Bool) async throws {
        try await inMode(demo) {
            let first = try await store.beginMarketplaceInstall(id: id, download: { _ in downloaded() }).value
            #expect(first == .installed(id), "A fresh download is the success control")
            store.applySyncedTemplates([])
            let pause = DownloadPause()
            let pending = store.beginMarketplaceInstall(id: id, download: { _ in
                await pause.stopDownload()
                return downloaded()
            })
            await pause.waitForArrival()
            let otherInstall = ReplyTemplate(id: id, name: "Installed while the download waited", enabled: true,
                instructions: ["Keep the installed copy"], exampleReply: "Keep this reply")
            #expect(store.addTemplate(otherInstall), "The competing installation is the stored-row writer")
            let before = stored()
            await pause.resumeDownload()
            let second = try await pending.value
            #expect(second == .alreadyInstalled(id))
            #expect(stored() == before, "The completed download must not rewrite either store")
            let key = demo ? "demo.user_templates" : "user_templates"
            let data = try #require(UserDefaults.standard.data(forKey: key))
            let templates = try JSONDecoder().decode([ReplyTemplate].self, from: data)
            let matching = templates.filter { $0.id == id && !$0.deleted }
            #expect(matching.count == 1)
            #expect(matching.first?.name == otherInstall.name)
        }
    }
}
