/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "PatchApplierUtils.normalizeContent" — it collided
// with `PatchApplierUtilsNormalizeTests` in `PatchApplierUtilsTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("PatchApplierUtils.normalizeContent — extended cases")
struct NormalizeContentTests {

    @Test("Adds bullet prefix and period suffix")
    func addsBulletAndPeriod() {
        let result = PatchApplierUtils.normalizeContent("Hello world")
        #expect(result == "- Hello world.")
    }

    @Test("Strips existing bullet prefix")
    func stripsExistingBullet() {
        let result = PatchApplierUtils.normalizeContent("- Already bulleted")
        #expect(result == "- Already bulleted.")
    }

    @Test("Does not add duplicate period")
    func noDuplicatePeriod() {
        let result = PatchApplierUtils.normalizeContent("Already ended.")
        #expect(result == "- Already ended.")
    }

    @Test("Strips existing bullet and preserves period")
    func stripsBulletPreservesPeriod() {
        let result = PatchApplierUtils.normalizeContent("- Already bulleted.")
        #expect(result == "- Already bulleted.")
    }

    @Test("Trims leading/trailing whitespace")
    func trimsWhitespace() {
        let result = PatchApplierUtils.normalizeContent("  padded text  ")
        #expect(result == "- padded text.")
    }

    @Test("Trims whitespace after removing bullet")
    func trimsAfterBulletRemoval() {
        let result = PatchApplierUtils.normalizeContent("-   extra space  ")
        #expect(result == "- extra space.")
    }

    @Test("Empty string gets bullet and period")
    func emptyString() {
        let result = PatchApplierUtils.normalizeContent("")
        #expect(result == "- .")
    }

    @Test("Bullet-only string")
    func bulletOnly() {
        let result = PatchApplierUtils.normalizeContent("- ")
        #expect(result == "- .")
    }

    @Test("Period-only string")
    func periodOnly() {
        let result = PatchApplierUtils.normalizeContent(".")
        #expect(result == "- .")
    }

    @Test("Preserves internal spaces")
    func internalSpaces() {
        let result = PatchApplierUtils.normalizeContent("word one word two")
        #expect(result == "- word one word two.")
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "PatchApplierUtils.isDuplicate" — it collided
// with `PatchApplierUtilsIsDuplicateTests` in `PatchApplierUtilsTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("PatchApplierUtils.isDuplicate — extended cases")
struct IsDuplicateTests {

    @Test("Exact match is duplicate")
    func exactMatch() {
        let lines = ["- Hello world.", "- Other line."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Hello world.") == true)
    }

    @Test("Case-insensitive match is duplicate")
    func caseInsensitive() {
        let lines = ["- Hello World."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- hello world.") == true)
    }

    @Test("Whitespace-trimmed match is duplicate")
    func whitespaceTrimmed() {
        let lines = ["  - Hello.  "]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Hello.") == true)
    }

    @Test("Non-matching content is not duplicate")
    func notDuplicate() {
        let lines = ["- Other content."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- New content.") == false)
    }

    @Test("Empty lines array returns false")
    func emptyLines() {
        #expect(PatchApplierUtils.isDuplicate(contentLines: [], normalizedContent: "- anything.") == false)
    }

    @Test("Unicode normalize mode matches normalized content")
    func unicodeNormalize() {
        let lines = ["- Hello world."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- Hello world.", unicodeNormalize: true) == true)
    }

    @Test("Unicode normalize mode with non-matching is false")
    func unicodeNormalizeNoMatch() {
        let lines = ["- Other."]
        #expect(PatchApplierUtils.isDuplicate(contentLines: lines, normalizedContent: "- New.", unicodeNormalize: true) == false)
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "PatchApplierUtils.parseOperations" — it collided
// with `PatchApplierUtilsParseOperationsTests` in `PatchApplierUtilsTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("PatchApplierUtils.parseOperations — extended cases")
struct ParseOperationsTests {

    // MARK: - Without action type (KB patches)

    @Test("Parses single ADD operation without action type")
    func singleAddNoAction() {
        let patch = """
        ADD
        New rule content
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].actionType == nil)
        #expect(ops[0].content == "New rule content")
    }

    @Test("Parses single DEL operation without action type")
    func singleDelNoAction() {
        let patch = """
        DEL
        Remove this rule
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "DEL")
        #expect(ops[0].content == "Remove this rule")
    }

    @Test("Parses multiple operations without action type")
    func multipleOpsNoAction() {
        let patch = """
        ADD
        First rule
        DEL
        Second rule
        ADD
        Third rule
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 3)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].content == "First rule")
        #expect(ops[1].operation == "DEL")
        #expect(ops[1].content == "Second rule")
        #expect(ops[2].operation == "ADD")
        #expect(ops[2].content == "Third rule")
    }

    @Test("Multi-line content collected until next operation")
    func multiLineContent() {
        let patch = """
        ADD
        Line one
        Line two
        Line three
        DEL
        Another op
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
        #expect(ops[0].content == "Line one\nLine two\nLine three")
        #expect(ops[1].content == "Another op")
    }

    // MARK: - With action type (action patches)

    @Test("Parses ADD with action type")
    func addWithActionType() {
        let patch = """
        ADD
        delete
        Newsletters and marketing emails
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "ADD")
        #expect(ops[0].actionType == "delete")
        #expect(ops[0].content == "Newsletters and marketing emails")
    }

    @Test("Parses DEL with action type")
    func delWithActionType() {
        let patch = """
        DEL
        archive
        Old rule to remove
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 1)
        #expect(ops[0].operation == "DEL")
        #expect(ops[0].actionType == "archive")
        #expect(ops[0].content == "Old rule to remove")
    }

    @Test("Multiple operations with action type")
    func multipleWithAction() {
        let patch = """
        ADD
        reply
        Emails from my boss
        DEL
        archive
        Duplicate rule
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.count == 2)
        #expect(ops[0].actionType == "reply")
        #expect(ops[1].actionType == "archive")
    }

    @Test("Action type is lowercased")
    func actionTypeLowercased() {
        let patch = """
        ADD
        DELETE
        Some content
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops[0].actionType == "delete")
    }

    // MARK: - Edge cases

    @Test("Empty string returns empty array")
    func emptyString() {
        let ops = PatchApplierUtils.parseOperations("", hasActionType: false)
        #expect(ops.isEmpty)
    }

    @Test("Non-operation lines are skipped")
    func nonOperationSkipped() {
        let patch = """
        some random text
        not an operation
        ADD
        Actual content
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 1)
        #expect(ops[0].content == "Actual content")
    }

    @Test("Case insensitive operation keywords")
    func caseInsensitiveOps() {
        let patch = """
        add
        Content one
        del
        Content two
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 2)
        #expect(ops[0].operation == "ADD")
        #expect(ops[1].operation == "DEL")
    }

    @Test("Carriage returns stripped")
    func carriageReturns() {
        let patch = "ADD\r\nContent here\r\n"
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 1)
        #expect(ops[0].content == "Content here")
    }

    @Test("ADD at end with no content is skipped")
    func addNoContent() {
        let patch = "ADD"
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.isEmpty)
    }

    @Test("ADD with action type but no content is skipped")
    func addActionNoContent() {
        let patch = """
        ADD
        delete
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: true)
        #expect(ops.isEmpty)
    }

    @Test("Whitespace-only content lines collected")
    func whitespaceContent() {
        let patch = """
        ADD
           Content with spaces
        """
        let ops = PatchApplierUtils.parseOperations(patch, hasActionType: false)
        #expect(ops.count == 1)
        #expect(ops[0].content == "Content with spaces")
    }
}
