/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A template tool awaits a confirmation between its start and its write, so it carries the change counter it
/// started with (DS-DEMO): a demo switch during the confirmation, in either direction, leaves both stores
/// unchanged and the tool reports that it could not save. The control is the same call with no switch.
@MainActor
@Suite("Template tools across a demo switch", .serialized, .processGlobalState)
struct DemoSwitchToolWriterTests {
    fileprivate enum Tool: String, CaseIterable, CustomStringConvertible {
        case create, edit, delete
        var description: String { rawValue }

        func run(_ translator: MockChatIdTranslator, numericId: Int, sink: any AgentUISink) async throws -> String {
            let context = ToolContext(db: try DatabaseQueue(), translator: translator)
            let invocation = ToolInvocation(uiSink: sink, sessionKey: "demo-switch-" + rawValue)
            switch self {
            case .create:
                return try await TemplateCreateTool(context: context).execute(
                    arguments: ["name": .string("Switch probe"), "instructions": .array([.string("Be brief")]), "example_reply": .string("Thanks")],
                    invocation: invocation)
            case .edit:
                return try await TemplateEditTool(context: context).execute(
                    arguments: ["template_id": .int(numericId), "name": .string("Switch renamed")], invocation: invocation)
            case .delete:
                return try await TemplateDeleteTool(context: context).execute(
                    arguments: ["template_id": .int(numericId)], invocation: invocation)
            }
        }
    }

    /// Confirms like the user would, after switching the demo the way the app does.
    @MainActor
    private final class SwitchingSink: AgentUISink {
        let entering: Bool?
        init(entering: Bool?) { self.entering = entering }

        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            let entering = entering
            Task { @MainActor in
                if let entering {
                    if entering { try? await PromptStore.shared.enterDemo() } else { try? await PromptStore.shared.leaveDemo() }
                }
                confirmation.onRespond(true)
            }
        }
    }

    private func stored(_ key: String) -> Data? { UserDefaults.standard.data(forKey: key) }

    @Test("A tool confirmed after the demo was entered or left saves nothing in either store and reports it; an uninterrupted one saves",
          arguments: Tool.allCases, [true, false])
    fileprivate func refusedAcrossASwitch(_ tool: Tool, entering: Bool) async throws {
        let store = PromptStore.shared
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        DeviceSyncService.shared.disconnect()
        DemoModeStore.shared._resetForTests()
        let saved = store.templates
        defer {
            DemoModeStore.shared._resetForTests()
            PromptStore.removeDemoOverlayKeys()
            store.applySyncedTemplates(saved)
        }
        store.applySyncedTemplates([ReplyTemplate(id: "tool-real", name: "Tool real")])
        if !entering { try await store.enterDemo() }
        let target = try #require(store.templates.first { !$0.deleted }?.id)
        let translator = MockChatIdTranslator()
        await translator.seed(target, as: 1)

        let realBefore = stored("user_templates")
        let result = try await tool.run(translator, numericId: 1, sink: SwitchingSink(entering: entering))

        #expect(result.contains("Could not save"), "\(tool): the tool reports that it could not save: \(result)")
        #expect(stored("user_templates") == realBefore, "\(tool): the real templates are unchanged")
        if entering {
            #expect(DemoModeStore.isDemoActive)
            #expect(!store.templates.contains { $0.id == "tool-real" || $0.name == "Switch probe" || $0.name == "Switch renamed" }, "\(tool): the demo shows no real or changed template")
            #expect(store.templates.allSatisfy { !$0.deleted }, "\(tool): nothing in the demo was deleted")
        } else {
            #expect(!DemoModeStore.isDemoActive)
            #expect(store.templates.map(\.id) == ["tool-real"], "\(tool): the real templates are shown")
            #expect(stored("demo.user_templates") == nil, "\(tool): no demo key came back")
        }

        // Control: the same call with no switch saves in the mode now live.
        let control = try #require(store.templates.first { !$0.deleted }?.id)
        await translator.seed(control, as: 2)
        let again = try await tool.run(translator, numericId: 2, sink: SwitchingSink(entering: nil))
        #expect(!again.contains("Could not save") && !again.contains("\"error\""), "\(tool): control saves: \(again)")
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }
}
