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

                    // Indeterminate activity bar — the migrator doesn't expose a
                    // reliable completion fraction (cost is dominated by a few
                    // heavy passes), so an honest indeterminate bar beats a fake
                    // percentage. Can become determinate later if we count
                    // completed migration steps.
                    IndeterminateActivityBar()
                        .frame(maxWidth: 240)

                    Text("This one-time update may take a moment. Please keep TabMail open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Indeterminate linear activity bar. On iOS, `ProgressView()` with
/// `.progressViewStyle(.linear)` and no value renders a STATIC empty track
/// (UIKit has no indeterminate `UIProgressView`; only the circular style
/// animates) — which read as a frozen launch, the opposite of what the
/// migration splash exists to convey. This sweeps a segment across the track
/// so a long migration always shows visible activity.
private struct IndeterminateActivityBar: View {
    @State private var sweeping = false

    private static let barHeight: CGFloat = 4
    private static let segmentFraction: CGFloat = 0.35
    private static let sweepDuration: TimeInterval = 1.2

    var body: some View {
        GeometryReader { geo in
            let segmentWidth = geo.size.width * Self.segmentFraction
            Capsule()
                .fill(.tint)
                .frame(width: segmentWidth)
                .offset(x: sweeping ? geo.size.width : -segmentWidth)
        }
        .frame(height: Self.barHeight)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.linear(duration: Self.sweepDuration).repeatForever(autoreverses: false)) {
                sweeping = true
            }
        }
    }
}
