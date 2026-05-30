/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("KBPatchApplier")
struct KBPatchApplierTests {

    let baseContent = """
    - I prefer formal emails.
    - My timezone is PST.
    - I work at Acme Corp.
    """

    @Test("ADD appends new entry")
    func addEntry() {
        let patch = """
        ADD
        I am a morning person.
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("morning person"))
    }

    @Test("DEL removes existing entry")
    func delEntry() {
        let patch = """
        DEL
        My timezone is PST.
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("timezone is PST"))
    }

    @Test("DEL for non-existent entry returns nil")
    func delNonExistent() {
        let patch = """
        DEL
        This does not exist.
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }

    @Test("ADD deduplicates existing entry")
    func addDedup() {
        let patch = """
        ADD
        I prefer formal emails.
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        // Should either return nil (no change) or not duplicate
        if let result {
            let count = result.components(separatedBy: "formal emails").count - 1
            #expect(count <= 1)
        }
    }

    @Test("Mixed ADD+DEL")
    func mixedPatch() {
        let patch = """
        DEL
        I work at Acme Corp.
        ADD
        I work at BigCo.
        """
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Acme Corp"))
        #expect(result!.contains("BigCo"))
    }

    @Test("Empty patch returns nil")
    func emptyPatch() {
        let result = KBPatchApplier.applyKBPatch(content: baseContent, patchText: "")
        #expect(result == nil)
    }

    @Test("ADD normalizes content with bullet prefix and period")
    func addNormalizesContent() {
        let result = KBPatchApplier.applyKBPatch(content: "", patchText: "ADD\nSome new fact")
        #expect(result != nil)
        #expect(result!.contains("- Some new fact."))
    }

    @Test("ADD with existing bullet prefix does not double-bullet")
    func addWithExistingBullet() {
        let result = KBPatchApplier.applyKBPatch(content: "", patchText: "ADD\n- Already bulleted")
        #expect(result != nil)
        #expect(!result!.contains("- - "))
        #expect(result!.contains("- Already bulleted."))
    }

    @Test("DEL is case-insensitive")
    func delCaseInsensitive() {
        let content = "- User prefers dark mode."
        let patch = "DEL\nuser prefers DARK MODE."
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("dark mode"))
    }

    @Test("DEL ignores trailing period differences")
    func delIgnoresTrailingPeriod() {
        let content = "- Item with content."
        let patch = "DEL\nItem with content"
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Item with content"))
    }

    @Test("DEL only removes bullet lines")
    func delOnlyRemovesBulletLines() {
        let content = "Header text\n- Bullet item.\nAnother header"
        let patch = "DEL\nHeader text"
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result == nil)
    }

    @Test("Multiple ADD operations")
    func multipleAdds() {
        let content = "- Existing."
        let patch = "ADD\nFirst new\nADD\nSecond new"
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- First new."))
        #expect(result!.contains("- Second new."))
    }

    @Test("DEL fails mid-sequence returns nil for whole patch")
    func delFailMidSequence() {
        let content = "- First.\n- Second."
        let patch = "DEL\nFirst.\nDEL\nNonexistent."
        let result = KBPatchApplier.applyKBPatch(content: content, patchText: patch)
        #expect(result == nil)
    }

    @Test("Patch with no valid operations returns nil")
    func noValidOperations() {
        let result = KBPatchApplier.applyKBPatch(content: "- Item.", patchText: "INVALID\nstuff")
        #expect(result == nil)
    }

    @Test("ADD to completely empty content")
    func addToEmptyContent() {
        let result = KBPatchApplier.applyKBPatch(content: "", patchText: "ADD\nBrand new entry")
        #expect(result != nil)
        #expect(result!.contains("- Brand new entry."))
    }

    @Test("ADD operation line without content returns nil")
    func addOperationWithoutContent() {
        let result = KBPatchApplier.applyKBPatch(content: "- Item.", patchText: "ADD")
        #expect(result == nil)
    }
}
