/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Helpers

private func makeCompositionMarkdown(
    writingStyle: [String] = [],
    language: [String] = [],
    links: [String] = []
) -> String {
    let writingBullets = writingStyle.map { "- \($0)" }.joined(separator: "\n")
    let languageBullets = language.map { "- \($0)" }.joined(separator: "\n")
    let linksBullets = links.map { "- \($0)" }.joined(separator: "\n")
    return """
    # User provided composition instructions
    - Below are the user-defined instructions for composing emails.
    - Strictly follow these instructions in future responses.

    ====BEGIN USER INSTRUCTIONS====


    # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(writingBullets)

    # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(languageBullets)

    # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(linksBullets)

    ====END USER INSTRUCTIONS====

    Now, acknowledge these user instructions and do not deviate from them.
    """
}

private func makeActionMarkdown(
    delete: [String] = [],
    archive: [String] = [],
    reply: [String] = [],
    none: [String] = []
) -> String {
    let deleteBullets = delete.map { "- \($0)" }.joined(separator: "\n")
    let archiveBullets = archive.map { "- \($0)" }.joined(separator: "\n")
    let replyBullets = reply.map { "- \($0)" }.joined(separator: "\n")
    let noneBullets = none.map { "- \($0)" }.joined(separator: "\n")
    return """
    # Action classification instructions

    ====BEGIN USER INSTRUCTIONS====

    # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(deleteBullets)

    # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(archiveBullets)

    # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(replyBullets)

    # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
    \(noneBullets)

    ====END USER INSTRUCTIONS====
    """
}

// MARK: - Tests

@Suite("PromptParser mergeSectionedField — Composition")
struct PromptParserMergeSectionedFieldCompositionTests {

    private let headers = PromptParser.compositionSectionHeaders

    @Test("No changes across any section returns local unchanged")
    func noChanges() {
        let doc = makeCompositionMarkdown(
            writingStyle: ["Be friendly and professional.", "Use Cheers as sign-off."],
            language: ["I write in English Only."],
            links: ["https://example.com"]
        )
        let result = PromptParser.mergeSectionedField(base: doc, local: doc, remote: doc, sectionHeaders: headers)
        #expect(result == doc)
    }

    @Test("Remote adds bullet in one section, others unchanged")
    func remoteAddsBulletInOneSection() {
        let base = makeCompositionMarkdown(
            writingStyle: ["Be friendly."],
            language: ["English only."],
            links: []
        )
        let local = base
        let remote = makeCompositionMarkdown(
            writingStyle: ["Be friendly.", "Keep it concise."],
            language: ["English only."],
            links: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        // Writing style should have both bullets
        let writingSection = PromptParser.extractSection(from: result, header: "General writing style")
        let writingBullets = PromptParser.extractBullets(from: writingSection)
        #expect(writingBullets.contains("Be friendly."))
        #expect(writingBullets.contains("Keep it concise."))

        // Language should be unchanged
        let langSection = PromptParser.extractSection(from: result, header: "Language")
        let langBullets = PromptParser.extractBullets(from: langSection)
        #expect(langBullets == ["English only."])
    }

    @Test("Remote removes bullet in one section, others unchanged")
    func remoteRemovesBulletInOneSection() {
        let base = makeCompositionMarkdown(
            writingStyle: ["Be friendly.", "Be formal."],
            language: ["English only."],
            links: []
        )
        let local = base
        let remote = makeCompositionMarkdown(
            writingStyle: ["Be friendly."],
            language: ["English only."],
            links: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let writingSection = PromptParser.extractSection(from: result, header: "General writing style")
        let writingBullets = PromptParser.extractBullets(from: writingSection)
        #expect(writingBullets == ["Be friendly."])

        // Language unchanged
        let langSection = PromptParser.extractSection(from: result, header: "Language")
        let langBullets = PromptParser.extractBullets(from: langSection)
        #expect(langBullets == ["English only."])
    }

    @Test("Changes in multiple sections merged independently")
    func changesInMultipleSections() {
        let base = makeCompositionMarkdown(
            writingStyle: ["Be friendly."],
            language: ["English only."],
            links: ["https://old.com"]
        )
        let local = base
        let remote = makeCompositionMarkdown(
            writingStyle: ["Be friendly.", "Use short paragraphs."],
            language: ["English only.", "Spanish accepted."],
            links: ["https://old.com", "https://new.com"]
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let writingBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "General writing style"))
        #expect(writingBullets.contains("Be friendly."))
        #expect(writingBullets.contains("Use short paragraphs."))
        #expect(writingBullets.count == 2)

        let langBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Language"))
        #expect(langBullets.contains("English only."))
        #expect(langBullets.contains("Spanish accepted."))
        #expect(langBullets.count == 2)

        let linksBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Useful links to personal website and other resources"))
        #expect(linksBullets.contains("https://old.com"))
        #expect(linksBullets.contains("https://new.com"))
        #expect(linksBullets.count == 2)
    }

    @Test("Local reorders bullets — local ordering preserved with remote additions appended")
    func localReorderPreserved() {
        let base = makeCompositionMarkdown(
            writingStyle: ["First.", "Second.", "Third."],
            language: ["English."],
            links: []
        )
        let local = makeCompositionMarkdown(
            writingStyle: ["Third.", "First.", "Second."],
            language: ["English."],
            links: []
        )
        let remote = makeCompositionMarkdown(
            writingStyle: ["First.", "Second.", "Third.", "Fourth."],
            language: ["English."],
            links: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let writingBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "General writing style"))
        // Local order preserved: Third, First, Second — remote addition Fourth appended
        #expect(writingBullets == ["Third.", "First.", "Second.", "Fourth."])
    }

    @Test("Both local and remote add different bullets to same section — both included")
    func bothAddDifferentBullets() {
        let base = makeCompositionMarkdown(
            writingStyle: ["Original."],
            language: ["English."],
            links: []
        )
        let local = makeCompositionMarkdown(
            writingStyle: ["Original.", "Local addition."],
            language: ["English."],
            links: []
        )
        let remote = makeCompositionMarkdown(
            writingStyle: ["Original.", "Remote addition."],
            language: ["English."],
            links: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let writingBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "General writing style"))
        #expect(writingBullets.contains("Original."))
        #expect(writingBullets.contains("Local addition."))
        #expect(writingBullets.contains("Remote addition."))
        #expect(writingBullets.count == 3)
    }

    @Test("Empty sections handled gracefully")
    func emptySections() {
        let base = makeCompositionMarkdown(
            writingStyle: [],
            language: [],
            links: []
        )
        let local = base
        let remote = makeCompositionMarkdown(
            writingStyle: ["New bullet."],
            language: [],
            links: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let writingBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "General writing style"))
        #expect(writingBullets == ["New bullet."])

        // Other empty sections remain empty (no crash)
        let langBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Language"))
        #expect(langBullets.isEmpty)
    }

    @Test("Section with no bullets — only text — no crash and unmodified")
    func sectionWithNoBullets() {
        // A section that has plain text but no bullet lines
        let doc = """
        # User provided composition instructions
        - Below are the user-defined instructions for composing emails.

        ====BEGIN USER INSTRUCTIONS====

        # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
        Just some plain text without bullet syntax.
        Another line of plain text.

        # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
        - English only.

        # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)

        ====END USER INSTRUCTIONS====
        """
        let result = PromptParser.mergeSectionedField(base: doc, local: doc, remote: doc, sectionHeaders: headers)
        // No crash, and since base == local == remote, result == local
        #expect(result == doc)
    }
}

@Suite("PromptParser mergeSectionedField — Action")
struct PromptParserMergeSectionedFieldActionTests {

    private let headers = PromptParser.actionSectionHeaders

    @Test("Remote adds bullet to one action category")
    func remoteAddsBulletToOneCategory() {
        let base = makeActionMarkdown(
            delete: ["Spam emails."],
            archive: ["Newsletters."],
            reply: [],
            none: []
        )
        let local = base
        let remote = makeActionMarkdown(
            delete: ["Spam emails.", "Marketing promos."],
            archive: ["Newsletters."],
            reply: [],
            none: []
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let deleteBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `delete`"))
        #expect(deleteBullets.contains("Spam emails."))
        #expect(deleteBullets.contains("Marketing promos."))
        #expect(deleteBullets.count == 2)

        // Archive unchanged
        let archiveBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `archive`"))
        #expect(archiveBullets == ["Newsletters."])
    }

    @Test("Changes across multiple action categories merged independently")
    func changesAcrossMultipleCategories() {
        let base = makeActionMarkdown(
            delete: ["Spam."],
            archive: ["Updates."],
            reply: ["Urgent."],
            none: ["Info."]
        )
        let local = base
        let remote = makeActionMarkdown(
            delete: ["Spam.", "Junk."],
            archive: [],
            reply: ["Urgent.", "Questions."],
            none: ["Info."]
        )
        let result = PromptParser.mergeSectionedField(base: base, local: local, remote: remote, sectionHeaders: headers)

        let deleteBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `delete`"))
        #expect(deleteBullets == ["Spam.", "Junk."])

        let archiveBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `archive`"))
        #expect(archiveBullets.isEmpty)

        let replyBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `reply`"))
        #expect(replyBullets == ["Urgent.", "Questions."])

        let noneBullets = PromptParser.extractBullets(from: PromptParser.extractSection(from: result, header: "Emails to be marked as `none`"))
        #expect(noneBullets == ["Info."])
    }
}
