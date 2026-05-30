/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Persistent bottom banner shown while Demo Mode is active.
/// Tap → confirmation dialog → exit demo.
struct DemoBanner: View {
    let aiEnabled: Bool

    @Bindable private var store = DemoModeStore.shared
    @State private var showExitConfirm = false
    @State private var callsRemaining: Int = DemoModeStore.shared.callsRemaining

    var body: some View {
        statusText
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            // Tight band: just enough top padding to keep the text legible
            // against the colored fill, while the negative bottom padding
            // pushes the whole band into the bottom safe area. Net effect:
            // the band's top edge sits low so it doesn't crowd controls
            // (chat send, etc.) above it.
            .padding(.top, 4)
            // Slightly negative so the band still hugs the bottom safe area,
            // but stays above the home-indicator gesture zone — iOS otherwise
            // intercepts taps on content sitting at the very bottom edge.
            .padding(.bottom, -4)
            .background(bannerColor)
            .contentShape(Rectangle())
            .onTapGesture { showExitConfirm = true }
        .confirmationDialog("Exit demo mode?", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Exit demo", role: .destructive) {
                Task { await DemoModeService.shared.exit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your demo conversations and edits will be discarded.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoCallsRemainingChanged)) { _ in
            callsRemaining = store.callsRemaining
        }
        .onChange(of: store.callsConsumed) { _, _ in
            callsRemaining = store.callsRemaining
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if !aiEnabled {
            Text("DEMO • AI disabled • Tap to exit")
        } else if callsRemaining == 0 {
            Text("DEMO • AI call limit reached • Tap to exit")
        } else {
            Text("DEMO • \(callsRemaining) AI calls left • Tap to exit")
        }
    }

    private var bannerColor: Color {
        if aiEnabled && callsRemaining == 0 {
            return Color.red.opacity(0.85)
        }
        return Color.accentColor.opacity(0.92)
    }
}

#Preview("AI enabled") {
    DemoBanner(aiEnabled: true)
        .background(Color.gray.opacity(0.2))
}

#Preview("AI disabled") {
    DemoBanner(aiEnabled: false)
        .background(Color.gray.opacity(0.2))
}
