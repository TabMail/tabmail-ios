/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

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
#endif
