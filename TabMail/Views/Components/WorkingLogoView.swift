/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// A logo view that switches between static icon and glowing wand when AI is working.
struct TabMailLogoView: View {
    let isWorking: Bool
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if isWorking {
            ChatPillWandIcon(isWorking: true, size: size * 0.7)
                .frame(width: size, height: size)
        } else {
            Image("TabMailIcon")
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Magic wand icon for the chat pill. Pulses with a glow when AI is working.
struct ChatPillWandIcon: View {
    let isWorking: Bool
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isWorking)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let pulse = isWorking ? (sin(seconds * 2.5) + 1) / 2 : 0  // 0…1

            // Layer two icons: primary fades out as accent fades in
            ZStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.primary)
                    .opacity(1.0 - pulse)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(Palette.accentColor)
                    .opacity(pulse)
            }
            .shadow(color: Palette.accentColor.opacity(pulse * 0.6), radius: pulse * 8)
        }
    }
}

#Preview("Logo States") {
    ScrollView {
        VStack(spacing: 30) {
            // Splash
            VStack(spacing: 16) {
                Text("Splash").font(.caption).foregroundStyle(.secondary)
                Image("TabMailLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                Text("Tap, Talk, Send")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Static vs Working
            VStack(spacing: 16) {
                Text("Static vs Working").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    ChatPillWandIcon(isWorking: false, size: 24)
                    ChatPillWandIcon(isWorking: true, size: 24)
                }
                .padding()
                .background(Palette.buttonBg)
                .clipShape(Capsule())
            }
        }
        .padding(40)
    }
}
