/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionPatchApplier")
struct ActionPatchApplierTests {

    let baseContent = """
    # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Archive newsletters.

    # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Delete spam.

    # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Reply to clients.

    # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    """

    @Test("ADD patch appends rule to correct section")
    func addPatch() {
        let patch = """
        ADD
        archive
        Always archive promotional emails.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("Always archive promotional emails"))
    }

    @Test("DEL patch removes existing rule")
    func delPatch() {
        let patch = """
        DEL
        archive
        Archive newsletters.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Archive newsletters"))
    }

    @Test("DEL for non-existent rule returns nil")
    func delNonExistent() {
        let patch = """
        DEL
        archive
        This rule does not exist.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }

    @Test("Mixed ADD+DEL patch applies both")
    func mixedPatch() {
        let patch = """
        DEL
        delete
        Delete spam.
        ADD
        delete
        Delete marketing emails.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Delete spam"))
        #expect(result!.contains("Delete marketing emails"))
    }

    @Test("ADD deduplicates existing rule")
    func addDedup() {
        let patch = """
        ADD
        archive
        Archive newsletters.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        // Should either return nil (no change) or return content unchanged
        if let result {
            let count = result.components(separatedBy: "Archive newsletters").count - 1
            #expect(count <= 1)
        }
    }

    @Test("Empty patch text returns nil")
    func emptyPatch() {
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: "")
        #expect(result == nil)
    }

    @Test("Invalid action type returns nil")
    func invalidActionType() {
        let patch = """
        ADD
        invalid_type
        Some rule.
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }
}
