/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Demo Mode Account Settings page (replaces `AccountDashboardView` for the
/// duration of the demo session).
///
/// Shows: demo email, calls remaining (large), AI on/off toggle, "Exit demo"
/// button. Hides: edit / sign out / wipe / billing / push consent / web
/// search toggle. Other Settings sub-pages (Prompts, Templates, AI Settings)
/// continue to work normally so users see the full feature surface.
struct DemoAccountDashboardView: View {
    @Bindable private var store = DemoModeStore.shared
    @State private var showExitConfirm = false
    @State private var showAIConsent = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Email") {
                    Text(DemoSeed.demoEmail)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Plan") {
                    HStack(spacing: 6) {
                        Text("DEMO")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        Text("Sample data, no network")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Demo Account")
            }

            // AI Calls budget
            Section {
                VStack(alignment: .center, spacing: 12) {
                    Text("\(store.callsRemaining)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(store.callsRemaining == 0 ? .red : .primary)
                    Text("of \(DemoModeStore.totalCallBudget) AI calls remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(store.callsRemaining), total: Double(DemoModeStore.totalCallBudget))
                        .tint(store.callsRemaining == 0 ? .red : .accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Text("AI Budget")
            } footer: {
                if store.callsRemaining == 0 {
                    Text("Sign up for your own account to keep using AI features.")
                        .foregroundStyle(.red)
                } else {
                    Text("Each agent chat or compose-edit consumes one call. Pre-baked summaries don't count.")
                }
            }

            // AI status toggle
            Section {
                if store.aiEnabled {
                    LabeledContent("AI features") {
                        Text("Enabled")
                            .foregroundStyle(.green)
                    }
                    Button {
                        store.aiEnabled = false
                    } label: {
                        Label("Disable AI for this demo", systemImage: "xmark.circle")
                    }
                } else {
                    LabeledContent("AI features") {
                        Text("Disabled")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showAIConsent = true
                    } label: {
                        Label("Enable AI", systemImage: "sparkles")
                    }
                }
            } header: {
                Text("AI Settings")
            }

            Section {
                Text("You're trying TabMail with sample data. None of these emails are real. AI features use a shared demo budget.\n\nSign up to get your own account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About this demo")
            }

            Section {
                Button(role: .destructive) {
                    showExitConfirm = true
                } label: {
                    Label("Exit demo", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Demo")
        .confirmationDialog("Exit demo mode?", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Exit demo", role: .destructive) {
                Task { await DemoModeService.shared.exit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your demo conversations and edits will be discarded.")
        }
        .sheet(isPresented: $showAIConsent) {
            NavigationStack {
                AIConsentView { aiEnabled in
                    store.aiEnabled = aiEnabled
                    showAIConsent = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DemoAccountDashboardView()
    }
}
