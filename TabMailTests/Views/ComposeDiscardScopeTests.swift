/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// #254 (owner 2026-10-22): the Discard of the "Save Draft?" prompt drops only
/// this session's unsaved edits. A draft already on the server stays as it was
/// last saved; deleting it takes the explicit cleared-draft Delete. The discard
/// itself runs in `ComposeDraftDiscardTests`.
@Suite("Compose discard scope")
@MainActor
struct ComposeDiscardScopeTests {
    private func composeSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot
            .appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"),
            encoding: .utf8)
    }

    private func sourceSlice(
        _ startMarker: String,
        before endMarker: String,
        in source: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: endMarker))
        return tail[..<end.lowerBound]
    }

    @Test("Discarding unsaved edits keeps a draft that is on the server")
    func unsavedEditsKeepServerDraft() {
        #expect(ComposeDraftGuards.discardDisposition(
            scope: .unsavedEdits, serverDraftId: "42") == .keepDraft)
    }

    @Test("Deleting a cleared draft still deletes its server copy")
    func wholeDraftDeletesServerDraft() {
        #expect(ComposeDraftGuards.discardDisposition(
            scope: .wholeDraft, serverDraftId: "42") == .deleteServerDraft)
    }

    @Test("A draft that never reached the server is deleted by either discard")
    func localOnlyDraftIsDeleted() {
        for scope in [ComposeDraftGuards.DiscardScope.unsavedEdits, .wholeDraft] {
            #expect(ComposeDraftGuards.discardDisposition(
                scope: scope, serverDraftId: nil) == .deleteLocalDraft)
        }
    }

    @Test("The Save Draft prompt's Discard drops only unsaved edits")
    func savePromptDiscardUsesUnsavedEditsScope() throws {
        let alert = try sourceSlice(
            ".alert(\"Save Draft?\"",
            before: "} message: {",
            in: composeSource())
        #expect(alert.contains("discardDraftAndDismiss(.unsavedEdits)"))
        #expect(!alert.contains(".wholeDraft"))
    }

    @Test("The confirmed cleared-draft Delete deletes the whole draft")
    func clearedDraftDeleteUsesWholeDraftScope() throws {
        let body = try sourceSlice(
            "private func deleteClearedDraftAndDismiss() async {",
            before: "\n    }\n",
            in: composeSource())
        #expect(body.contains("discardDraftAndDismiss(.wholeDraft)"))
    }
}
