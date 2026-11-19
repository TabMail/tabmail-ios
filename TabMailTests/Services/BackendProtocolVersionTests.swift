/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The backend picks each tool description and the agent's system prompt by `X-Client-Version`,
/// the protocol version, serving the highest file at or below it. So the version the app
/// advertises decides which texts the assistant reads, and every one of them must describe what
/// this app does.
///
/// At 2.0.0 the backend answers the summary and the precache reply as JSON with their text
/// messages, and the assistant is served the calendar texts up to 1.11.x: `calendar_event_create`
/// v1.11.5 (a repeat rule's `until` is a plain date, the series' last day, which the Outlook writer
/// dates in the event's zone; an all-day end is the day after the last day),
/// `calendar_event_edit` v1.11.2 and `calendar_event_delete` v1.11.4, with
/// `system_prompt_agent-v1.10.3`. Before the chat view the app was pinned at 1.10.3. The version
/// is pinned exactly: raising it is a deliberate change that checks the texts it newly serves first.
@Suite("Backend protocol version")
struct BackendProtocolVersionTests {
    @Test("the app advertises exactly the protocol version whose texts it implements")
    func advertisesExactProtocolVersion() {
        #expect(BackendClient.clientVersion == "2.0.0")
    }
}
