/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("KBPatchApplier.applyKBPatch")
struct KBPatchApplierExtendedTests {

    private let baseContent = """
    - User prefers concise summaries.
    - User works in software engineering.
    - User timezone is Pacific.
    """

    // MARK: - ADD

    @Test("ADD appends to end")
    func addAppends() {
        let patch = """
        ADD
        User is a morning person
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- User is a morning person."))
        // Should be at the end
        let lines = result!.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.last == "- User is a morning person.")
    }

    @Test("ADD normalizes content with bullet and period")
    func addNormalizes() {
        let patch = """
        ADD
        No bullet or period
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- No bullet or period."))
    }

    @Test("ADD duplicate is idempotent")
    func addDuplicate() {
        let patch = """
        ADD
        User prefers concise summaries
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result == baseContent)
    }

    @Test("ADD duplicate is case-insensitive")
    func addDuplicateCaseInsensitive() {
        let patch = """
        ADD
        USER PREFERS CONCISE SUMMARIES
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result == baseContent) // No change
    }

    // MARK: - DEL

    @Test("DEL removes matching line")
    func delRemoves() {
        let patch = """
        DEL
        User timezone is Pacific
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Pacific"))
    }

    @Test("DEL case-insensitive match")
    func delCaseInsensitive() {
        let patch = """
        DEL
        USER TIMEZONE IS PACIFIC
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Pacific"))
    }

    @Test("DEL for non-existent content returns nil")
    func delNonExistent() {
        let patch = """
        DEL
        This line does not exist
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }

    // MARK: - Multiple operations

    @Test("Multiple ADD operations")
    func multipleAdds() {
        let patch = """
        ADD
        User likes dark mode
        ADD
        User prefers bullet points
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- User likes dark mode."))
        #expect(result!.contains("- User prefers bullet points."))
    }

    @Test("ADD then DEL in sequence")
    func addThenDel() {
        let patch = """
        ADD
        New preference
        DEL
        User timezone is Pacific
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- New preference."))
        #expect(!result!.contains("Pacific"))
    }

    // MARK: - Error cases

    @Test("Empty patch returns nil")
    func emptyPatch() {
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: "")
        #expect(result == nil)
    }

    @Test("Non-operation text returns nil")
    func noOperations() {
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: "just random text")
        #expect(result == nil)
    }

    @Test("Empty content text after ADD")
    func emptyContentAfterAdd() {
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: "ADD")
        #expect(result == nil)
    }

    // MARK: - Edge cases

    @Test("ADD to empty content")
    func addToEmpty() {
        let patch = """
        ADD
        First entry
        """
        let result = KBPatchApplier.applyKBPatch(content: "", patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- First entry."))
    }

    @Test("DEL last remaining line")
    func delLastLine() {
        let content = "- Only line."
        let patch = """
        DEL
        Only line
        """
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Only line"))
    }
}
