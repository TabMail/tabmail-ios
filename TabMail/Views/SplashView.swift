/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct SplashView: View {
    /// Visual variant. `.loading` is the normal returning-user splash;
    /// `.migrating` is shown while a one-time database migration runs behind a
    /// gating splash (RC2 fix, PLAN_HANG_FIX) — adds a progress bar and a
    /// "keep the app open" notice so a long migration reads as honest progress
    /// instead of a frozen launch.
    enum Mode {
        case loading
        case migrating
    }

    var mode: Mode = .loading

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("TabMailLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .padding(.horizontal, 20)

            switch mode {
            case .loading:
                Text("Tap, Talk, Send")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 8)

            case .migrating:
                VStack(spacing: 12) {
                    Text("Updating database…")
                        .font(.title3.weight(.semibold))

                    // Indeterminate linear bar — the migrator doesn't expose a
                    // reliable completion fraction (cost is dominated by a few
                    // heavy passes), so an honest indeterminate bar beats a fake
                    // percentage. Can become determinate later if we count
                    // completed migration steps.
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)

                    Text("This one-time update may take a moment.\nPlease keep TabMail open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Splash") {
    SplashView()
}

#Preview("Migration Splash") {
    SplashView(mode: .migrating)
}
