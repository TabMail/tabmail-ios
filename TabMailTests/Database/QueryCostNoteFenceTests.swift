/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// The query-cost note stays at every place the app's databases get their schema: the main database's migrations,
/// the notification staging database, the body-asset manifest, the badge table, the search and memory indexes, and
/// the deferred indexes. Whoever adds a table, column, index or query there reads it first.
///
/// - Every entry point in `entryPoints` carries the note, word for word, in the comment directly above its
///   declaration (attributes may sit between).
/// - Every app source file that defines schema (SQL DDL, or GRDB's schema and migration calls) is one of those
///   files, so a new schema site needs the note too, and its place listed here.
@Suite("The query-cost note stays at every schema and migration entry point")
struct QueryCostNoteFenceTests {

    static let note = "QUERY COST (keep this note; QueryCostNoteFenceTests checks it): every query, index, table or "
        + "column added here, and every query that reads them, must be as cheap as the data allows. It must not add "
        + "a new table or index scan unless no index or plainer query can avoid it; then state why at the query. "
        + "Prove a query or index change on a mail-sized database with the DBProof harness "
        + "(TabMailTests/Helpers/DBProofHarness.swift)."

    /// Each schema entry point: its file from the repository root, and how its declaration line starts.
    static let entryPoints: [(file: String, declaration: String)] = [
        ("TabMail/Services/AppDatabase.swift", "static func registerAllMigrations("),
        ("TabMail/Services/AppDatabase.swift", "static func createNSEStagingDB("),
        ("Shared/Persistence/BodyAssetStore.swift", "static func migrateManifestSchema("),
        ("Shared/Persistence/NSEBadge.swift", "enum NSEBadge {"),
        ("TabMailNotificationService/NSEStagingDB.swift", "enum NSEStagingDB {"),
        ("TabMail/Services/Search/SearchIndex.swift", "private func createSchema("),
        ("TabMail/Services/Search/SearchIndex.swift", "private func migrateSchema("),
        ("TabMail/Services/Search/MemoryIndex.swift", "private func createSchema("),
        ("TabMail/Services/Sync/SyncEngineMaintenance.swift", "nonisolated static let deferredIndexes"),
        ("TabMail/Services/HTMLCachePair.swift", "static let indexSQL"),
    ]

    /// The app's source folders: the app, the code it shares with the notification extension, and the extension.
    static let sourceFolders = ["TabMail", "Shared", "TabMailNotificationService"]

    /// A schema definition in Swift source: SQL that creates a table, index or trigger or alters a table, or GRDB's
    /// migration and schema calls.
    static let schemaPattern = #"(?i)\bCREATE\s+(UNIQUE\s+)?(VIRTUAL\s+|TEMP\s+|TEMPORARY\s+)?(TABLE|INDEX|TRIGGER)\b"#
        + #"|\bALTER\s+TABLE\b|\bregister(Timed)?Migration\(|\.create\((table|index|virtualTable):|\.alter\(table:"#

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Database
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repository root
    }

    /// The text of the comment lines among `lines`, in order: comment markers removed, whitespace collapsed to
    /// single spaces.
    static func commentText(_ lines: [String]) -> String {
        let text = lines.compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("///") { return String(line.dropFirst(3)) }
            if line.hasPrefix("//") { return String(line.dropFirst(2)) }
            return nil
        }
        return text.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The comment directly above the first line that starts with `declaration` (attribute lines between are
    /// skipped), as `commentText`; nil when no line starts with `declaration`.
    static func commentAbove(_ declaration: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(declaration) })
        else { return nil }
        var block: [String] = []
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                block.insert(line, at: 0)
            } else if !line.hasPrefix("@") {
                break
            }
            cursor -= 1
        }
        return commentText(block)
    }

    private struct SourceFolderUnreadable: Error {
        let folder: String
    }

    static func definesSchema(_ source: String) -> Bool {
        source.range(of: schemaPattern, options: .regularExpression) != nil
    }

    /// Repository-relative paths of the app source files that define schema.
    private static func schemaFiles() throws -> Set<String> {
        let root = repositoryRoot
        var files: Set<String> = []
        for folder in sourceFolders {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                throw SourceFolderUnreadable(folder: folder)
            }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                guard definesSchema(source) else { continue }
                files.insert(String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        return files
    }

    @Test("The checks themselves: the note directly above a declaration passes; a gap, a changed word or no note fails")
    func checksAreSound() {
        let wrapped = Self.note.split(separator: " ").chunked(into: 9).map { "    /// " + $0.joined(separator: " ") }
        let declaration = "    static func makeSchema(_ db: Database) throws {"
        let above = (["    /// Builds the schema.", "    ///"] + wrapped + ["    @discardableResult", declaration])
            .joined(separator: "\n")
        let aboveText = Self.commentAbove("static func makeSchema(", in: above)
        #expect(aboveText?.contains(Self.note) == true, "the note above the declaration was not found: \(aboveText ?? "nil")")

        let lineComments = (wrapped.map { $0.replacingOccurrences(of: "///", with: "//") } + [declaration])
            .joined(separator: "\n")
        let lineText = Self.commentAbove("static func makeSchema(", in: lineComments)
        #expect(lineText?.contains(Self.note) == true, "the note in // comments was not found")

        let gap = (wrapped + ["", declaration]).joined(separator: "\n")
        let gapText = Self.commentAbove("static func makeSchema(", in: gap)
        #expect(gapText?.contains(Self.note) == false, "a note separated by a blank line counted")

        let changed = above.replacingOccurrences(of: "plainer", with: "simpler")
        let changedText = Self.commentAbove("static func makeSchema(", in: changed)
        #expect(changedText?.contains(Self.note) == false, "a changed note counted")

        #expect(Self.commentAbove("static func otherSchema(", in: above) == nil)

        for schema in ["CREATE INDEX IF NOT EXISTS i ON t(a)", "create unique index i on t(a)",
                       "CREATE VIRTUAL TABLE IF NOT EXISTS f USING fts5(c)", "CREATE TRIGGER x AFTER INSERT ON t",
                       "ALTER TABLE t ADD COLUMN c", #"migrator.registerTimedMigration("v1")"#,
                       #"try db.create(table: "t") { _ in }"#, #"try db.alter(table: "t") { _ in }"#] {
            #expect(Self.definesSchema(schema), "not seen as schema: \(schema)")
        }
        for query in ["SELECT 1 FROM t WHERE a = ?", "UPDATE t SET a = 1", "DROP INDEX IF EXISTS i",
                      "// recreated tables are rare"] {
            #expect(!Self.definesSchema(query), "seen as schema: \(query)")
        }
    }

    @Test("Every schema entry point carries the note directly above its declaration")
    func everyEntryPointCarriesTheNote() throws {
        for entry in Self.entryPoints {
            let url = Self.repositoryRoot.appendingPathComponent(entry.file)
            let source = try String(contentsOf: url, encoding: .utf8)
            let comment = Self.commentAbove(entry.declaration, in: source)
            #expect(comment != nil, "\(entry.file): no line starts with \(entry.declaration)")
            #expect(comment?.contains(Self.note) == true,
                    "\(entry.file): the query-cost note is not directly above \(entry.declaration)")
        }
    }

    @Test("Every app source file that defines schema is a listed entry point's file")
    func everySchemaFileIsListed() throws {
        let schemaFiles = try Self.schemaFiles()
        let listed = Set(Self.entryPoints.map(\.file))
        #expect(schemaFiles.contains("TabMail/Services/AppDatabase.swift"),
                "the schema search found no migrations; the check is vacuous: \(schemaFiles.sorted())")
        let unlisted = schemaFiles.subtracting(listed)
        #expect(unlisted.isEmpty,
                "these files define schema but carry no listed note: put the note above their schema entry point and list it in entryPoints: \(unlisted.sorted())")
        let stale = listed.subtracting(schemaFiles)
        #expect(stale.isEmpty, "listed files that no longer define schema: \(stale.sorted())")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
