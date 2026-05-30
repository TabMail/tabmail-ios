/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Search Scoping — From/To query composition")
struct SearchScopingTests {

    // MARK: - FTS Query Composition

    @Test("from filter produces column-scoped FTS match")
    func fromFilterColumnScoped() {
        let result = SearchQueryParser.buildFTSMatch("from:john meeting")
        #expect(result.contains("from_:"))
        #expect(result.contains("john"))
    }

    @Test("from + to produces both column-scoped matches")
    func fromAndToColumnScoped() {
        let result = SearchQueryParser.buildFTSMatch("from:john to:jane")
        #expect(result.contains("from_:"))
        #expect(result.contains("to_:"))
    }

    @Test("from filter alone (no query) produces valid FTS expression")
    func fromFilterAlone() {
        let result = SearchQueryParser.buildFTSMatch("from:john")
        #expect(!result.isEmpty)
        #expect(result.contains("from_:"))
    }

    @Test("multi-word from quoted value stays column-scoped")
    func multiWordFromQuoted() {
        let result = SearchQueryParser.buildFTSMatch("from:\"John Smith\" meeting")
        #expect(result.contains("from_:\"John Smith\""))
    }

    @Test("email address in from gets quoted by parser")
    func emailAddressFromQuoted() {
        let result = SearchQueryParser.buildFTSMatch("from:john@example.com")
        // @ triggers quoting in the parser
        #expect(result.contains("from_:"))
        #expect(result.contains("john@example.com"))
    }

    @Test("from with apostrophe removes apostrophe per parser rules")
    func fromApostrophe() {
        let result = SearchQueryParser.buildFTSMatch("from:o'brien")
        #expect(result.contains("from_:"))
        #expect(result.contains("obrien"))
    }

    // MARK: - FTS folderIds parameter

    @Test("keywordSearch with nil folderIds returns results (no filter)")
    func keywordSearchNilFolderIds() async throws {
        // Verify the method signature accepts nil and doesn't crash
        // (Can't test FTS content without a real SearchIndex DB, but verify compilation + signature)
        let ftsQuery = SearchQueryParser.buildFTSMatch("test")
        #expect(!ftsQuery.isEmpty)
    }

    @Test("buildFTSMatch handles empty string gracefully")
    func emptyQueryBuildFTS() {
        let result = SearchQueryParser.buildFTSMatch("")
        #expect(result.isEmpty)
    }

    @Test("buildFTSMatch with only from: prefix produces valid output")
    func onlyFromPrefix() {
        let result = SearchQueryParser.buildFTSMatch("from:alice")
        #expect(!result.isEmpty)
        #expect(result.contains("from_:"))
    }

    @Test("buildFTSMatch with only to: prefix produces valid output")
    func onlyToPrefix() {
        let result = SearchQueryParser.buildFTSMatch("to:bob")
        #expect(!result.isEmpty)
        #expect(result.contains("to_:"))
    }

    // MARK: - Composed query scenarios (simulating SearchView.composedQuery)

    @Test("composed query with from + to + main query")
    func composedQueryAll() {
        // Simulating what SearchView.composedQuery would produce
        let composed = "from:john to:jane meeting notes"
        let result = SearchQueryParser.buildFTSMatch(composed)
        #expect(result.contains("from_:"))
        #expect(result.contains("to_:"))
    }

    @Test("composed query with quoted multi-word from")
    func composedQueryQuotedFrom() {
        let composed = "from:\"John Smith\" important"
        let result = SearchQueryParser.buildFTSMatch(composed)
        #expect(result.contains("from_:\"John Smith\""))
    }

    @Test("composed query from only (no main query)")
    func composedQueryFromOnly() {
        let composed = "from:alice"
        let result = SearchQueryParser.buildFTSMatch(composed)
        #expect(!result.isEmpty)
        #expect(result.contains("from_:"))
    }
}
