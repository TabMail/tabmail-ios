/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing

/// An email's TabMail chat is keyed by its thread, `thread:<accountId>:<computedThreadId>`
/// (ADR-IOS-114 decision 14), and the reader finds a thread's chats through the thread ids its
/// emails carry NOW. So a write that changes `computedThreadId` on an EXISTING row strands the
/// chat stored under the old id unless the same change moves the thread chats to the new key.
///
/// No write does that today: the only rewrite of an existing row is the fragment merge
/// (`ThreadUtils.runFragmentMergeOnce`), and its only caller is migration `v54`, which runs before
/// `v107` creates thread keys, so there is no chat to move. This fence keeps it that way. It reads
/// the source of every app and extension target listed in `project.yml` at run time and fails on:
///
/// - any caller of the fragment merge (`runFragmentMergeOnce`, or `runFragmentMergeToFixpoint`,
///   which runs it) other than a migration registered before v107;
/// - a write of `computedThreadId` anywhere but the listed sites below: a Swift assignment
///   (`computedThreadId =`), an SQL `SET … computedThreadId =`, a GRDB
///   `Column("computedThreadId").set(to:)`, or a call of `ThreadUtils.assignComputedThreadId` /
///   `ThreadUtils.findAdoptableThreadId`, which decide a thread id for a write. The listed sites
///   write a header built for its insert or an in-memory copy, except the fragment merge's SET;
/// - in `AppDatabase.swift`, a write outside a migration, a migration before v107 not listed with
///   its exact counts, and any write in a migration from v107 on (when chats are keyed by thread).
///
/// Each failure says what a new caller or write must do: move the thread chats to the new key in
/// the same change. The second test plants each violation into the real sources and checks the
/// fence fails it.
@Suite("Only known places write computedThreadId; the fragment merge runs only in migrations before thread chat keys")
struct ThreadIdWriteFenceTests {

    enum Rule: String, CaseIterable {
        /// A Swift assignment of `computedThreadId`.
        case assigned
        /// An SQL `SET` of `computedThreadId`.
        case sqlSet
        /// A GRDB column assignment of `computedThreadId`.
        case columnSet
        /// A call that decides a thread id for a write.
        case threadIdDecided
    }

    /// Pattern per rule; `true` matches against code with string contents kept (SQL lives in
    /// strings), `false` against code with comments and strings blanked.
    static let patterns: [Rule: (String, Bool)] = [
        .assigned: (#"(?<![A-Za-z0-9_$])computedThreadId\s*=(?!=)"#, false),
        .sqlSet: (#"(?is)\bSET\s(?:(?!\bWHERE\b|\bFROM\b|;).){0,400}?\bcomputedThreadId\s*=(?!=)"#, true),
        .columnSet: (#"Column\s*\(\s*"computedThreadId"\s*\)\s*\.\s*set\s*\("#, true),
        .threadIdDecided: (#"\bThreadUtils\s*\.\s*(assignComputedThreadId|findAdoptableThreadId)\s*\("#, false),
    ]

    /// Every mention of the fragment merge's two entry points: a call, or a reference that could be
    /// called later. A match with group 1 (`func `) is the declaration and is skipped. Matched in
    /// code with comments and strings blanked.
    static let mergeMention = #"(\bfunc\s+)?\b(runFragmentMergeOnce|runFragmentMergeToFixpoint)\b"#

    /// What every failure tells the author of a new caller or write.
    static let mustMoveChats = "a new caller or write of computedThreadId on an existing row must move the thread chats to their new key (thread:<accountId>:<computedThreadId>, ADR-IOS-114 decision 14) in the same change, then be listed in ThreadIdWriteFenceTests"

    static let migrationsFile = "TabMail/Services/AppDatabase.swift"
    static let mergeFile = "TabMail/Helpers/ThreadUtils.swift"
    static let mergeFunction = "runFragmentMergeOnce"
    static let mergeLoopFunction = "runFragmentMergeToFixpoint"
    /// `v107_rekeyChatSessionsByThread` keyed chats by thread. The migrations before it ran while
    /// chats were keyed by email, so their rewrites of `computedThreadId` strand no chat.
    static let firstThreadKeyedMigration = 107

    /// Write sites outside `AppDatabase.swift`: file → rule → exact count. A new site, or a removed
    /// one, fails until listed here with its reason.
    static let allowedSites: [String: [Rule: Int]] = [
        // `assignComputedThreadId` sets a header built for its insert (3); the fragment merge's SET
        // (1), checked below to sit in the merge, whose callers are checked too.
        "TabMail/Helpers/ThreadUtils.swift": [.assigned: 3, .sqlSet: 1],
        // In-memory display snapshots: adoption for a staged or arriving row, kept on reload.
        "TabMail/ViewModels/InboxViewModel.swift": [.assigned: 2],
        "TabMail/ViewModels/InboxListComposer.swift": [.assigned: 1],
        // A display snapshot's copy of its header.
        "TabMail/Models/MessageSnapshot.swift": [.assigned: 1],
        // Demo and test-scene headers built for their insert.
        "TabMail/Services/Demo/DemoSeed.swift": [.assigned: 1],
        "TabMail/Views/Compose/ServerDraftCloseTestScene.swift": [.assigned: 1],
        // Insert paths: `assignComputedThreadId` on a header built for its insert.
        "TabMail/Services/NSEDataBridge.swift": [.threadIdDecided: 1],
        "TabMail/Services/Account/AccountManagerOutbox.swift": [.threadIdDecided: 1],
        "TabMail/Services/Sync/SyncEngine.swift": [.threadIdDecided: 1],
        "TabMail/Services/Sync/SyncEngineChangesApply.swift": [.threadIdDecided: 1],
        "TabMail/Services/Sync/SyncEngineBackfillDeep.swift": [.threadIdDecided: 1],
        "TabMail/Services/Sync/SyncEngineFullSync.swift": [.threadIdDecided: 1],
    ]

    /// Migrations before v107 that write `computedThreadId`: name → rule → exact count. No thread
    /// chat key existed when they ran.
    static let allowedEarlyMigrations: [String: [Rule: Int]] = [
        "v27_computedThreadId": [.sqlSet: 2],
        "v47_lateralThreadRepair": [.sqlSet: 1, .threadIdDecided: 1],
    ]

    // MARK: - Reading

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    /// Every Swift source of the app and extension targets, by repository-relative path.
    static func productSources() throws -> [String: String] {
        let root = repositoryRoot()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let roots = FixedDateFormatFenceTests.productSourceRoots(projectYML: yml)
        #expect(roots.unparsed.isEmpty, "project.yml entries the reader could not read: \(roots.unparsed)")
        #expect(roots.roots.isSuperset(of: FixedDateFormatFenceTests.requiredSourceRoots), "source roots: \(roots.roots)")
        var sources: [String: String] = [:]
        for sourceRoot in roots.roots.sorted() {
            let base = root.appendingPathComponent(sourceRoot)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                sources[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return sources
    }

    struct Finding: Sendable {
        let rule: Rule
        /// In characters: `codeOnly` keeps every character's position, so offsets agree across
        /// the source and both of its code texts (UTF-16 offsets would not: it blanks a
        /// two-unit character to one space).
        let offset: Int
        let line: Int
    }

    static func characterOffset(_ utf16Offset: Int, in text: String) -> Int {
        text.distance(from: text.startIndex, to: String.Index(utf16Offset: utf16Offset, in: text))
    }

    static func lineNumber(_ text: NSString, _ offset: Int) -> Int {
        text.substring(to: offset).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// `FixedDateFormatFenceTests.codeOnly`, read once per source: the planted-write test checks
    /// the whole app many times over with one file changed.
    static let codeMemo = Mutex<[String: [Character]]>([:])

    static func stripped(_ source: String, keepStrings: Bool = false) -> [Character] {
        let key = (keepStrings ? "s" : "c") + source
        if let hit = codeMemo.withLock({ $0[key] }) { return hit }
        let result = FixedDateFormatFenceTests.codeOnly(source, keepStrings: keepStrings)
        codeMemo.withLock { $0[key] = result }
        return result
    }

    static func findings(in source: String) -> [Finding] {
        // Every pattern names `computedThreadId` or `ThreadUtils`; a source without either has none.
        guard source.contains("computedThreadId") || source.contains("ThreadUtils") else { return [] }
        let code = String(stripped(source)) as NSString
        let codeWithStrings = String(stripped(source, keepStrings: true)) as NSString
        var result: [Finding] = []
        for rule in Rule.allCases {
            guard let (pattern, keepStrings) = patterns[rule] else { continue }
            let text = keepStrings ? codeWithStrings : code
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                result.append(Finding(
                    rule: rule, offset: characterOffset(match.range.location, in: text as String),
                    line: lineNumber(text, match.range.location)))
            }
        }
        return result.sorted { $0.offset < $1.offset }
    }

    static func counts(_ findings: [Finding]) -> [Rule: Int] {
        findings.reduce(into: [:]) { $0[$1.rule, default: 0] += 1 }
    }

    /// The code of `function`'s body (comments blanked, strings kept), with its character range
    /// in `source`. Braces are matched in the code with strings blanked.
    static func functionBody(_ function: String, in source: String) -> (range: Range<Int>, text: String)? {
        let code = stripped(source)
        let withStrings = stripped(source, keepStrings: true)
        let codeText = String(code)
        let declaration = (codeText as NSString).range(of: #"\bfunc\s+\#(function)\s*\("#, options: .regularExpression)
        guard declaration.location != NSNotFound else { return nil }
        let start = characterOffset(declaration.location, in: codeText)
        guard let open = code[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        for index in open..<code.count {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return (open..<(index + 1), String(withStrings[open...index])) }
            }
        }
        return nil
    }

    struct Migration {
        let name: String
        let version: Int?
        let range: Range<Int>
    }

    /// The migrations registered in `source`, each spanning to the next registration (the last to
    /// the end of the file).
    static func migrations(in source: String) -> [Migration] {
        let text = String(stripped(source, keepStrings: true))
        let regex = try! NSRegularExpression(pattern: #"\bregister(?:Timed)?Migration\s*\(\s*"([^"]+)""#)
        let found = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        let starts = found.map { characterOffset($0.range.location, in: text) }
        return found.enumerated().map { index, match in
            let name = (text as NSString).substring(with: match.range(at: 1))
            let end = index + 1 < starts.count ? starts[index + 1] : text.count
            let version = name.range(of: #"^v(\d+)_"#, options: .regularExpression)
                .flatMap { Int(name[$0].dropFirst().dropLast()) }
            return Migration(name: name, version: version, range: starts[index]..<end)
        }
    }

    /// Every violation of the fence in `sources` (repository-relative path → source).
    static func violations(in sources: [String: String]) -> [String] {
        var problems: [String] = []
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            problems += callerViolations(path: path, source: source)
            let found = findings(in: source)
            if path == migrationsFile {
                problems += migrationViolations(source: source, findings: found)
                continue
            }
            let allowed = allowedSites[path] ?? [:]
            if counts(found) != allowed {
                let lines = found.map { "\($0.rule.rawValue)@\($0.line)" }.joined(separator: ", ")
                problems.append("\(path): writes computedThreadId at \(lines); allowed \(allowed); \(mustMoveChats)")
            }
            if path == mergeFile {
                problems += mergeViolations(source: source, findings: found)
            }
        }
        for path in allowedSites.keys.sorted() where sources[path] == nil {
            problems.append("\(path): listed but not among the sources (moved? update the list)")
        }
        if sources[migrationsFile] == nil { problems.append("\(migrationsFile): not among the sources") }
        if sources[mergeFile] == nil { problems.append("\(mergeFile): not among the sources") }
        return problems
    }

    /// The fragment merge's callers in `source`. Allowed: `runFragmentMergeOnce` from the merge's
    /// own loop (`runFragmentMergeToFixpoint`), and either entry point from a migration registered
    /// before v107. Anything else (app code at run time, a migration from v107 on, a helper of
    /// `AppDatabase.swift` outside a migration) fails.
    static func callerViolations(path: String, source: String) -> [String] {
        guard source.contains("runFragmentMerge") else { return [] }
        let code = String(stripped(source))
        let regex = try! NSRegularExpression(pattern: mergeMention)
        let loop = path == mergeFile ? functionBody(mergeLoopFunction, in: source)?.range : nil
        let registered = path == migrationsFile ? migrations(in: source) : []
        var problems: [String] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) {
            if match.range(at: 1).location != NSNotFound { continue }
            let name = (code as NSString).substring(with: match.range(at: 2))
            let offset = characterOffset(match.range.location, in: code)
            let line = lineNumber(code as NSString, match.range.location)
            if name == mergeFunction, let loop, loop.contains(offset) { continue }
            if let migration = registered.last(where: { $0.range.lowerBound <= offset }),
               let version = migration.version, version < firstThreadKeyedMigration {
                continue
            }
            problems.append("\(path):\(line): \(name) is called outside a migration before v\(firstThreadKeyedMigration): the fragment merge rewrites computedThreadId on existing rows; \(mustMoveChats)")
        }
        return problems
    }

    /// The merge's SET of `computedThreadId` sits in `runFragmentMergeOnce`, whose callers
    /// `callerViolations` checks.
    static func mergeViolations(source: String, findings found: [Finding]) -> [String] {
        guard let body = functionBody(mergeFunction, in: source) else {
            return ["\(mergeFile): no func \(mergeFunction) (moved? update the fence)"]
        }
        guard functionBody(mergeLoopFunction, in: source) != nil else {
            return ["\(mergeFile): no func \(mergeLoopFunction) (moved? update the fence)"]
        }
        let sets = found.filter { $0.rule == .sqlSet }
        if sets.isEmpty || !sets.allSatisfy({ body.range.contains($0.offset) }) {
            return ["\(mergeFile): the SET of computedThreadId is not in \(mergeFunction); \(mustMoveChats)"]
        }
        return []
    }

    static func migrationViolations(source: String, findings found: [Finding]) -> [String] {
        let registered = migrations(in: source)
        var problems: [String] = []
        var byMigration: [String: [Finding]] = [:]
        for finding in found {
            guard let migration = registered.last(where: { $0.range.lowerBound <= finding.offset }) else {
                problems.append("\(migrationsFile): \(finding.rule.rawValue)@\(finding.line) writes computedThreadId outside a migration; \(mustMoveChats)")
                continue
            }
            byMigration[migration.name, default: []].append(finding)
        }
        for migration in registered {
            let writes = byMigration[migration.name] ?? []
            guard let version = migration.version else {
                if !writes.isEmpty { problems.append("\(migrationsFile): \(migration.name) has no version and writes computedThreadId; \(mustMoveChats)") }
                continue
            }
            let lines = writes.map { "\($0.rule.rawValue)@\($0.line)" }.joined(separator: ", ")
            if version < firstThreadKeyedMigration {
                let allowed = allowedEarlyMigrations[migration.name] ?? [:]
                if counts(writes) != allowed {
                    problems.append("\(migrationsFile): \(migration.name) writes computedThreadId at \(lines); allowed \(allowed)")
                }
            } else if !writes.isEmpty {
                problems.append("\(migrationsFile): \(migration.name) rewrites computedThreadId at \(lines) after v\(firstThreadKeyedMigration) keyed chats by thread; \(mustMoveChats)")
            }
        }
        for name in allowedEarlyMigrations.keys.sorted() where !registered.contains(where: { $0.name == name }) {
            problems.append("\(migrationsFile): \(name) listed but not registered")
        }
        return problems
    }

    // MARK: - Tests

    @Test("Every write of computedThreadId is a listed insert-time or in-memory site, the fragment merge run only by migrations before v107, or an early migration")
    func onlyListedWrites() throws {
        let sources = try Self.productSources()
        #expect(sources.count > 100, "control: the app's sources are read: \(sources.count)")
        let problems = Self.violations(in: sources)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("The fence fails a planted write or merge caller: a run-time caller, a late migration, a new app write")
    func fenceCatchesPlantedWrites() throws {
        let sources = try Self.productSources()
        #expect(Self.violations(in: sources).isEmpty, "control: the real sources pass")
        let merge = try #require(sources[Self.mergeFile])
        let database = try #require(sources[Self.migrationsFile])
        let syncEngine = try #require(sources["TabMail/Services/Sync/SyncEngine.swift"])
        let v107 = try #require(database.range(of: #"migrator\.registerTimedMigration\(\s*"v107_"#, options: .regularExpression))
        func planted(_ path: String, _ source: String) -> [String] {
            var copy = sources
            copy[path] = source
            return Self.violations(in: copy)
        }
        func callerFailure(_ problems: [String], _ path: String) -> Bool {
            problems.contains { $0.contains(path) && $0.contains("outside a migration before v107") && $0.contains("must move the thread chats") }
        }

        // The fragment merge's callers.
        let runtimeOnce = planted("TabMail/Services/Sync/SyncEngine.swift", syncEngine
            + "\nextension SyncEngine { func plantedRethread(db: Database) throws { _ = try ThreadUtils.runFragmentMergeOnce(db: db) } }\n")
        #expect(callerFailure(runtimeOnce, "SyncEngine.swift"), "a run-time caller of runFragmentMergeOnce: \(runtimeOnce)")

        let runtimeLoop = planted("TabMail/Services/Planted.swift", "func planted(db: Database) throws { try ThreadUtils.runFragmentMergeToFixpoint(db: db) }\n")
        #expect(callerFailure(runtimeLoop, "Planted.swift"), "a run-time caller of runFragmentMergeToFixpoint: \(runtimeLoop)")

        let reference = planted("TabMail/Services/Planted.swift", "let planted = ThreadUtils.runFragmentMergeOnce\n")
        #expect(callerFailure(reference, "Planted.swift"), "a reference to the merge, called later: \(reference)")

        let mergeHelper = merge.replacingOccurrences(
            of: "    static func \(Self.mergeFunction)(",
            with: "    static func plantedRethread(db: Database) throws { _ = try runFragmentMergeOnce(db: db) }\n    static func \(Self.mergeFunction)(")
        #expect(mergeHelper != merge, "control: the ThreadUtils plant applied")
        let helper = planted(Self.mergeFile, mergeHelper)
        #expect(callerFailure(helper, Self.mergeFile), "a caller in ThreadUtils outside the merge's loop: \(helper)")

        let lateCaller = "migrator.registerTimedMigration(\"v108_plantedRethread\") { db in\n"
            + "    try ThreadUtils.runFragmentMergeToFixpoint(db: db)\n}\n"
        var lateMerge = database
        lateMerge.insert(contentsOf: lateCaller, at: v107.lowerBound)
        let lateMerged = planted(Self.migrationsFile, lateMerge)
        #expect(callerFailure(lateMerged, Self.migrationsFile), "a migration from v107 on that runs the merge: \(lateMerged)")

        // Writes of computedThreadId.
        let appWrite = planted("TabMail/Services/AI/ChatStore.swift", (sources["TabMail/Services/AI/ChatStore.swift"] ?? "")
            + "\nlet plantedRethread = \"UPDATE messageHeader SET isRead = 1, computedThreadId = ? WHERE id = ?\"\n")
        #expect(appWrite.contains { $0.contains("ChatStore.swift") && $0.contains("must move the thread chats") }, "an SQL write in app code: \(appWrite)")

        let swiftWrite = planted("TabMail/Services/Planted.swift", "func planted(_ h: inout MessageHeader) { h.computedThreadId = \"x\" }\n")
        #expect(swiftWrite.contains { $0.contains("Planted.swift") }, "a Swift write in a new file: \(swiftWrite)")

        let columnWrite = planted("TabMail/Services/Planted.swift", "let planted = Column(\"computedThreadId\").set(to: \"x\")\n")
        #expect(columnWrite.contains { $0.contains("Planted.swift") }, "a column write: \(columnWrite)")

        let decided = planted("TabMail/Services/Planted.swift", "func planted(db: Database) throws { try ThreadUtils.assignComputedThreadId(to: &h, nativeThreadId: nil, db: db) }\n")
        #expect(decided.contains { $0.contains("Planted.swift") }, "a thread id decided outside the insert paths: \(decided)")

        let movedSet = merge.replacingOccurrences(
            of: "    static func \(Self.mergeFunction)(",
            with: "    static func plantedRethread(db: Database) throws { try db.execute(sql: \"UPDATE messageHeader SET computedThreadId = ? WHERE id = ?\") }\n    static func \(Self.mergeFunction)(")
        let outsideMerge = planted(Self.mergeFile, movedSet)
        #expect(outsideMerge.contains { $0.contains("not in \(Self.mergeFunction)") }, "a second SET in ThreadUtils outside the merge: \(outsideMerge)")

        let lateMigration = "migrator.registerTimedMigration(\"v108_plantedRethread\") { db in\n"
            + "    try db.execute(sql: \"UPDATE messageHeader SET computedThreadId = id\")\n}\n"
        var late = database
        late.insert(contentsOf: lateMigration, at: v107.lowerBound)
        let lateWrite = planted(Self.migrationsFile, late)
        #expect(lateWrite.contains { $0.contains("v108_plantedRethread") && $0.contains("must move the thread chats") }, "a late migration write: \(lateWrite)")

        let earlyWrite = database.replacingOccurrences(
            of: "migrator.registerTimedMigration(\"v53_backfillIsRepliedFromSentReplies\") { db in\n",
            with: "migrator.registerTimedMigration(\"v53_backfillIsRepliedFromSentReplies\") { db in\n    try db.execute(sql: \"UPDATE messageHeader SET computedThreadId = id\")\n")
        #expect(earlyWrite != database, "control: the early plant applied")
        let early = planted(Self.migrationsFile, earlyWrite)
        #expect(early.contains { $0.contains("v53_backfillIsRepliedFromSentReplies") }, "an unlisted early migration write: \(early)")
    }
}
