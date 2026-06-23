/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Brief splash shown after the demo consent gates pass while the seeding
/// pipeline runs (account, folders, messages, FTS, calendar). Blocks UI for
/// <2s on a real device (acceptance target).
struct DemoSeedingSplash: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Setting up demo…")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Preparing sample messages, calendar, and contacts.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
