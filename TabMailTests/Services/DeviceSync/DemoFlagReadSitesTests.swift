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
            "assert(DemoModeStore.isDemoActive, \"enterDemoOverlay requires demo active\")",
            "assert(DemoModeStore.isDemoActive, \"exitDemoOverlay requires demo still active\")",
        ],
        "TabMail/Services/AI/DisabledRemindersStore.swift": [
            // Validity of a demo-targeted write, inside the map lock: refused once the demo ended. Not a choice of map.
            "!demo || DemoModeStore.isDemoActive",
        ],
        // The model's tools take the target on their first line, before the call's first suspension.
        "TabMail/Services/AI/Tools/KBAddTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/KBDelTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/ReminderAddTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/ReminderDelTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/TemplateCreateTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/TemplateDeleteTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/TemplateDownloadTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/TemplateEditTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/AI/Tools/TemplateToggleTool.swift": ["let demo = DemoModeStore.isDemoActive"],
        "TabMail/Services/DeviceSyncService.swift": [
            // Connect: the demo has no peers to probe.
            "if DemoModeStore.shared.isActive {",
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
        // Reminder build: the target is taken once as the build starts and carried to every read and write.
        "TabMail/Services/AI/ReminderBuilder.swift": ["let demoActive = await MainActor.run { DemoModeStore.shared.isActive }"],
        "TabMail/Services/AI/KBRefinementService.swift": [],
        "TabMail/Services/AI/AIPromptLearning.swift": [],
        "TabMail/Views/Settings/BulletListEditor.swift": [],
    ]

    @Test("The live demo flag is read only at the listed sites")
    func readsAreAtTheListedSites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (path, expected) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let found = source.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { ($0.contains("DemoModeStore.isDemoActive") || $0.contains("DemoModeStore.shared.isActive")) && !$0.hasPrefix("//") }
            #expect(found == expected, "\(path): the reads of the live demo flag changed; a writer takes its target as it starts")
        }
    }

    /// A gesture in a view takes its target as the argument of the store call it makes, in the one expression.
    private static let gestureViews: [String: [String]] = [
        "TabMail/Views/Settings/RemindersSettingsView.swift": ["setEnabled"],
        "TabMail/Views/Inbox/ReminderTopCard.swift": ["setEnabled", "setEnabled"],
        "TabMail/Views/Agent/MarkdownChatText.swift": ["setEnabled", "setEnabled"],
        "TabMail/Views/Settings/TemplateDetailView.swift": ["updateTemplate", "updateTemplate", "updateTemplate"],
        "TabMail/Views/Settings/TemplatesListView.swift": ["updateTemplate", "deleteTemplate", "addTemplate"],
        "TabMail/Views/Settings/MarketplaceTemplateDetailView.swift": ["addTemplate"],
    ]

    @Test("A view reads the live demo flag only as the target argument of the store call its gesture makes")
    func viewsReadTheFlagOnlyAsAGestureArgument() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (path, calls) in Self.gestureViews.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let reads = source.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { ($0.contains("DemoModeStore.isDemoActive") || $0.contains("DemoModeStore.shared.isActive")) && !$0.hasPrefix("//") }
            #expect(reads.count == calls.count, "\(path): the reads of the live demo flag changed")
            for (read, call) in zip(reads, calls) {
                #expect(read.contains("\(call)(") && read.contains("demo: DemoModeStore.isDemoActive"),
                        "\(path): \(read) is not the target argument of a \(call)")
            }
        }
    }
}
