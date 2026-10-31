/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// Every read of the live demo flag in the prompt and reminder write paths, by file and line. A writer takes its
/// target (demo or real) as it starts, before its first suspension, and carries it as an argument (DS-DEMO); a
/// read anywhere else is a late sample that can send a started operation to the other target. This lexical
/// fence reads the sources at run time, so a new read fails here until it is reviewed and listed with its reason.
@Suite("Demo flag read sites in the prompt and reminder write paths")
struct DemoFlagReadSitesTests {
    private static let allowed: [String: [String]] = [
        "TabMail/Services/PromptStore.swift": [
            // Validity of an access made for the demo: refused once the demo ended. Not a choice of target.
            "guard hold.isHolder, !demo || DemoModeStore.isDemoActive else { throw PromptRefusal.changed }",
            // Synchronous: no Device Sync broadcast or history for a templates change made while the demo shows its own.
            "guard !DemoModeStore.isDemoActive else { return }",
            // Display: the demo shows the overlay's bullets without labels.
            "if DemoModeStore.isDemoActive { return bullets(section).map { ShownBullet(text: $0, labels: []) } }",
            // Synchronous, after a commit: the demo shows its overlay, and the real text is shown again on exit.
            "guard !DemoModeStore.isDemoActive else { return }",
            // Gesture creation: the target is taken as the gesture is made, before its task first runs.
            "let demo = DemoModeStore.isDemoActive",
            // AI read: the capture it returns carries the target from then on.
            "return try await withPromptStore(label, demo: DemoModeStore.isDemoActive) { access in",
            // Validity of a demo capture's commit: dropped once the demo ended, its overlay being discarded.
            "guard DemoModeStore.isDemoActive else {",
            // Storage routing for the synchronous snapshot readers (display).
            "DemoModeStore.isDemoActive ? \"demo.\\(base)\" : base",
            // Synchronous reset handler, taken as the handler runs.
            "if DemoModeStore.isDemoActive { templates = Defaults.templates; return }",
            // Synchronous: while the demo shows its own templates a received set is saved to the real key only.
            "guard !DemoModeStore.isDemoActive else {",
            "assert(DemoModeStore.isDemoActive, \"enterDemoOverlay requires demo active\")",
            "assert(DemoModeStore.isDemoActive, \"exitDemoOverlay requires demo still active\")",
        ],
        "TabMail/Services/AI/DisabledRemindersStore.swift": [
            // Each takes the demo map or the real one at the start of one synchronous whole-map transaction.
            "getDisabledMap(key: keyV2(demo: DemoModeStore.isDemoActive))",
            "let demo = DemoModeStore.isDemoActive  // captured once — see getDisabledMap(key:)",
            "let key = keyV2(demo: DemoModeStore.isDemoActive)  // captured once — see getDisabledMap(key:)",
            "let key = keyV2(demo: DemoModeStore.isDemoActive)  // captured once — see getDisabledMap(key:)",
            "let key = keyV2(demo: DemoModeStore.isDemoActive)  // captured once — see getDisabledMap(key:)",
        ],
        // The model's tools take the target on their first line, before the call's first suspension.
        "TabMail/Services/AI/Tools/KBAddTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/KBDelTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/ReminderAddTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/ReminderDelTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/DeviceSyncService.swift": [
            // Receive: demo never syncs (DS-DEMO); each is read as a message arrives, before it waits in line.
            "if !DemoModeStore.isDemoActive {",
            "if !DemoModeStore.isDemoActive { receiveBulletState(object) }",
            "guard !DemoModeStore.isDemoActive else { break }",
            "guard !DemoModeStore.isDemoActive else {",
        ],
        // The history view takes the target as it starts loading.
        "TabMail/Views/Settings/PromptHistoryView.swift": [
            "entries = try await PromptStore.shared.withPromptStore(\"load prompt history\", demo: DemoModeStore.isDemoActive) { try $0.loadHistory() }",
        ],
        // The refine queue defers every drain while the demo runs.
        "TabMail/Services/AI/BackfillAIQueue.swift": ["guard DemoModeStore.isDemoActive == false else {"],
        // The files that write through the store carry a target and read the flag nowhere.
        "TabMail/Services/AI/KBRefinementService.swift": [],
        "TabMail/Services/AI/AIPromptLearning.swift": [],
        "TabMail/Views/Settings/RemindersSettingsView.swift": [],
        "TabMail/Views/Settings/BulletListEditor.swift": [],
        "TabMail/Services/AI/ReminderBuilder.swift": [],
    ]

    @Test("The live demo flag is read only at the listed sites")
    func readsAreAtTheListedSites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (path, expected) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let found = source.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("DemoModeStore.isDemoActive") && !$0.hasPrefix("//") }
            #expect(found == expected, "\(path): the reads of the live demo flag changed; a writer takes its target as it starts")
        }
    }
}
