/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("TabMailLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .padding(.horizontal, 20)

            Text("Tap, Talk, Send")
                .font(.title2)
                .foregroundStyle(.secondary)

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Splash") {
    SplashView()
}
