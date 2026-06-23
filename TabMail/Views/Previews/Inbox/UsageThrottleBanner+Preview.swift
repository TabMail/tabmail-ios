/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// Previews for the inbox usage-throttle banner (ADR-IOS-044), rendered in the
// REAL `InboxView` (seeded via `PreviewMocks`) so the canvas shows exactly how
// the banner sits above the live message list — same as the tooltip previews.
//
// `UsageThrottleStore.previewConfigure` forces the banner state, so no live
// `/whoami` throttle has to be triggered. The host below also wires the banner's
// navigation notifications, so TAPPING the banner in the canvas pushes the real
// destination page (PlanPickerView for Basic, TabMail Settings' AI Provider
// section for BYOK) — making the flow testable.

private enum ThrottlePreviewRoute: Hashable {
    case planPicker
    case aiProvider
}

/// Hosts the seeded `InboxView` in a `NavigationStack` and bridges the banner's
/// `.navigateToPlanPicker` / `.navigateToAIProvider` notifications (which in the
/// real app are handled by `MailNavigationView`) into a push — so the canvas is
/// interactive. Tips are suppressed via `PreviewMocks.hideAllTips()` at the
/// preview entry points so tooltips don't pop in on interaction.
private struct ThrottleBannerPreviewHost: View {
    let scenario: PreviewMocks.InboxScenario
    @State private var path: [ThrottlePreviewRoute] = []
    // PlanPickerView reads StoreKitManager from the environment; APIKeysView
    // doesn't need it. A fresh instance is enough for the canvas.
    @State private var storeKit = StoreKitManager()

    var body: some View {
        NavigationStack(path: $path) {
            InboxView(
                title: "All Inboxes",
                folders: [scenario.inbox],
                selection: .unified(.inbox),
                selectedMessageId: .constant(nil)
            )
            .navigationDestination(for: ThrottlePreviewRoute.self) { route in
                switch route {
                case .planPicker: PlanPickerView()
                case .aiProvider: TabMailSettingsView()
                }
            }
        }
        .environment(storeKit)
        .environment(\.hasTabMailSession, true)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPlanPicker).receive(on: DispatchQueue.main)) { _ in
            path = [.planPicker]
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAIProvider).receive(on: DispatchQueue.main)) { _ in
            // Mirror the app's handler: flag the scroll-to-AI-Provider deep link
            // so TabMailSettingsView scrolls to that section on appear.
            UserDefaults.standard.set(true, forKey: TabMailSettingsView.pendingScrollAIProviderKey)
            path = [.aiProvider]
        }
    }
}

@MainActor
private func throttledInboxPreview(planTier: String, hasOwnAPIKeys: Bool) -> some View {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    PreviewMocks.hideAllTips()
    UsageThrottleStore.shared.previewConfigure(
        planTier: planTier,
        isThrottled: true,
        hasOwnAPIKeys: hasOwnAPIKeys
    )
    return ThrottleBannerPreviewHost(scenario: scenario)
        .environment(navStore)
}

/// Basic plan, monthly budget exhausted → "Upgrade to Pro" banner.
/// Tap the banner → pushes the real `PlanPickerView`.
#Preview("Throttle banner — Basic (upgrade to Pro)") {
    throttledInboxPreview(planTier: "Basic", hasOwnAPIKeys: false)
}

/// BYOK plan with no own key (slow shared queue) → "Set up API keys" banner.
/// Tap the banner → pushes TabMail Settings, scrolled to the AI Provider
/// section (provider pickers + Manage API Keys).
#Preview("Throttle banner — BYOK (set up API keys)") {
    throttledInboxPreview(planTier: "BYOK", hasOwnAPIKeys: false)
}
#endif
