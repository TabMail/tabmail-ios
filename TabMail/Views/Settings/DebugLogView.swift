/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UserNotifications

struct DebugMenuView: View {
    @State private var useDevServers = BackendConfig.useDevServers
    @State private var pushTestResult: String?
    @State private var reminderTestStatus: String?
    @State private var showTouchRings = TouchVisualizer.shared.isEnabled
    @State private var demoEnterError: String?
    @Bindable private var demoStore = DemoModeStore.shared
    @State private var stuckScanStatus: String?
    @Environment(NavigationStore.self) private var navigationStore

    var body: some View {
        List {
            Section("Demo Recording") {
                Toggle("Show Touch Rings", isOn: $showTouchRings)
                    .onChange(of: showTouchRings) { _, newValue in
                        TouchVisualizer.shared.setEnabled(newValue)
                    }
                Text("Draws a ring at every touch so taps are visible in screen recordings (e.g. on a physical device with a TestFlight build).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Demo Mode") {
                if demoStore.isActive {
                    Button(role: .destructive) {
                        Task { await DemoModeService.shared.exit() }
                    } label: {
                        Label("Exit Demo Mode", systemImage: "stop.rectangle.on.rectangle")
                    }
                } else {
                    Button {
                        Task {
                            do {
                                try await DemoModeService.shared.startFromDebugMenu()
                            } catch {
                                demoEnterError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Enter Demo Mode", systemImage: "play.rectangle.on.rectangle")
                    }
                }
                if let demoEnterError {
                    Text(demoEnterError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    demoStore.resetCallBudget()
                } label: {
                    Label("Reset AI Call Limit (\(demoStore.callsConsumed)/\(DemoModeStore.totalCallBudget) used)", systemImage: "arrow.counterclockwise.circle")
                }
                Text("Demo entered here is for demo recording: no demo banner is shown, and your live account stays logged in. Demo data is namespaced (accountId 'demo-account'), real sync is paused, and everything is wiped when you exit from this menu. Your real accounts and data are untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment") {
                Toggle("Use Dev Servers", isOn: $useDevServers)
                    .onChange(of: useDevServers) { _, newValue in
                        BackendConfig.useDevServers = newValue
                        // Re-mirror backend URL to NSE shared UserDefaults
                        NSEDataBridge.mirrorBackendConfig()
                        // Reconnect Device Sync to the new server
                        DeviceSyncService.shared.forceReconnect()
                    }
                Text(useDevServers ? "dev / sync-dev / templates-dev / billing-dev" : "api / sync / templates / billing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Device Sync reconnects automatically. Other services (API, billing) take effect on next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                Button {
                    Task { await resetSyncProgress() }
                } label: {
                    Label("Reset Sync Progress", systemImage: "arrow.counterclockwise")
                }
                Text("Resets backfill cursors and completion flags for all folders. Messages are preserved — only sync progress is cleared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stuck Message Diagnostics") {
                Button {
                    Task {
                        stuckScanStatus = "Scanning…"
                        await StuckMessageDiagnostics.run()
                        stuckScanStatus = "Done — share the report below."
                    }
                } label: {
                    Label("Scan for Stuck Messages", systemImage: "stethoscope")
                }
                if let stuckScanStatus {
                    Text(stuckScanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LogShareButton(title: "Stuck Message Report", filename: "stuck_messages.txt", readLog: { AppLogStore.read(channel: .stuckDiag) }, clearLog: { AppLogStore.clear(channel: .stuckDiag) })
                Text("Read-only scan for messages that are searchable but can't open / have no snippet / aren't in their folder. Nothing is modified. Run the scan, then share the report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Push Notifications") {
                Button {
                    Task { await testPushRegistration() }
                } label: {
                    Label("Test Push Registration", systemImage: "bell.badge")
                }

                if let pushTestResult {
                    Text(pushTestResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    scheduleTestNotification()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test Reminder (5s)")
                            Text("Fires in 5 seconds — also shows in foreground")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.and.waves.left.and.right")
                            .foregroundStyle(.primary)
                    }
                }

                if let reminderTestStatus {
                    Text(reminderTestStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Consent") {
                Button {
                    UserDefaults.standard.set(false, forKey: "hasSeenAIConsent")
                } label: {
                    Label("Reset AI Consent", systemImage: "brain")
                }
                Text("EULA consent is server-side (whoami) and cannot be reset locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                LogShareButton(title: "App Logs", filename: "tabmail_logs.txt", readLog: { AppLogStore.read() }, clearLog: { AppLogStore.clear() })
                LogShareButton(title: "NSE Logs", filename: "nse_logs.txt", readLog: { NSELogStore.read() }, clearLog: { NSELogStore.clear() })

                Text("One file per process: App Logs is every main-app subsystem interleaved in the order entries were written, each entry tagged with its channel (SYNC, ERROR, AI, BACKFILL, …). NSE Logs is the notification extension's own file — a separate process with its own container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    AppLogStore.clear()
                    NSELogStore.clear()
                } label: {
                    Label("Clear All Logs", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Debug")
    }

    private func resetSyncProgress() async {
        // Delegate to resetCrawlState which handles: folder cursors, bodyEmptyConfirmed,
        // ccBccBackfillDone, backfill task cancellation + generation increment.
        await AccountManager.shared.syncEngine.resetCrawlState()
        for account in navigationStore.accounts {
            await AccountManager.shared.syncEngine.startBackfill(account: account)
        }
        print("[Debug] Sync progress reset via resetCrawlState — backfill will re-walk all folders")
    }

    private func testPushRegistration() async {
        pushTestResult = "Running..."
        pushTestResult = await PushNotificationService.shared.testFullFlow()
    }

    private func scheduleTestNotification() {
        reminderTestStatus = "Scheduling..."
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                reminderTestStatus = "Notifications denied — enable in iOS Settings"
                return
            }
            let stale = await center.pendingNotificationRequests()
            let staleIds = stale.filter { $0.identifier.hasPrefix("test_") }.map(\.identifier)
            if !staleIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIds)
            }
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = "Today at 2:00 PM \u{2014} Reply to John about project timeline"
            content.sound = .default
            content.userInfo = [
                "hash": "test_\(UUID().uuidString)",
                "messageId": "",
                "source": "kb",
            ]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(identifier: "test_\(Int(Date().timeIntervalSince1970))", content: content, trigger: trigger)
            do {
                try await center.add(request)
                reminderTestStatus = "Scheduled — fires in 5s"
                print("[ProactiveNotify] Test reminder scheduled — fires in 5s")
            } catch {
                reminderTestStatus = "Failed: \(error.localizedDescription)"
                print("[ProactiveNotify] Failed to schedule test reminder: \(error)")
            }
        }
    }
}

struct LogShareButton: View {
    let title: String
    let filename: String
    let readLog: () -> String
    let clearLog: () -> Void

    @State private var fileToShare: URL?

    var body: some View {
        Button {
            let text = readLog()
            let tmpDir = FileManager.default.temporaryDirectory
            let fileURL = tmpDir.appendingPathComponent(filename)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            fileToShare = fileURL
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .sheet(item: $fileToShare) { url in
            ActivityViewController(activityItems: [url])
                .presentationDetents([.medium, .large])
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

