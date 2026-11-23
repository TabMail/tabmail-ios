import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Sync timing promises 4, 5 and 6 at the screen (#1331, #1327). Foreground polling
/// (`SyncScheduler.startForegroundPolling`: a return's stage 1, the 300 s poll timer
/// and IMAP IDLE) starts as soon as the scene is active with an account. That holds
/// for a view that mounts in an already active scene (a foreground cold launch) and
/// for the first account added while the app is open, with no phase change.
///
/// Each test hosts the production `ForegroundPollStart` in a window of its own, and
/// drives the scene phase, the account count and screenshot mode itself. The start
/// records instead of syncing. Nothing else in the run (other suites, the app's own
/// sync, the real scene's state) can change a result.
@MainActor
@Suite("Foreground polling starts for the scene and the accounts it has", .serialized)
struct ForegroundPollStartTests {

    @MainActor @Observable
    final class PollState {
        var phase: ScenePhase
        var accounts: Int
        var screenshotMode: Bool
        /// Changed only to make the view render again.
        var unrelated = 0
        private(set) var starts = 0

        init(phase: ScenePhase, accounts: Int, screenshotMode: Bool = false) {
            self.phase = phase
            self.accounts = accounts
            self.screenshotMode = screenshotMode
        }

        func recordStart() { starts += 1 }
    }

    private struct Probe: View {
        let state: PollState

        var body: some View {
            Text("accounts \(state.accounts), render \(state.unrelated)")
                .modifier(ForegroundPollStart(
                    hasAccounts: state.accounts > 0,
                    screenshotMode: state.screenshotMode,
                    start: { state.recordStart() }
                ))
                .environment(\.scenePhase, state.phase)
        }
    }

    // MARK: - The two cases the fix is for

    @Test("A view that mounts in an active scene with an account starts polling once, with no phase change")
    func mountInAnActiveSceneStartsOnce() async throws {
        let state = PollState(phase: .active, accounts: 1)
        let window = try Self.host(state)
        defer { Self.close(window) }

        let started = await eventually { state.starts == 1 }
        #expect(started, "the poll starts at mount, as on a foreground cold launch (#1331)")

        state.unrelated += 1
        await settle()
        #expect(state.starts == 1, "a later render starts nothing more")
    }

    @Test("The first account added in an active scene starts polling once")
    func firstAccountInAnActiveSceneStartsOnce() async throws {
        let state = PollState(phase: .active, accounts: 0)
        let window = try Self.host(state)
        defer { Self.close(window) }

        await settle()
        #expect(state.starts == 0, "no account, no poll")

        state.accounts = 1
        let started = await eventually { state.starts == 1 }
        #expect(started, "the first account starts the poll with no phase change (#1327)")

        state.accounts = 2
        await settle()
        #expect(state.starts == 1, "a second account starts nothing more")
    }

    // MARK: - The returns keep the old handler's starts

    @Test("A view that mounts before the scene is active starts polling when it becomes active",
          arguments: [ScenePhase.inactive, .background])
    func mountBeforeActiveStartsOnActive(phase: ScenePhase) async throws {
        let state = PollState(phase: phase, accounts: 1)
        let window = try Self.host(state)
        defer { Self.close(window) }

        await settle()
        #expect(state.starts == 0, "not active yet")

        state.phase = .active
        let started = await eventually { state.starts == 1 }
        #expect(started, "becoming active starts the poll")
    }

    @Test("Every change to active starts polling again, from inactive as from the background")
    func everyReturnStartsAgain() async throws {
        let state = PollState(phase: .active, accounts: 1)
        let window = try Self.host(state)
        defer { Self.close(window) }
        let atMount = await eventually { state.starts == 1 }
        try #require(atMount)

        // Control Center or a system alert over the app: inactive, then active.
        state.phase = .inactive
        await settle()
        #expect(state.starts == 1, "inactive starts nothing")
        state.phase = .active
        let afterBlip = await eventually { state.starts == 2 }
        #expect(afterBlip, "active again starts the poll, as the scene-phase handler did")

        // A return from the background passes through inactive.
        state.phase = .inactive
        state.phase = .background
        await settle()
        #expect(state.starts == 2, "the background starts nothing")
        state.phase = .inactive
        state.phase = .active
        let afterReturn = await eventually { state.starts == 3 }
        #expect(afterReturn, "a return starts the poll")
    }

    @Test("Removing the last account and adding one again starts polling again")
    func accountAfterTheLastWasRemovedStartsAgain() async throws {
        let state = PollState(phase: .active, accounts: 1)
        let window = try Self.host(state)
        defer { Self.close(window) }
        let atMount = await eventually { state.starts == 1 }
        try #require(atMount)

        state.accounts = 0
        await settle()
        #expect(state.starts == 1, "removing the last account starts nothing")

        state.accounts = 1
        let started = await eventually { state.starts == 2 }
        #expect(started, "an account added after that starts the poll, as a first account does")
    }

    @Test("Screenshot mode never starts polling")
    func screenshotModeNeverStarts() async throws {
        let state = PollState(phase: .active, accounts: 1, screenshotMode: true)
        let window = try Self.host(state)
        defer { Self.close(window) }

        await settle()
        #expect(state.starts == 0, "not at mount")

        state.phase = .background
        await settle()
        state.phase = .active
        await settle()
        #expect(state.starts == 0, "not on a return")

        state.accounts = 2
        await settle()
        #expect(state.starts == 0, "not on an added account")
    }

    // MARK: - The condition and its one place

    @Test("Polling is wanted exactly when the scene is active, an account exists and it is not screenshot mode")
    func condition() {
        for phase in [ScenePhase.active, .inactive, .background] {
            for hasAccounts in [false, true] {
                for screenshotMode in [false, true] {
                    let wanted = ForegroundPollStart.wanted(
                        phase: phase, hasAccounts: hasAccounts, screenshotMode: screenshotMode)
                    let expected = phase == .active && hasAccounts && !screenshotMode
                    #expect(wanted == expected,
                            "phase \(String(describing: phase)), accounts \(hasAccounts), screenshot \(screenshotMode)")
                }
            }
        }
    }

    @Test("RootView starts foreground polling only through ForegroundPollStart, with the app's own inputs")
    func rootViewStartsThePollInOnePlace() throws {
        let root = try Self.source("TabMail/Views/RootView.swift")
        #expect(root.contains(
            ".modifier(ForegroundPollStart( hasAccounts: !navigationStore.accounts.isEmpty, "
            + "screenshotMode: ScreenshotMode.isActive, start: { syncScheduler.startForegroundPolling() } ))"),
            "RootView applies the modifier with its account list, screenshot mode and the scheduler's start")
        #expect(root.components(separatedBy: ".startForegroundPolling()").count - 1 == 1,
                "RootView calls startForegroundPolling in one place")

        // App-wide, the only other caller is Settings' database reset.
        var callers: [String: Int] = [:]
        let appRoot = Self.projectRoot.appendingPathComponent("TabMail")
        let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let calls = text.components(separatedBy: ".startForegroundPolling()").count - 1
            if calls > 0 { callers[url.lastPathComponent] = calls }
        }
        #expect(callers == ["RootView.swift": 1, "SettingsView.swift": 1], "callers: \(callers)")
    }

    // MARK: - Helpers

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The file with every run of whitespace made one space.
    private static func source(_ path: String) throws -> String {
        let raw = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func host(_ state: PollState) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "a window scene to host the probe")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.rootViewController = UIHostingController(rootView: Probe(state: state))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Long enough for SwiftUI to apply a state change to the hosted view.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func eventually(seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
