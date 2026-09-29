/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// A running server tool shows the backend's own label, as Thunderbird's chat does (ADR-IOS-008):
/// the backend now sends the tool's name in production too, and that name must not replace the
/// richer label it sends beside it ("Searching the web: <query>").
@Suite("Tool status label")
@MainActor
struct ToolStatusLabelTests {

    private func status(label: String?, name: String?) -> ToolStatusEvent {
        ToolStatusEvent(execution_id: "execution-1", call_id: "call-1", display_label: label, tool_name: name,
                        success: nil, elapsed_ms: nil, error: nil, result: nil)
    }

    @Test("the backend's label wins over the tool's name")
    func backendLabelWins() {
        #expect(DynamicIslandChat.toolStatusLabel(status(label: "Searching the web: launch plan", name: "search_web"))
                == "Searching the web: launch plan")
        #expect(DynamicIslandChat.toolStatusLabel(status(label: "Checking day of week…", name: "date_to_day"))
                == "Checking day of week…")
    }

    @Test("without a label, the tool's name, and without either, a generic label")
    func fallbacks() {
        #expect(DynamicIslandChat.toolStatusLabel(status(label: nil, name: "search_web")) == "search_web")
        #expect(DynamicIslandChat.toolStatusLabel(status(label: nil, name: nil)) == "Processing")
    }
}
