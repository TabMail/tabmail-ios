/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

#Preview("AI enabled") {
    DemoBanner(aiEnabled: true)
        .background(Color.gray.opacity(0.2))
}

#Preview("AI disabled") {
    DemoBanner(aiEnabled: false)
        .background(Color.gray.opacity(0.2))
}
#endif
