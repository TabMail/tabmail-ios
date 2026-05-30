/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

#Preview("iCloudSetup – icloud.com") {
    AddAccountICloudView(detectedEmail: "alex@icloud.com")
}

#Preview("iCloudSetup – me.com") {
    AddAccountICloudView(detectedEmail: "first.last@me.com")
}

#Preview("iCloudSetup – Apple private relay") {
    // Apple's anonymous relay addresses look like
    // <random>@privaterelay.appleid.com — the view detects this and
    // does NOT pre-fill the field, so the user has to type their real
    // Apple ID.
    AddAccountICloudView(
        detectedEmail: "abc12345@privaterelay.appleid.com"
    )
}

#Preview("iCloudSetup – Dark") {
    AddAccountICloudView(detectedEmail: "alex@icloud.com")
        .preferredColorScheme(.dark)
}
#endif
