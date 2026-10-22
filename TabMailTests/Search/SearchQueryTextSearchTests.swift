/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Whatever a user or a model types, an email search answers, and every word is searched as text
/// (tabmail-ios#246, the tabmail-native-fts #14 and #31 builder, ADR-NF-011). These are the
/// native-fts `db::tests` searches, run on the real FTS5 shards: each search goes through
/// `SearchIndex.keywordSearch`, which throws when FTS5 rejects the MATCH expression. The rows live in
/// their own far-future year and every search is bounded to it, so other suites' rows never match.
@Suite("Search query text reaches FTS5 as text", .serialized, .processGlobalState)
struct SearchQueryTextSearchTests {

    private var index: SearchIndex { SearchIndex.shared }

    private static let accountId = "test_query_text"

    private struct Mail {
        let id: String
        var subject = ""
        var from = ""
        var to = ""
        var cc = ""
        var bcc = ""
        var body = ""
    }

    private static func yearBounds() throws -> (from: Int64, to: Int64) {
        let calendar = Calendar(identifier: .gregorian)
        let start = try #require(calendar.date(from: DateComponents(timeZone: .gmt, year: 2097, month: 1, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(timeZone: .gmt, year: 2097, month: 12, day: 31)))
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    private static func key(_ id: String) -> ContentKey {
        ContentKey(rawValue: "\(accountId):INBOX:\(id)")
    }

    /// Replaces this suite's rows with `mails`, a day apart in its year.
    private func indexMails(_ mails: [Mail]) async throws {
        try await index.removeMessagesForAccount(accountId: Self.accountId)
        let (from, _) = try Self.yearBounds()
        let records = mails.enumerated().map { i, mail in
            FTSHeaderRecord(contentKey: Self.key(mail.id), headerId: Self.key(mail.id).rawValue, messageId: mail.id,
                            subject: mail.subject, from: mail.from, to: mail.to, cc: mail.cc, bcc: mail.bcc,
                            dateMs: from + Int64(i + 1) * 86_400_000)
        }
        let inserted = try await index.indexHeaders(records)
        #expect(inserted == mails.count)
        for mail in mails where !mail.body.isEmpty {
            try await index.updateBody(contentKey: Self.key(mail.id), body: mail.body)
        }
    }

    /// Ids of the mails a keyword search for `q` finds, sorted; throws if the search fails.
    private func found(_ q: String) async throws -> [String] {
        let (from, to) = try Self.yearBounds()
        let prefix = Self.key("").rawValue
        return try await index.keywordSearch(query: q, fromDateMs: from, toDateMs: to, limit: 100)
            .map { String($0.contentKey.rawValue.dropFirst(prefix.count)) }
            .sorted()
    }

    private func cleanUp() async throws {
        try await index.removeMessagesForAccount(accountId: Self.accountId)
    }

    private static let one = Mail(id: "one", subject: "Budget plan for the café", from: "alice@example.com", to: "team@example.com",
                                  body: "R&D notes: 50% off the launch, and the meeting with bob@example.com")
    private static let two = Mail(id: "two", subject: "Greetings", from: "carol@example.com", to: "dave@example.com",
                                  body: "日本語 हिन्दी Привет")

    @Test("no query text makes search fail, and every word is searched as text")
    func readsAnyQueryTextAsText() async throws {
        try await indexMails([Self.one, Self.two])

        // Characters FTS5 would read as syntax, and FTS5 operator words.
        for q in [
            "50% off", "hello!", "a/b", "#launch", "$100", "budget, plan", "invoice OR", "NOT budget",
            "budget NOT", "(budget", "budget)", "AND", "NEAR", "OR budget", "\"unclosed", "\"\"",
            "x^y", "budget -plan", "{budget}", "budget AND", "re:budget", "__FQ0__", "_", "R&D", "f(x)",
            "invoice OR receipt", "\"jane doe\" meeting", "*", "subject:*", "subject:\"\"", "tag:\"urgent\"",
            "msgId:abc", "from : alice",
            // Fields with no value before the next field.
            "from: to: meeting", "subject: cc: budget", "to: body: call", "from: from: invoice",
            // A NUL, which FTS5 reads as the end of the query.
            "budget\u{0}", "budget\u{0}plan", "\"a\u{0}b\"", "\u{0}alice",
        ] {
            _ = try await found(q)
        }

        // Words are searched as typed, punctuation inside them included.
        #expect(try await found("café") == ["one"], "non-ASCII word")
        #expect(try await found("cafe") == ["one"], "without its accent")
        #expect(try await found("50% off") == ["one"])
        #expect(try await found("budget\u{0}") == ["one"], "a NUL separates words")
        for q in ["日本語", "हिन्दी", "Привет"] {
            #expect(try await found(q) == ["two"], "\(q)")
        }
        #expect(try await found("R&D") == ["one"])
        #expect(try await found("budget, plan") == ["one"])
        #expect(try await found("(budget") == ["one"])
        // A name before a colon that is not a field is text: "note" matches "notes".
        #expect(try await found("note: launch") == ["one"])
        // A phrase beside a word that has synonyms.
        #expect(try await found("meeting \"budget plan\"") == ["one"])
        #expect(try await found("\"budget plan\" meeting") == ["one"])

        // The documented fields still scope, whatever their case, with or without a space after the
        // colon: bob@example.com is in the body, not the sender.
        #expect(try await found("from:alice@example.com") == ["one"])
        #expect(try await found("from: \"alice@example.com\"") == ["one"])
        #expect(try await found("from:\"alice@example.com\" launch") == ["one"])
        #expect(try await found("from:bob@example.com") == [])
        #expect(try await found("Subject:budget") == ["one"])
        #expect(try await found("subject:launch") == [])
        #expect(try await found("to:team") == ["one"])
        #expect(try await found("body:launch") == ["one"])
        try await cleanUp()
    }

    @Test("a partial word of 4+ bytes finds the longer word, in any script")
    func findsShortPartialWordsInAnyScript() async throws {
        try await indexMails([
            Mail(id: "p1", subject: "会議は明日です", from: "erin@example.com", to: "team@example.com", body: "Agenda attached."),
            Mail(id: "p2", subject: "Привет", from: "erin@example.com", to: "team@example.com", body: "Greetings."),
            Mail(id: "p3", subject: "Zürich trip", from: "erin@example.com", to: "team@example.com", body: "Tickets."),
        ])
        for (q, id) in [("会議", "p1"), ("При", "p2"), ("Zür", "p3")] {
            #expect(try await found(q) == [id], "\(q)")
        }
        try await cleanUp()
    }

    @Test("a field's value may hold a colon")
    func fieldValueMayHoldAColon() async throws {
        try await indexMails([
            Mail(id: "c1", subject: "Re: budget", from: "erin@example.com", to: "team@example.com", body: "Notes."),
            Mail(id: "c2", subject: "Notes", from: "erin@example.com", to: "team@example.com", body: "Re the budget."),
            Mail(id: "c3", subject: "Link", from: "erin@example.com", to: "team@example.com", body: "See https://example.com/x today."),
            Mail(id: "c4", subject: "https://example.com/x", from: "erin@example.com", to: "team@example.com", body: "Other."),
        ])
        #expect(try await found("subject:Re: budget") == ["c1"])
        #expect(try await found("body:https://example.com/x") == ["c3"])
        try await cleanUp()
    }

    @Test("a possessive looks up its word with the s")
    func possessiveOfAPluralSynonymKeyExpands() async throws {
        try await indexMails([
            Mail(id: "p1", subject: "Thoughts on the deck", from: "erin@example.com", to: "team@example.com", body: "My feedback on the slides"),
            Mail(id: "p2", subject: "Lunch plans", from: "erin@example.com", to: "team@example.com", body: "Pizza on Friday"),
        ])
        for q in ["comment's", "COMMENT'S", "comment\u{2019}s", "COMMENT\u{2019}S"] {
            #expect(try await found(q) == ["p1"], "\(q)")
        }
        try await cleanUp()
    }

    @Test("a kept NOT excludes only the word typed")
    func notExcludesOnlyTheWordTyped() async throws {
        try await indexMails([
            Mail(id: "r1", subject: "Invoice for March", from: "accounts@example.com", to: "team@example.com", body: "The invoice is attached."),
            Mail(id: "r2", subject: "Receipt for March", from: "accounts@example.com", to: "team@example.com", body: "Here is the receipt."),
            Mail(id: "r3", subject: "Payment due in March", from: "accounts@example.com", to: "team@example.com", body: "Please pay soon."),
        ])
        // The left side still expands (payment); only mail with the word typed is excluded.
        #expect(try await found("invoice NOT receipt") == ["r1", "r3"])
        #expect(try await found("March NOT receipt") == ["r1", "r3"])
        // A NOT that is dropped leaves the word a search term with its synonyms.
        #expect(try await found("NOT receipt") == ["r1", "r2", "r3"])
        // A word after a kept AND or OR still expands.
        #expect(try await found("zebra OR receipt") == ["r1", "r2", "r3"])
        #expect(try await found("March AND receipt") == ["r1", "r2", "r3"])
        try await cleanUp()
    }

    @Test("operators between terms, any whitespace, and words with no letter")
    func operatorsSeparatorsAndTextLessWords() async throws {
        try await indexMails([Self.one, Self.two])
        let both = ["one", "two"]

        #expect(try await found("from:alice@example.com OR from:carol@example.com") == both)
        #expect(try await found("from:\"alice@example.com\" OR to:\"dave@example.com\"") == both)
        #expect(try await found("\"budget plan\" OR greetings") == both)
        // Beside a synonym group.
        #expect(try await found("meeting OR greetings") == both)
        #expect(try await found("from:alice@example.com AND from:carol@example.com") == [])
        #expect(try await found("from:alice@example.com AND launch") == ["one"])
        #expect(try await found("from:alice@example.com NOT launch") == [])
        #expect(try await found("from:alice@example.com NOT greetings") == ["one"])
        #expect(try await found("greetings NOT budget") == ["two"])
        // An operator replaces one join: this is café, or greetings and budget.
        #expect(try await found("café OR greetings budget") == ["one"])
        // Not between two terms: dropped.
        #expect(try await found("NOT budget") == ["one"])
        #expect(try await found("OR greetings") == ["two"])
        #expect(try await found("greetings OR") == ["two"])
        #expect(try await found("greetings OR NOT budget") == both)
        #expect(try await found("greetings OR -- budget") == both)

        // Tabs, no-break and ideographic spaces separate words like a space: the words are found
        // apart, not as the phrase "plan budget".
        #expect(try await found("\"plan budget\"") == [])
        for q in ["plan budget", "plan\tbudget", "plan\u{a0}budget", "plan\u{3000}budget"] {
            #expect(try await found(q) == ["one"], "\(q)")
        }

        // A word with no letter or digit, beside words with synonyms (an AND join).
        #expect(try await found("budget ?") == ["one"])
        #expect(try await found("meeting -- \"\"") == ["one"])
        // Letters the tokenizer does not index (enclosed-letter symbols, a lone mark) too.
        for q in ["meeting \u{24d0}", "budget \u{1f17f}\u{fe0f}", "\"\u{24d0}\" meeting", "meeting AND \u{24d0}", "meeting \u{93e}"] {
            #expect(try await found(q) == ["one"], "\(q)")
        }
        try await cleanUp()
    }

    @Test("a private-use character is kept")
    func keepsPrivateUseCharacters() async throws {
        try await indexMails([
            Mail(id: "mark", subject: "Plan \u{e000} launch", from: "alice@example.com", to: "team@example.com"),
            Mail(id: "plain", subject: "Plan launch", from: "alice@example.com", to: "team@example.com"),
        ])
        #expect(try await found("plan \u{e000}") == ["mark"])
        try await cleanUp()
    }

    @Test("a word with an inner apostrophe finds both spellings")
    func findsWordsWithApostrophes() async throws {
        try await indexMails([
            Mail(id: "apostrophe", subject: "Lunch with O'Brien", from: "alice@example.com", to: "team@example.com", body: "Don't forget the receipts."),
            Mail(id: "joined", subject: "Lunch with OBrien", from: "carol@example.com", to: "team@example.com", body: "Dont forget the receipts."),
            Mail(id: "sarah", subject: "Invoice from Sarah", from: "sarah@example.com", to: "team@example.com", body: "Thanks, Sarah"),
            Mail(id: "sarahs", subject: "Sarah's invoice", from: "billing@example.com", to: "team@example.com"),
            Mail(id: "john", subject: "Travel", from: "agent@example.com", to: "team@example.com", body: "John booked the flight to Denver."),
            Mail(id: "team", subject: "Team budget", from: "carol@example.com", to: "team@example.com"),
            Mail(id: "expense", subject: "Travel expense report", from: "agent@example.com", to: "office@example.com"),
            Mail(id: "r5", subject: "Files", from: "agent@example.com", to: "office@example.com", body: "Tommy sent the files."),
            Mail(id: "took", subject: "Bus", from: "agent@example.com", to: "office@example.com", body: "Don took the bus."),
            Mail(id: "noon", subject: "Lunch at noon", from: "agent@example.com", to: "office@example.com", body: "See you there."),
            Mail(id: "r6", subject: "L'\u{e9}tudiant arrives", from: "agent@example.com", to: "office@example.com"),
            Mail(id: "r7", subject: "L\u{e9}tude draft", from: "agent@example.com", to: "office@example.com"),
        ])
        // Never "Don took": a one-letter last part is not a prefix.
        let both = ["apostrophe", "joined"]
        for q in ["O'Brien", "o'brien", "O\u{2019}Brien", "don't forget", "Don't", "Don\u{2019}t", "DON'T"] {
            #expect(try await found(q) == both, "\(q)")
        }
        // A word beside it keeps its prefix star, as beside any word.
        for q in ["don't forg", "forg don't"] {
            #expect(try await found(q) == both, "\(q)")
        }
        // A joined spelling of 4 bytes is a prefix, counted in bytes: "lét" finds "Létude".
        #expect(try await found("l'\u{e9}t") == ["r6", "r7"])
        // A kept NOT excludes both spellings.
        #expect(try await found("lunch NOT don't") == ["noon"])
        // More capital NOTs than FTS5's expression depth allows, beside a spelling group or a
        // synonym group: the first ones exclude, the rest are left out, and the query answers.
        let nots = { (n: Int) in (0..<n).map { " NOT qz" + String(format: "%03d", $0) }.joined() }
        let budget = try await found("'budget'")
        for n in [255, 256, 257, 300] {
            #expect(try await found("don't NOT obrien" + nots(n)) == ["apostrophe"], "\(n) NOTs")
            #expect(try await found("'budget'" + nots(n)) == budget, "\(n) NOTs")
        }
        // A field's value is searched as typed.
        #expect(try await found("subject:O'Brien") == ["apostrophe"])
        // A possessive finds what it names, written with or without the 's.
        for q in ["Sarah's", "Sarah\u{2019}s invoice", "SARAH'S", "Sarah's.", "Sarah's...", "Sarah's,", "(Sarah's)", "Sarah's?"] {
            #expect(try await found(q) == ["sarah", "sarahs"], "\(q)")
        }
        #expect(try await found("John's flight") == ["john"])
        // A short name's possessive stays a prefix, as 0.11.8's `Toms*` was.
        #expect(try await found("Tom's") == ["r5"])
        #expect(try await found("team's budget") == ["team"])
        // Quote marks around a word are not part of it: it still expands to its synonyms.
        #expect(budget == ["expense", "team"])
        try await cleanUp()
    }

    @Test("the automatic prefix star is decided per run of words")
    func prefixStarIsDecidedPerRunOfWords() async throws {
        try await indexMails([
            Mail(id: "sheet", subject: "Roadmapping", from: "alice@example.com", to: "team@example.com", body: "Notesheet from Jane Doe for the meeting"),
            Mail(id: "other", subject: "Roadmapping", from: "alice@example.com", to: "team@example.com", body: "Jane Doe set up the meeting"),
            Mail(id: "r1", subject: "Notesheet for the client", from: "alice@example.com", to: "office@example.com"),
            Mail(id: "r2", subject: "Notes for the customer", from: "alice@example.com", to: "office@example.com"),
            Mail(id: "r3", subject: "Meeting", from: "alex@example.com", to: "office@example.com"),
            Mail(id: "r4", subject: "Meeting", from: "alexandra@example.com", to: "office@example.com"),
        ])
        #expect(try await found("notes \"Jane Doe\" roadmapping meeting") == ["sheet"])
        // A possessive does not expand, so `notes` beside it stays a prefix: this finds
        // "Notesheet", and not the mail that has only a synonym of "client".
        #expect(try await found("client's notes") == ["r1"])
        // A field's value beside a synonym group is not a prefix either.
        for q in ["meeting from:alex", "meeting from: alex"] {
            #expect(try await found(q) == ["r3"], "\(q)")
        }
        try await cleanUp()
    }

    /// The documented fields, written out here so a dropped or wrong entry fails.
    private static let documentedFields = [
        ("subject", "subject"), ("from", "from_"), ("from_", "from_"), ("to", "to_"),
        ("to_", "to_"), ("cc", "cc"), ("bcc", "bcc"), ("body", "body"),
    ]

    private static func oneHot(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: SearchConfig.embeddingDims)
        v[i] = 1
        return v
    }

    @Test("each documented field scopes to its column, in keyword search and the hybrid vector filter")
    func eachDocumentedFieldScopesToItsColumn() async throws {
        let (from, to) = try Self.yearBounds()
        for (typed, column) in Self.documentedFields {
            var inField = Mail(id: "in-field")
            var elsewhere = Mail(id: "elsewhere")
            let value = "zorblax@example.com"
            switch column {
            case "subject": inField.subject = value
            case "from_": inField.from = value
            case "to_": inField.to = value
            case "cc": inField.cc = value
            case "bcc": inField.bcc = value
            default: inField.body = value
            }
            if column == "body" { elsewhere.subject = value } else { elsewhere.body = value }
            try await indexMails([inField, elsewhere])

            for q in ["\(typed):\(value)", "\(typed.uppercased()): \(value)"] {
                #expect(try await found(q) == ["in-field"], "\(q)")
            }
            #expect(try await found(value) == ["elsewhere", "in-field"], "\(typed)")

            // Both rows are the query's nearest vectors; only the field's match is eligible.
            for id in ["in-field", "elsewhere"] {
                try await index.storeEmbedding(contentKey: Self.key(id), embedding: Self.oneHot(5))
            }
            let hybrid = try await index.hybridSearch(
                ftsQuery: SearchQueryParser.buildFTSMatch("\(typed):\"\(value)\" meeting"), queryEmbedding: Self.oneHot(5),
                fromDateMs: from, toDateMs: to, limit: 100, folderIds: nil)
            #expect(hybrid.map(\.contentKey) == [Self.key("in-field")], "\(typed)")
        }
        try await cleanUp()
    }

    /// Words that may be typed together, joined at random: no query makes search fail. The same
    /// fragments as tabmail-native-fts `QUERY_FRAGMENTS`.
    private static let queryFragments = [
        "from:", "From:", "to:", "cc:", "bcc:", "subject:", "body:", "from_:", "to_:", "note:", ":", "re:",
        "meeting", "budget", "plan", "call", "invoice", "done", "AND", "OR", "NOT", "NEAR", "\"",
        "\"budget plan\"", "(", ")", "*", "-", "^", "+", "%", "!", "?", "/", "'", ",", ".", "@", "#", "$",
        "&", "{", "}", "[", "]", "~", "`", "\\", "|", "<", ">", "=", ";", "_", "café", "日本語", "हिन्दी",
        "Привет", "ⓐ", "\u{301}", "😀", "\u{a0}", "\u{3000}", "\u{200b}", "\u{feff}", "\u{2028}",
        "\u{e000}", "\u{1}", "\u{0}", "\t", " ", "a@example.com", "don't", "O\u{2019}Brien", "I'm",
    ]

    /// `count` queries of 1 to 7 fragments, from a fixed seed, so a failure repeats.
    private static func randomQueries(_ count: Int) -> [String] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        return (0..<count).map { _ in
            let n = 1 + Int(next() % 7)
            var q = ""
            for _ in 0..<n {
                q += queryFragments[Int(next() % UInt64(queryFragments.count))]
                if next() % 2 == 0 {
                    q += " "
                }
            }
            return q
        }
    }

    @Test("no seeded random query makes keyword or hybrid search fail")
    func noQueryTextMakesSearchFail() async throws {
        let (from, to) = try Self.yearBounds()
        try await indexMails([Mail(id: "one", subject: "Budget plan meeting", from: "alice@example.com",
                              to: "team@example.com", body: "the call about the invoice")])
        try await index.storeEmbedding(contentKey: Self.key("one"), embedding: Self.oneHot(5))
        var hybridRuns = 0
        for q in Self.randomQueries(3000) {
            _ = try await found(q)
            // The hybrid path, as `search` reaches it: only with a keyword term.
            let ftsQuery = SearchQueryParser.buildFTSMatch(q)
            if !ftsQuery.isEmpty {
                _ = try await index.hybridSearch(ftsQuery: ftsQuery, queryEmbedding: Self.oneHot(5),
                                                 fromDateMs: from, toDateMs: to, limit: 10, folderIds: nil)
                hybridRuns += 1
            }
        }
        #expect(hybridRuns > 0)
        // A scoped contraction, one under a kept NOT, and more NOTs than FTS5's depth allows.
        let nots = (0..<300).map { " NOT qz" + String(format: "%03d", $0) }.joined()
        for q in ["subject: O'Brien don't", "subject:lunch don't", "don't NOT O'Brien", "budget" + nots, "don't" + nots] {
            _ = try await index.hybridSearch(ftsQuery: SearchQueryParser.buildFTSMatch(q), queryEmbedding: Self.oneHot(5),
                                             fromDateMs: from, toDateMs: to, limit: 10, folderIds: nil)
        }
        try await cleanUp()
    }
}
