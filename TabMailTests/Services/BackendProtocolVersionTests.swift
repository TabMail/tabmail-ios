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
/// At 1.10.3 the assistant is served `calendar_event_delete-v1.10.3` (`delete_scope`
/// `this_only` / `this_and_following` / `all`, `recurrence_id` read in the user's own zone),
/// `calendar_event_edit-v1.10.3` and `system_prompt_agent-v1.10.3`. Higher versions of these
/// texts exist (1.11.x) and describe behaviour this app has not been checked against, so the
/// version is pinned exactly: raising it is a deliberate change that checks those texts first.
@Suite("Backend protocol version")
struct BackendProtocolVersionTests {
    @Test("the app advertises exactly the protocol version whose texts it implements")
    func advertisesExactProtocolVersion() {
        #expect(BackendClient.clientVersion == "1.10.3")
    }
}
