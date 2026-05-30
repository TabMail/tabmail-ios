/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Simplified sync view — auto-sync replaces manual send/receive.
/// Kept for backward compatibility but no longer navigated to from TabMailSettingsView.
struct DeviceSyncView: View {
    @State private var syncService = DeviceSyncService.shared

    var body: some View {
        Form {
            Group {
            Section {
                Toggle(isOn: Binding(
                    get: { syncService.isAutoEnabled },
                    set: { syncService.isAutoEnabled = $0 }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Sync")
                            Group {
                                if !syncService.isAutoEnabled {
                                    Text("Auto-sync disabled")
                                } else if syncService.isConnecting {
                                    Text("Connecting...")
                                } else if syncService.isConnected {
                                    Text("Connected — syncing automatically")
                                } else {
                                    Text("Disconnected — will retry")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        if syncService.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: syncService.isConnected ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                                .foregroundStyle(syncService.isConnected ? .green : .secondary)
                        }
                    }
                }
            }

            Section {
                Text("When enabled, prompts, action rules, knowledge base, and templates sync automatically between **your own** TabMail devices. Nothing is shared with anyone else or stored on the server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .animation(.easeInOut(duration: 0.3), value: syncService.isConnected)
        .animation(.easeInOut(duration: 0.2), value: syncService.isConnecting)
        .navigationTitle("Sync with Your Other Devices")
        .navigationBarTitleDisplayMode(.inline)
    }
}
