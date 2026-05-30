/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - PromptStore Template CRDT Merge Tests

@MainActor
@Suite("PromptStore mergeTemplates")
struct PromptStoreMergeTemplatesTests {

    /// Save current templates, run body, restore originals.
    /// Uses applySync(skipHistory: true) to avoid Device Sync broadcast side effects.
    private func withCleanTemplates(_ body: () -> Void) {
        let store = PromptStore.shared
        let saved = store.templates
        store.applySync(templates: [], skipHistory: true)
        defer { store.applySync(templates: saved, skipHistory: true) }
        body()
    }

    @Test("Remote template newer than local is adopted")
    func remoteNewerWins() {
        withCleanTemplates {
            let store = PromptStore.shared
            let oldDate = Date(timeIntervalSince1970: 1000)
            let newDate = Date(timeIntervalSince1970: 2000)

            let local = ReplyTemplate(id: "t1", name: "Local", updatedAt: oldDate)
            store.applySync(templates: [local], skipHistory: true)

            let remote = ReplyTemplate(id: "t1", name: "Remote", updatedAt: newDate)
            store.mergeTemplates([remote])

            #expect(store.templates.count == 1)
            #expect(store.templates[0].name == "Remote")
        }
    }

    @Test("Local template newer than remote is preserved")
    func localNewerPreserved() {
        withCleanTemplates {
            let store = PromptStore.shared
            let oldDate = Date(timeIntervalSince1970: 1000)
            let newDate = Date(timeIntervalSince1970: 2000)

            let local = ReplyTemplate(id: "t1", name: "Local", updatedAt: newDate)
            store.applySync(templates: [local], skipHistory: true)

            let remote = ReplyTemplate(id: "t1", name: "Remote", updatedAt: oldDate)
            store.mergeTemplates([remote])

            #expect(store.templates.count == 1)
            #expect(store.templates[0].name == "Local")
        }
    }

    @Test("Remote introduces new template that is added")
    func remoteNewTemplateAdded() {
        withCleanTemplates {
            let store = PromptStore.shared
            let local = ReplyTemplate(id: "t1", name: "Existing", updatedAt: Date(timeIntervalSince1970: 1000))
            store.applySync(templates: [local], skipHistory: true)

            let remote = ReplyTemplate(id: "t2", name: "Brand New", updatedAt: Date(timeIntervalSince1970: 500))
            store.mergeTemplates([remote])

            #expect(store.templates.count == 2)
            let ids = Set(store.templates.map(\.id))
            #expect(ids.contains("t1"))
            #expect(ids.contains("t2"))
        }
    }

    @Test("Merge does not duplicate same-id templates")
    func noDuplicateIds() {
        withCleanTemplates {
            let store = PromptStore.shared
            let date = Date(timeIntervalSince1970: 1000)
            let local = ReplyTemplate(id: "t1", name: "Original", updatedAt: date)
            store.applySync(templates: [local], skipHistory: true)

            let remote = ReplyTemplate(id: "t1", name: "Updated", updatedAt: date.addingTimeInterval(1))
            store.mergeTemplates([remote])

            let matchingIds = store.templates.filter { $0.id == "t1" }
            #expect(matchingIds.count == 1)
        }
    }

    @Test("Empty incoming array causes no changes")
    func emptyIncomingNoChanges() {
        withCleanTemplates {
            let store = PromptStore.shared
            let local = ReplyTemplate(id: "t1", name: "Stays", updatedAt: Date(timeIntervalSince1970: 1000))
            store.applySync(templates: [local], skipHistory: true)

            store.mergeTemplates([])

            #expect(store.templates.count == 1)
            #expect(store.templates[0].name == "Stays")
        }
    }
}

// MARK: - PromptStore GC Deleted Templates Tests

@MainActor
@Suite("PromptStore gcDeletedTemplates")
struct PromptStoreGCDeletedTemplatesTests {

    private func withCleanTemplates(_ body: () -> Void) {
        let store = PromptStore.shared
        let saved = store.templates
        store.applySync(templates: [], skipHistory: true)
        defer { store.applySync(templates: saved, skipHistory: true) }
        body()
    }

    @Test("Template deleted more than 90 days ago is removed")
    func oldTombstoneRemoved() {
        withCleanTemplates {
            let store = PromptStore.shared
            let longAgo = Date().addingTimeInterval(-91 * 86400)
            let template = ReplyTemplate(id: "old", name: "Old", deleted: true, deletedAt: longAgo)
            store.applySync(templates: [template], skipHistory: true)

            store.gcDeletedTemplates()

            #expect(store.templates.isEmpty)
        }
    }

    @Test("Template deleted less than 90 days ago is kept")
    func recentTombstoneKept() {
        withCleanTemplates {
            let store = PromptStore.shared
            let recent = Date().addingTimeInterval(-30 * 86400)
            let template = ReplyTemplate(id: "recent", name: "Recent", deleted: true, deletedAt: recent)
            store.applySync(templates: [template], skipHistory: true)

            store.gcDeletedTemplates()

            #expect(store.templates.count == 1)
            #expect(store.templates[0].id == "recent")
        }
    }

    @Test("Non-deleted templates are untouched by GC")
    func nonDeletedUntouched() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(id: "alive", name: "Alive", deleted: false)
            store.applySync(templates: [template], skipHistory: true)

            store.gcDeletedTemplates()

            #expect(store.templates.count == 1)
            #expect(store.templates[0].id == "alive")
        }
    }

    @Test("Template with deleted=true but no deletedAt is not removed")
    func deletedWithoutTimestampNotRemoved() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(id: "no-ts", name: "NoTimestamp", deleted: true, deletedAt: nil)
            store.applySync(templates: [template], skipHistory: true)

            store.gcDeletedTemplates()

            #expect(store.templates.count == 1)
            #expect(store.templates[0].id == "no-ts")
        }
    }
}

// MARK: - PromptStore templatesAsPrompt Tests

@MainActor
@Suite("PromptStore templatesAsPrompt")
struct PromptStoreTemplatesAsPromptTests {

    private func withCleanTemplates(_ body: () -> Void) {
        let store = PromptStore.shared
        let saved = store.templates
        store.applySync(templates: [], skipHistory: true)
        defer { store.applySync(templates: saved, skipHistory: true) }
        body()
    }

    @Test("Enabled template with instructions and example is formatted correctly")
    func enabledTemplateFormatted() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "fmt", name: "Formal Reply",
                enabled: true,
                instructions: ["Be polite", "Use greeting"],
                exampleReply: "Dear Sir,\n\nThank you.",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            store.applySync(templates: [template], skipHistory: true)

            let result = store.templatesAsPrompt()

            #expect(result.contains("# Email template for standard replies"))
            #expect(result.contains("## Formal Reply"))
            #expect(result.contains("- Be polite"))
            #expect(result.contains("- Use greeting"))
            #expect(result.contains("- Example reply:"))
            #expect(result.contains("```"))
            #expect(result.contains("Dear Sir,"))
        }
    }

    @Test("Disabled template is excluded")
    func disabledExcluded() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "dis", name: "Disabled",
                enabled: false, instructions: ["Stuff"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            store.applySync(templates: [template], skipHistory: true)

            let result = store.templatesAsPrompt()
            #expect(result.isEmpty)
        }
    }

    @Test("Deleted template is excluded")
    func deletedExcluded() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "del", name: "Deleted",
                enabled: true, instructions: ["Stuff"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                deleted: true, deletedAt: Date()
            )
            store.applySync(templates: [template], skipHistory: true)

            let result = store.templatesAsPrompt()
            #expect(result.isEmpty)
        }
    }

    @Test("Empty templates produces empty string")
    func emptyTemplates() {
        withCleanTemplates {
            let result = PromptStore.shared.templatesAsPrompt()
            #expect(result.isEmpty)
        }
    }

    @Test("Template with empty exampleReply omits example block")
    func emptyExampleReplyOmitsBlock() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "no-ex", name: "No Example",
                enabled: true, instructions: ["Do something"],
                exampleReply: "",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            store.applySync(templates: [template], skipHistory: true)

            let result = store.templatesAsPrompt()

            #expect(result.contains("## No Example"))
            #expect(result.contains("- Do something"))
            #expect(!result.contains("- Example reply:"))
            #expect(!result.contains("```"))
        }
    }
}

// MARK: - PromptStore compositionMarkdown Tests

@MainActor
@Suite("PromptStore compositionMarkdown")
struct PromptStoreCompositionMarkdownTests {

    private func withCleanState(_ body: () -> Void) {
        let store = PromptStore.shared
        let savedTemplates = store.templates
        let savedComposition = store.rawComposition
        store.applySync(composition: "", templates: [], skipHistory: true)
        defer { store.applySync(composition: savedComposition, templates: savedTemplates, skipHistory: true) }
        body()
    }

    @Test("With templates, prompt is inserted before END marker")
    func templatesInsertedBeforeEnd() {
        withCleanState {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "ins", name: "Inserted",
                enabled: true, instructions: ["Insert me"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            store.applySync(
                composition: "Some preamble\n\n====END USER INSTRUCTIONS====\n\nFooter text",
                templates: [template],
                skipHistory: true
            )

            let result = store.compositionMarkdown()

            #expect(result.contains("## Inserted"))
            #expect(result.contains("- Insert me"))
            #expect(result.contains("====END USER INSTRUCTIONS===="))
            // Template content should appear before the END marker
            let endRange = result.range(of: "====END USER INSTRUCTIONS====")!
            let templateRange = result.range(of: "## Inserted")!
            #expect(templateRange.lowerBound < endRange.lowerBound)
        }
    }

    @Test("Without templates, rawComposition is returned unchanged")
    func noTemplatesReturnsRaw() {
        withCleanState {
            let store = PromptStore.shared
            let raw = "My composition\n\n====END USER INSTRUCTIONS====\n\nFooter"
            store.applySync(composition: raw, templates: [], skipHistory: true)

            let result = store.compositionMarkdown()
            #expect(result == raw)
        }
    }

    @Test("Missing END marker appends templates at end")
    func missingEndMarkerAppendsAtEnd() {
        withCleanState {
            let store = PromptStore.shared
            let template = ReplyTemplate(
                id: "end", name: "Appended",
                enabled: true, instructions: ["Append me"],
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            store.applySync(
                composition: "Just some content without an end marker",
                templates: [template],
                skipHistory: true
            )

            let result = store.compositionMarkdown()

            #expect(result.contains("Just some content without an end marker"))
            #expect(result.contains("## Appended"))
            #expect(result.contains("- Append me"))
        }
    }
}

// MARK: - PromptStore visibleTemplates Tests

@MainActor
@Suite("PromptStore visibleTemplates")
struct PromptStoreVisibleTemplatesTests {

    private func withCleanTemplates(_ body: () -> Void) {
        let store = PromptStore.shared
        let saved = store.templates
        store.applySync(templates: [], skipHistory: true)
        defer { store.applySync(templates: saved, skipHistory: true) }
        body()
    }

    @Test("Deleted template is excluded from visibleTemplates")
    func deletedExcluded() {
        withCleanTemplates {
            let store = PromptStore.shared
            store.applySync(templates: [
                ReplyTemplate(id: "alive", name: "Alive", deleted: false),
                ReplyTemplate(id: "dead", name: "Dead", deleted: true, deletedAt: Date()),
            ], skipHistory: true)

            let visible = store.visibleTemplates
            #expect(visible.count == 1)
            #expect(visible[0].id == "alive")
        }
    }

    @Test("Non-deleted template is included in visibleTemplates")
    func nonDeletedIncluded() {
        withCleanTemplates {
            let store = PromptStore.shared
            store.applySync(templates: [
                ReplyTemplate(id: "v1", name: "First", deleted: false),
                ReplyTemplate(id: "v2", name: "Second", deleted: false),
            ], skipHistory: true)

            let visible = store.visibleTemplates
            #expect(visible.count == 2)
        }
    }
}

// MARK: - PromptStore deleteTemplate Tests

@MainActor
@Suite("PromptStore deleteTemplate")
struct PromptStoreDeleteTemplateTests {

    private func withCleanTemplates(_ body: () -> Void) {
        let store = PromptStore.shared
        let saved = store.templates
        store.applySync(templates: [], skipHistory: true)
        defer { store.applySync(templates: saved, skipHistory: true) }
        body()
    }

    @Test("deleteTemplate sets deleted, deletedAt, and updatedAt")
    func setsDeleteFields() {
        withCleanTemplates {
            let store = PromptStore.shared
            let beforeDelete = Date()
            let template = ReplyTemplate(
                id: "to-del", name: "DeleteMe",
                createdAt: Date(timeIntervalSince1970: 1000),
                updatedAt: Date(timeIntervalSince1970: 1000)
            )
            store.applySync(templates: [template], skipHistory: true)

            store.deleteTemplate(id: "to-del")

            let result = store.templates.first { $0.id == "to-del" }!
            #expect(result.deleted == true)
            #expect(result.deletedAt != nil)
            #expect(result.deletedAt! >= beforeDelete)
            #expect(result.updatedAt >= beforeDelete)
        }
    }

    @Test("deleteTemplate with unknown id is a no-op")
    func unknownIdNoOp() {
        withCleanTemplates {
            let store = PromptStore.shared
            let template = ReplyTemplate(id: "keep", name: "KeepMe")
            store.applySync(templates: [template], skipHistory: true)

            store.deleteTemplate(id: "nonexistent")

            #expect(store.templates.count == 1)
            #expect(store.templates[0].deleted == false)
        }
    }
}
