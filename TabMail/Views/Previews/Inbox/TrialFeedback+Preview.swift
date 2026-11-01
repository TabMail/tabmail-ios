/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

private struct PreviewFeedbackClient: TrialFeedbackSubmitting {
    func submit(reason: TrialFeedbackReason) async throws { }
}

@MainActor
private struct TrialFeedbackPreview: View {
    private let flow: TrialFeedbackFlow
    init() {
        let defaults = UserDefaults(suiteName: "TrialFeedbackPreview")!
        flow = TrialFeedbackFlow(prompt: TrialFeedbackPromptState(defaults: defaults), client: PreviewFeedbackClient())
    }
    var body: some View { TrialFeedbackForm(flow: flow) }
}

#Preview("Optional feedback — no network") { TrialFeedbackPreview() }
#Preview("Optional feedback — dark, larger text") {
    TrialFeedbackPreview().preferredColorScheme(.dark).dynamicTypeSize(.accessibility3)
}
#endif
