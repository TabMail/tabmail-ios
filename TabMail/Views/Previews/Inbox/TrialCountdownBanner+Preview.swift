/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

@MainActor
private struct TrialReminderPreview: View {
    private let scenario: PreviewMocks.InboxScenario
    private let navigation: NavigationStore
    @State private var plansPresented = false
    @State private var storeKit = StoreKitManager()

    init() {
        scenario = PreviewMocks.seedInbox()
        navigation = PreviewMocks.navigationStore()
        PreviewMocks.hideAllTips()
        let end = Int(Date().addingTimeInterval(3 * AccountPlanConfig.secondsPerDay).timeIntervalSince1970)
        let json: [String: Any] = ["logged_in": true, "has_subscription": true, "plan_tier": "Trial",
            "subscription_provider": "signup", "trial": ["is_trial": true, "trial_end": end]]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let info = try? JSONDecoder().decode(AccountInfo.self, from: data) {
            AISubscriptionGate.shared.apply(info)
        }
    }

    var body: some View {
        NavigationStack {
            InboxView(title: "All Inboxes", folders: [scenario.inbox], selection: .unified(.inbox),
                      selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
                .navigationDestination(isPresented: $plansPresented) { PlanPickerView() }
        }
        .environment(navigation)
        .environment(storeKit)
        .environment(\.hasTabMailSession, true)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPlanPicker)) { _ in
            plansPresented = true
        }
    }
}

#Preview("Trial reminder in the real inbox") {
    TrialReminderPreview()
}

#Preview("Trial reminder — dark, larger text") {
    TrialReminderPreview()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
