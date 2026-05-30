/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionPatchApplier.applyActionPatch")
struct ActionPatchApplierExtendedTests {

    // Template matching production user_action.md format
    private let baseContent = """
    # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Promotional newsletters from stores.
    # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Automated CI/CD notifications.
    # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Direct questions from team members.
    # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    - Calendar invites.
    """

    // MARK: - ADD operations

    @Test("ADD appends to correct section")
    func addAppendsToSection() {
        let patch = """
        ADD
        delete
        Marketing emails from SaaS companies
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- Marketing emails from SaaS companies."))
    }

    @Test("ADD to archive section")
    func addToArchive() {
        let patch = """
        ADD
        archive
        CodeHub issue notifications
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- CodeHub issue notifications."))
    }

    @Test("ADD to reply section")
    func addToReply() {
        let patch = """
        ADD
        reply
        Emails from my manager
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- Emails from my manager."))
    }

    @Test("ADD to none section")
    func addToNone() {
        let patch = """
        ADD
        none
        FYI emails from legal
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- FYI emails from legal."))
    }

    @Test("ADD duplicate is idempotent (returns original)")
    func addDuplicate() {
        let patch = """
        ADD
        delete
        Promotional newsletters from stores
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result == baseContent) // No change
    }

    // MARK: - DEL operations

    @Test("DEL removes existing entry")
    func delRemovesEntry() {
        let patch = """
        DEL
        delete
        Promotional newsletters from stores
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Promotional newsletters from stores"))
    }

    @Test("DEL for non-existent content returns nil")
    func delNonExistent() {
        let patch = """
        DEL
        delete
        This rule does not exist
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }

    // MARK: - Multiple operations

    @Test("Multiple ADD and DEL operations in sequence")
    func multipleOps() {
        let patch = """
        ADD
        delete
        Spam from unknown senders
        DEL
        archive
        Automated CI/CD notifications
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- Spam from unknown senders."))
        #expect(!result!.contains("Automated CI/CD notifications"))
    }

    // MARK: - Error cases

    @Test("Invalid action type returns nil")
    func invalidActionType() {
        let patch = """
        ADD
        forward
        Some content
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result == nil)
    }

    @Test("Empty patch text returns nil")
    func emptyPatch() {
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: "")
        #expect(result == nil)
    }

    @Test("Patch with only non-operation text returns nil")
    func noOperations() {
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: "just some text")
        #expect(result == nil)
    }

    @Test("ADD to missing section returns nil")
    func addMissingSection() {
        let content = "No sections here"
        let patch = """
        ADD
        delete
        Some rule
        """
        let result = ActionPatchApplier.applyActionPatch(content: content, patchText: patch)
        #expect(result == nil)
    }

    // MARK: - Content normalization

    @Test("ADD normalizes content with bullet and period")
    func addNormalizesContent() {
        let patch = """
        ADD
        delete
        Emails without period or bullet
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(result!.contains("- Emails without period or bullet."))
    }

    @Test("DEL matches case-insensitively")
    func delCaseInsensitive() {
        let patch = """
        DEL
        delete
        PROMOTIONAL NEWSLETTERS FROM STORES
        """
        let result = ActionPatchApplier.applyActionPatch(content: baseContent, patchText: patch)
        #expect(result != nil)
        #expect(!result!.contains("Promotional newsletters from stores"))
    }
}
