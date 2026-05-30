/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PatchApplierUtils.normalizeContent")
struct PatchApplierUtilsNormalizeTests {

    @Test("Plain text gets bullet and period")
    func plainText() {
        let result = PatchApplierUtils.normalizeContent("some text")
        #expect(result == "- some text.")
    }

    @Test("Already bulleted text preserves content")
    func alreadyBulleted() {
        let result = PatchApplierUtils.normalizeContent("- some text")
        #expect(result == "- some text.")
    }

    @Test("Already bulleted with period unchanged")
    func alreadyBulletedWithPeriod() {
        let result = PatchApplierUtils.normalizeContent("- some text.")
        #expect(result == "- some text.")
    }

    @Test("Text with period gets bullet")
    func textWithPeriod() {
        let result = PatchApplierUtils.normalizeContent("some text.")
        #expect(result == "- some text.")
    }

    @Test("Whitespace trimmed")
    func whitespace() {
        let result = PatchApplierUtils.normalizeContent("  some text  ")
        #expect(result == "- some text.")
    }

    @Test("Bullet with extra spaces")
    func bulletExtraSpaces() {
        let result = PatchApplierUtils.normalizeContent("-   spaced out  ")
        #expect(result == "- spaced out.")
    }
}

@Suite("PatchApplierUtils.isDuplicate")
struct PatchApplierUtilsIsDuplicateTests {

    @Test("Exact match is duplicate")
    func exactMatch() {
        let lines = ["- Check email.", "- Review docs."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Check email."))
    }

    @Test("Case-insensitive duplicate")
    func caseInsensitive() {
        let lines = ["- Check Email."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- check email."))
    }

    @Test("Not duplicate returns false")
    func notDuplicate() {
        let lines = ["- Check email."]
        #expect(!PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Review docs."))
    }

    @Test("Empty lines not duplicate")
    func emptyLines() {
        let lines: [String] = []
        #expect(!PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Something."))
    }

    @Test("Unicode normalization mode applies NFKC")
    func unicodeNormalize() {
        // Same content should match with unicode normalization enabled
        let lines = ["- Check email."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- CHECK EMAIL.", unicodeNormalize: true))
    }

    @Test("Without unicode normalization still case-insensitive")
    func noUnicodeNormalize() {
        let lines = ["- Check email."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- check email.", unicodeNormalize: false))
    }
}

@Suite("PatchApplierUtils.parseOperations")
struct PatchApplierUtilsParseOperationsTests {

    @Test("Parse single ADD with action type")
    func singleAddWithAction() {
        let patch = """
        ADD
        archive
        Company newsletters about conferences.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].actionType == "archive")
        #expect(ops[0].content == "Company newsletters about conferences.")
    }

    @Test("Parse single DEL with action type")
    func singleDelWithAction() {
        let patch = """
        DEL
        reply
        Emails that are clearly informational.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "DEL")
        #expect(ops[0].actionType == "reply")
        #expect(ops[0].content == "Emails that are clearly informational.")
    }

    @Test("Parse multiple operations with action type")
    func multipleOpsWithAction() {
        let patch = """
        ADD
        archive
        First content line.
        DEL
        delete
        Second content line.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 2)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].actionType == "archive")
        #expect(ops[1].operation == "DEL")
        #expect(ops[1].actionType == "delete")
    }

    @Test("Parse KB operations (no action type)")
    func kbOperations() {
        let patch = """
        ADD
        User prefers concise replies.
        DEL
        Old preference note.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].actionType == nil)
        #expect(ops[0].content == "User prefers concise replies.")
        #expect(ops[1].operation == "DEL")
        #expect(ops[1].actionType == nil)
    }

    @Test("Empty patch returns empty")
    func emptyPatch() {
        let ops = PatchApplierUtils.parseOperations("", hasActionType: false)
        #expect(ops.isEmpty)
    }

    @Test("No valid operations returns empty")
    func noValidOps() {
        let patch = """
        Some random text
        that isn't a patch
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.isEmpty)
    }

    @Test("Case-insensitive operation keywords")
    func caseInsensitiveOps() {
        let patch = """
        add
        Content to add.
        del
        Content to remove.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
        #expect(ops[0].operation == "ADD")
        #expect(ops[1].operation == "DEL")
    }

    @Test("Multi-line content collected until next op")
    func multiLineContent() {
        let patch = """
        ADD
        Line one.
        Line two.
        Line three.
        DEL
        Remove this.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
        #expect(ops[0].content.contains("Line one."))
        #expect(ops[0].content.contains("Line two."))
        #expect(ops[0].content.contains("Line three."))
    }

    @Test("Truncated action type patch breaks cleanly")
    func truncatedActionPatch() {
        // Only has operation + action type, no content line
        let patch = """
        ADD
        archive
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        // Should have 0 ops since there's no content after action type
        // (i + 2 < lines.count fails — only 2 lines)
        #expect(ops.isEmpty)
    }

    @Test("Handles Windows line endings")
    func windowsLineEndings() {
        let patch = "ADD\r\nSome content.\r\nDEL\r\nOther content."
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
    }

    @Test("Action type is lowercased")
    func actionTypeLowercased() {
        let patch = """
        ADD
        ARCHIVE
        Content here.
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 1)
        #expect(ops[0].actionType == "archive")
    }
}
