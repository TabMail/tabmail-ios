/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// Preview gallery for the agent chat bubbles — warning vs agent vs user roles.
#Preview("Warning Bubble") {
    VStack(spacing: 12) {
        ChatBubble(message: ChatMessage(
            role: .warning,
            content: "Active subscription required. Go to TabMail Account to subscribe.",
            timestamp: Date()
        ))
        ChatBubble(message: ChatMessage(
            role: .agent,
            content: "Here's a normal agent message for comparison.",
            timestamp: Date()
        ))
        ChatBubble(message: ChatMessage(
            role: .user,
            content: "Test 123",
            timestamp: Date()
        ))
    }
    .padding()
}
#endif
