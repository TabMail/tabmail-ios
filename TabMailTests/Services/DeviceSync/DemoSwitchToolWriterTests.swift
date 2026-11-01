/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A template writer that awaits between its start and its write (a confirmation, a lookup, a download) carries
/// the change counter it started with (DS-DEMO): a demo switch in between, in either direction, leaves both
/// stores unchanged and the writer reports that it could not save. The control is the same call with no switch.
/// The template under change has the same id in the real store and in the demo's, so only the counter can tell the
/// two stores apart.
@MainActor
@Suite("Template writers across a demo switch", .serialized, .processGlobalState)
struct DemoSwitchToolWriterTests {
    fileprivate enum Tool: String, CaseIterable, CustomStringConvertible {
        case create, edit, delete, toggle, toggleToCurrentState, download
        var description: String { rawValue }

        /// The tools with a confirmation card switch there; the others switch while they resolve the template id.
        var confirms: Bool { self == .create || self == .edit || self == .delete || self == .download }

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
            case .toggle:
                return try await TemplateToggleTool(context: context).execute(
                    arguments: ["template_id": .int(numericId), "enabled": .bool(false)], invocation: invocation)
            case .toggleToCurrentState:
                // The template is enabled in both stores, so this changes nothing: the switch still refuses it.
                return try await TemplateToggleTool(context: context).execute(
                    arguments: ["template_id": .int(numericId), "enabled": .bool(true)], invocation: invocation)
            case .download:
                let body = Data(#"{"template":{"id":"switch-download","name":"Switch download","instructions":["Be brief"],"exampleReply":"Thanks","enabled":true}}"#.utf8)
                return try await TemplateDownloadTool(context: context, fetch: { _ in .body(body) }).execute(
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
                if let entering { await DemoSwitchToolWriterTests.switchDemo(entering: entering) }
                confirmation.onRespond(true)
            }
        }
    }

    fileprivate static func switchDemo(entering: Bool) async {
        if entering { try? await PromptStore.shared.enterDemo() } else { try? await PromptStore.shared.leaveDemo() }
    }

    private func stored(_ key: String) -> Data? { UserDefaults.standard.data(forKey: key) }

    private func decodedTemplates(_ key: String) -> [ReplyTemplate] {
        stored(key).flatMap { try? JSONDecoder().decode([ReplyTemplate].self, from: $0) } ?? []
    }

    @Test("A writer whose demo was entered or left during its call saves nothing in either store and reports it; an uninterrupted one saves",
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
        // The id the demo's own template has, so the real store holds a template of the same id.
        try await store.enterDemo()
        let shared = try #require(store.templates.first { !$0.deleted }?.id)
        try await store.leaveDemo()
        store.applySyncedTemplates([ReplyTemplate(id: shared, name: "Tool real")])
        if !entering { try await store.enterDemo() }
        let translator = MockChatIdTranslator()
        await translator.seed(shared, as: 1)
        let sink: SwitchingSink
        if tool.confirms {
            sink = SwitchingSink(entering: entering)
        } else {
            sink = SwitchingSink(entering: nil)
            await translator.setOnResolve { await DemoSwitchToolWriterTests.switchDemo(entering: entering) }
        }

        let realBefore = stored("user_templates")
        let result = try await tool.run(translator, numericId: 1, sink: sink)

        #expect(DemoModeStore.isDemoActive == entering, "\(tool): the switch happened")
        #expect(result.contains("Could not save"), "\(tool): the tool reports that it could not save: \(result)")
        #expect(stored("user_templates") == realBefore, "\(tool): the real templates are unchanged")
        #expect(!store.templates.contains { $0.name == "Switch probe" || $0.name == "Switch renamed" || $0.name == "Switch download" }, "\(tool): nothing changed was saved in the mode now shown")
        // Durable state, decoded from the keys themselves: the mode now live holds exactly the template it held
        // before the call, and the other mode's key is untouched.
        let probeNames: Set<String> = ["Switch probe", "Switch renamed", "Switch download"]
        let liveKey = entering ? "demo.user_templates" : "user_templates"
        let live = decodedTemplates(liveKey)
        #expect(live.allSatisfy { !probeNames.contains($0.name) }, "\(tool): nothing the call made reached the stored \(liveKey)")
        let liveShared = live.filter { $0.id == shared }
        #expect(liveShared.count == 1, "\(tool): the stored \(liveKey) still holds the shared template once")
        if let first = liveShared.first {
            #expect(!first.deleted && first.enabled, "\(tool): the stored template is neither deleted nor toggled: \(first)")
            #expect(entering || first.name == "Tool real", "\(tool): the stored real template is not renamed")
        }
        if !entering {
            #expect(decodedTemplates("demo.user_templates").isEmpty, "\(tool): the demo's key is gone, not rewritten")
        }
        let shownAfter = store.templates.first { $0.id == shared }
        if entering {
            // The demo's template is as the overlay seeded it, not the real one and not changed.
            #expect(shownAfter?.name != "Tool real" && shownAfter?.deleted == false && shownAfter?.enabled == true, "\(tool): the demo's template is unchanged")
        } else {
            #expect(shownAfter.map { ($0.name, $0.enabled, $0.deleted) }.map { $0 == ("Tool real", true, false) } == true, "\(tool): the real template is unchanged: \(String(describing: shownAfter))")
            #expect(stored("demo.user_templates") == nil, "\(tool): no demo key came back")
        }

        // Control: the same call with no switch saves in the mode now live.
        await translator.setOnResolve(nil)
        let again = try await tool.run(translator, numericId: 1, sink: SwitchingSink(entering: nil))
        #expect(!again.contains("Could not save") && !again.contains("\"error\""), "\(tool): control saves: \(again)")
        // ... and the effect is in the stored templates of the mode now live, decoded from the key itself.
        let controlled = decodedTemplates(liveKey)
        let target = controlled.first { $0.id == shared }
        switch tool {
        case .create: #expect(controlled.contains { $0.name == "Switch probe" && !$0.deleted }, "\(tool): control stored the new template")
        case .download: #expect(controlled.contains { $0.name == "Switch download" && !$0.deleted }, "\(tool): control stored the downloaded template")
        case .edit: #expect(target?.name == "Switch renamed", "\(tool): control stored the new name")
        case .delete: #expect(target?.deleted == true, "\(tool): control stored the deletion")
        case .toggle: #expect(target?.enabled == false, "\(tool): control stored the disabled state")
        case .toggleToCurrentState: #expect(target?.enabled == true && target?.deleted == false, "\(tool): control left the template enabled")
        }
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
    }

    @Test("A marketplace install whose demo was entered or left during the download saves nothing and reports it; an uninterrupted one installs",
          arguments: [true, false])
    func installRefusedAcrossASwitch(entering: Bool) async throws {
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
        store.applySyncedTemplates([ReplyTemplate(id: "install-real", name: "Install real")])
        if !entering { try await store.enterDemo() }
        let downloaded = TemplateMarketplaceClient.DownloadedTemplate(id: "install-new", name: "Install new", instructions: ["Be brief"], exampleReply: "Thanks", enabled: true)
        let realBefore = stored("user_templates")

        let outcome = try await store.installMarketplaceTemplate(id: "install-new", since: store.changeSeen) { _ in
            await DemoSwitchToolWriterTests.switchDemo(entering: entering)
            return downloaded
        }

        #expect(outcome == .notSaved, "the install is refused")
        #expect(DemoModeStore.isDemoActive == entering)
        #expect(stored("user_templates") == realBefore, "the real templates are unchanged")
        #expect(!store.templates.contains { $0.id == "install-new" }, "nothing was installed in the mode now shown")

        // Control: the same install with no switch installs into the mode now live.
        let again = try await store.installMarketplaceTemplate(id: "install-new", since: store.changeSeen) { _ in downloaded }
        #expect(again == .installed("install-new"))
        #expect(store.templates.contains { $0.id == "install-new" })
        if DemoModeStore.isDemoActive { try await store.leaveDemo() }
        #expect(entering == (stored("user_templates") == realBefore), "a demo install never reaches the real key, a real one does")
    }
}
