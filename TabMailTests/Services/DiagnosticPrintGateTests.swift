/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Global `CLAUDE.md` rule 12 over the whole app target.
///
/// `TabMail/tabmail-ios#72` measured ~1,500 ungated `print` sites. They now go
/// through `BackgroundSyncLogger.logDebug`, whose gate `AppLogStoreTests` pins.
/// This suite keeps the two properties that sweep depends on:
///
/// 1. Every console sink (`print`, `NSLog`, `os_log`) is lexically debug-gated,
///    unless it is an always-on façade's own echo or one of the three registered
///    `🚨 UNGATED BY DECISION` sinks.
/// 2. No `logDebug` call sits inside a database write context. `logDebug` appends
///    to `tabmail.log`, which no SQLite `ROLLBACK` retracts, so a line emitted there
///    can claim a write that never committed (root rule 12, 2026-09-05 addendum).
///    A line there stays a console `print` under
///    `if DebugModeManager.isLoggingEnabled() {`, and property 1 checks that gate.
///
/// Gate recognition is `RenderPathLogSinkTests.lex`: canonical spellings only, and
/// FAIL-CLOSED, so a correctly gated sink in an unrecognised shape reads as
/// ungated and fails here. Rewrite that sink in the canonical shape, or route it
/// through `logDebug`, rather than widening the lexer.
@Suite("Diagnostic console sinks in the app target are debug-gated")
struct DiagnosticPrintGateTests {

    // MARK: - Property 1: every console sink is gated or registered

    /// Always-on façades whose console echo is part of the writer by design.
    static let alwaysOnFacadeFiles: Set<String> = [
        "TabMail/Services/BackgroundSyncLogger.swift",
        "TabMail/Services/AuthDiagnostics.swift",
    ]

    static let sinkTokens = ["print(", "NSLog(", "os_log("]
    /// `Swift.print(` is the same sink as `print(`; any other `x.print(` is a method.
    static let moduleQualifiers = ["Swift.", "Foundation."]
    static let decisionMarker = "🚨 UNGATED BY DECISION"
    /// The marker is a comment block above its sink; the three current blocks sit
    /// 14–17 lines up. The window is bounded so a marker cannot license a sink in
    /// an unrelated later statement, and no other sink may sit in between.
    static let decisionWindowLines = 25
    /// The registered decisions, by file and call prefix, so a marker cannot license
    /// a different sink by moving. A new one is a new owner decision, added here.
    static let registeredDecisions: [(file: String, call: String)] = [
        ("TabMail/Services/Account/AccountOperationExecutor.swift",
         #"print("[Queue] CRITICAL: Failed to retire completed PendingOperation "#),
        ("TabMail/Services/Account/AccountOperationExecutor.swift",
         #"print("[Queue] Identity refused in "#),
        ("TabMail/Services/Account/AccountOperationExecutor.swift",
         #"print("[Queue] CRITICAL: could not narrow partially-completed "#),
    ]

    struct ScanResult {
        var sinks = 0
        var gated = 0
        var decisions: [String] = []
        /// `file|<the call to the end of its line>` for each entry in `decisions`.
        var decisionCalls: [String] = []
        var violations: [String] = []
    }

    static func scan(source: String, file: String) -> ScanResult {
        var result = ScanResult()
        let (gates, comments) = RenderPathLogSinkTests.lex(source)
        var hits: [String.Index] = []
        for token in sinkTokens {
            var cursor = source.startIndex
            while cursor < source.endIndex,
                  let call = source.range(of: token, range: cursor..<source.endIndex) {
                cursor = call.upperBound
                if call.lowerBound > source.startIndex {
                    let prev = source[source.index(before: call.lowerBound)]
                    if prev.isLetter || prev.isNumber || prev == "_" { continue }
                    if prev == ".", !isModuleQualified(source, call: call.lowerBound) { continue }
                }
                if comments.contains(where: { $0.contains(call.lowerBound) }) { continue }
                hits.append(call.lowerBound)
            }
        }
        hits.sort()
        var previousSink: String.Index?
        for hit in hits {
            defer { previousSink = hit }
            result.sinks += 1
            if gates.contains(where: { $0.contains(hit) }) {
                result.gated += 1
                continue
            }
            let line = source[..<hit].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            if let marker = source.range(of: decisionMarker, options: .backwards, range: source.startIndex..<hit),
               previousSink.map({ $0 < marker.lowerBound }) ?? true,
               source[marker.lowerBound..<hit].reduce(0, { $1 == "\n" ? $0 + 1 : $0 }) <= decisionWindowLines {
                result.decisions.append("\(file):\(line)")
                let lineEnd = source[hit...].firstIndex(of: "\n") ?? source.endIndex
                result.decisionCalls.append("\(file)|\(source[hit..<lineEnd])")
                continue
            }
            result.violations.append("\(file):\(line)")
        }
        return result
    }

    static func isModuleQualified(_ source: String, call: String.Index) -> Bool {
        let prefix = source[..<call]
        return moduleQualifiers.contains { qualifier in
            guard prefix.hasSuffix(qualifier) else { return false }
            let start = prefix.index(prefix.endIndex, offsetBy: -qualifier.count)
            guard start > prefix.startIndex else { return true }
            let before = prefix[prefix.index(before: start)]
            return !(before.isLetter || before.isNumber || before == "_" || before == ".")
        }
    }

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    struct SourceFile {
        let relativePath: String
        let source: String
    }

    static func appTargetSources() throws -> [SourceFile] {
        let root = repositoryRoot()
        let appRoot = root.appendingPathComponent("TabMail")
        guard let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            files.append(SourceFile(relativePath: relative, source: try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    struct TreeScan {
        var files = 0
        var total = ScanResult()
    }

    static func scanAppTarget() throws -> TreeScan {
        var tree = TreeScan()
        for file in try appTargetSources() {
            tree.files += 1
            if alwaysOnFacadeFiles.contains(file.relativePath) { continue }
            let result = scan(source: file.source, file: file.relativePath)
            tree.total.sinks += result.sinks
            tree.total.gated += result.gated
            tree.total.decisions += result.decisions
            tree.total.decisionCalls += result.decisionCalls
            tree.total.violations += result.violations
        }
        return tree
    }

    // MARK: - Property 2: no persisted debug line inside a database write context

    /// What counts as a database write context, in three shapes:
    /// - a trailing closure handed to a write callee, whatever it calls its parameter
    ///   (`conn`, `dbConn`, `$0`, `_`): GRDB's write entry points, plus every function
    ///   the target declares with a `(Database) … ->` parameter;
    /// - a closure whose parameter is `db` or typed `Database`, whatever it is handed to;
    /// - the body of a `func` or `init` with a `Database` parameter.
    /// A read's trailing closure is excluded. It is lexical, with two limits:
    /// - A closure passed inside parentheses has no callee here, so `write({ conn in … })`
    ///   is seen only through a `db` or `Database` parameter, and `read({ db in … })`
    ///   counts as a write context.
    /// - It does not follow calls: a helper with no `Database` parameter that calls
    ///   `logDebug` is not seen from the write that calls it.
    struct WriteContextPatterns {
        /// GRDB's entry points that run a closure with write access. Wrappers the
        /// target declares around them are derived by `writeCallees(in:patterns:)`.
        static let writeEntryPoints: Set<String> = [
            "write", "writeWithoutTransaction", "barrierWriteWithoutTransaction", "writeInTransaction",
            "asyncWrite", "asyncWriteWithoutTransaction", "asyncBarrierWriteWithoutTransaction",
            "unsafeReentrantWrite", "writePublisher", "inTransaction", "inSavepoint", "inDatabase",
            "registerMigration",
        ]
        /// A word before a callee that makes its `{` a body, not a trailing closure: a
        /// declaration (`func write(…) {`) or a statement condition (`if queue.enqueue(item) {`).
        static let nonCallWords: Set<String> = ["func", "if", "while", "guard", "switch", "where"]
        /// A closure that names its parameter `db` or types it `Database`, for a callee
        /// no rule names. Its return type may span lines.
        let closure: NSRegularExpression
        /// A read cannot roll a write back: `read`, `unsafeRead`, `asyncRead`,
        /// `ValueObservation.tracking`.
        let readCallee: NSRegularExpression
        let function: NSRegularExpression
        /// A parameter OF type `Database`. `(Database) throws -> T` does not match:
        /// that closure runs wherever it is called, not in this function's body.
        let databaseParameter: NSRegularExpression
        /// A body-less requirement is followed by the next declaration, not a `{`.
        let declarationKeyword: NSRegularExpression
        let persistedDebugSink: NSRegularExpression
        /// A `func` declaration, capturing its name.
        let wrapperDeclaration: NSRegularExpression
        /// A parameter whose closure type takes a `Database`: `(Database) throws -> T`.
        let databaseClosureParameter: NSRegularExpression

        init() throws {
            // Possessive quantifiers: blanked comments leave long whitespace runs after a
            // `{`, and a backtracking `\s*` across them is quadratic — seconds, not
            // milliseconds, over the target, for the same matches.
            closure = try NSRegularExpression(pattern:
                #"\{\s*+(?:\[[^\]\n]*+\]\s*+)?\(?\s*+(\w++)(?:\s*+:\s*+((?:GRDB\s*+\.\s*+)?\w++))?\s*+\)?\s*+(?:throws\s*+)?(?:->[^{}]*?)?\bin\b"#)
            readCallee = try NSRegularExpression(pattern: #"^read|Read|^tracking$"#)
            function = try NSRegularExpression(pattern: #"\b(?:func\s+\w+|init[?!]?)\s*(?:<[^>{}]*>)?\s*\("#)
            databaseParameter = try NSRegularExpression(pattern: #"\w+\s*:\s*(?:inout\s+)?(?:GRDB\s*\.\s*)?Database\b(?![\w.])"#)
            declarationKeyword = try NSRegularExpression(pattern:
                #"\b(?:func|var|let|init|subscript|case|struct|class|enum|protocol|extension|actor)\b"#)
            persistedDebugSink = try NSRegularExpression(pattern: #"\bBackgroundSyncLogger\s*\.\s*logDebug\s*\("#)
            wrapperDeclaration = try NSRegularExpression(pattern: #"\bfunc\s+(\w+)\s*(?:<[^>{}]*>)?\s*\("#)
            databaseClosureParameter = try NSRegularExpression(pattern:
                #"\(\s*(?:_\s+\w+\s*:\s*)?(?:inout\s+)?(?:GRDB\s*\.\s*)?Database\s*\)\s*(?:async\s+)?(?:(?:re)?throws\s+)?->"#)
        }
    }

    struct WriteContextScan {
        var contexts = 0
        var violations: [String] = []
    }

    static func scanWriteContexts(masked: String, file: String, patterns: WriteContextPatterns, writeCallees: Set<String>) -> WriteContextScan {
        let text = masked as NSString
        let units = Array(masked.utf16)
        let whole = NSRange(location: 0, length: text.length)
        var bodies: [Range<Int>] = []
        var calleeBodies = Set<Int>()

        // A trailing closure handed to a write callee, whatever it calls its parameter. A
        // declaration's body (`func write(…) {`) and a condition's body
        // (`if queue.enqueue(item) {`) are not calls.
        for (offset, unit) in units.enumerated() where unit == 0x7B {
            let callee = Self.callee(before: offset, in: units)
            guard writeCallees.contains(callee.name),
                  !WriteContextPatterns.nonCallWords.contains(callee.wordBefore) else { continue }
            calleeBodies.insert(offset)
            bodies.append(offset..<pastMatchingBrace(from: offset, in: units))
        }

        for match in patterns.closure.matches(in: masked, range: whole) where !calleeBodies.contains(match.range.location) {
            let name = text.substring(with: match.range(at: 1))
            let typeRange = match.range(at: 2)
            let type = typeRange.location == NSNotFound ? "" : text.substring(with: typeRange).filter { !$0.isWhitespace }
            guard name == "db" || type == "Database" || type == "GRDB.Database" else { continue }
            let calleeName = Self.callee(before: match.range.location, in: units).name
            if patterns.readCallee.firstMatch(in: calleeName, range: NSRange(location: 0, length: calleeName.utf16.count)) != nil {
                continue
            }
            bodies.append(match.range.location..<pastMatchingBrace(from: match.range.location, in: units))
        }

        for match in patterns.function.matches(in: masked, range: whole) {
            let open = NSMaxRange(match.range) - 1
            let close = matchingParen(from: open, in: units)
            let parameters = text.substring(with: NSRange(location: open, length: close - open))
            guard patterns.databaseParameter.firstMatch(in: parameters, range: NSRange(location: 0, length: parameters.utf16.count)) != nil,
                  let body = bodyBrace(after: close, in: units, text: text, patterns: patterns) else { continue }
            bodies.append(body..<pastMatchingBrace(from: body, in: units))
        }

        var result = WriteContextScan(contexts: bodies.count)
        for match in patterns.persistedDebugSink.matches(in: masked, range: whole)
        where bodies.contains(where: { $0.contains(match.range.location) }) {
            let line = units[..<match.range.location].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            result.violations.append("\(file):\(line)")
        }
        return result
    }

    /// GRDB's write entry points, plus every function the target declares with a
    /// parameter whose closure type takes a `Database` (`retryWrite`,
    /// `registerTimedMigration`, …), minus reads. Derived from the sources, so a new
    /// wrapper is a write callee without editing this suite.
    static func writeCallees(in maskedSources: [String], patterns: WriteContextPatterns) -> Set<String> {
        var callees = WriteContextPatterns.writeEntryPoints
        for masked in maskedSources {
            let text = masked as NSString
            let units = Array(masked.utf16)
            for match in patterns.wrapperDeclaration.matches(in: masked, range: NSRange(location: 0, length: text.length)) {
                let open = NSMaxRange(match.range) - 1
                let close = matchingParen(from: open, in: units)
                let parameters = text.substring(with: NSRange(location: open + 1, length: max(0, close - open - 1)))
                guard patterns.databaseClosureParameter.firstMatch(in: parameters, range: NSRange(location: 0, length: parameters.utf16.count)) != nil else { continue }
                callees.insert(text.substring(with: match.range(at: 1)))
            }
        }
        return callees.filter { patterns.readCallee.firstMatch(in: $0, range: NSRange(location: 0, length: $0.utf16.count)) == nil }
    }

    /// `source` with comment and string-literal content blanked to spaces. Newlines
    /// and the code inside `\(…)` interpolations stay, so offsets survive and braces
    /// balance.
    static func codeOnly(_ source: String) -> String {
        var masker = CodeMasker(Array(source.utf8))
        masker.code(from: 0, stopAtUnbalancedParen: false)
        return String(decoding: masker.out, as: UTF8.self)
    }

    struct CodeMasker {
        let src: [UInt8]
        var out: [UInt8]

        init(_ bytes: [UInt8]) {
            src = bytes
            out = bytes
        }

        mutating func blank(_ from: Int, _ to: Int) {
            var k = from
            while k < to {
                if out[k] != 0x0A { out[k] = 0x20 }
                k += 1
            }
        }

        /// Scans code from `start`. With `stopAtUnbalancedParen`, returns the index of
        /// the `)` that closes an interpolation; otherwise runs to the end.
        @discardableResult
        mutating func code(from start: Int, stopAtUnbalancedParen: Bool) -> Int {
            let n = src.count
            var i = start
            var depth = 0
            while i < n {
                let c = src[i]
                let next: UInt8 = i + 1 < n ? src[i + 1] : 0
                if c == 0x2F, next == 0x2F {                        // `//`
                    var j = i
                    while j < n, src[j] != 0x0A { j += 1 }
                    blank(i, j)
                    i = j
                    continue
                }
                if c == 0x2F, next == 0x2A {                        // `/*`, which nests
                    var j = i
                    var nesting = 0
                    while j < n {
                        if src[j] == 0x2F, j + 1 < n, src[j + 1] == 0x2A {
                            nesting += 1
                            j += 2
                            continue
                        }
                        if src[j] == 0x2A, j + 1 < n, src[j + 1] == 0x2F {
                            nesting -= 1
                            j += 2
                            if nesting == 0 { break }
                            continue
                        }
                        j += 1
                    }
                    blank(i, j)
                    i = j
                    continue
                }
                if c == 0x23 {                                      // `#"…"#`, or `#if` etc.
                    var j = i
                    while j < n, src[j] == 0x23 { j += 1 }
                    if j < n, src[j] == 0x22 {
                        i = string(at: j, hashes: j - i)
                    } else {
                        i = j
                    }
                    continue
                }
                if c == 0x22 {
                    i = string(at: i, hashes: 0)
                    continue
                }
                if c == 0x28 {
                    depth += 1
                } else if c == 0x29 {
                    if stopAtUnbalancedParen, depth == 0 { return i }
                    depth -= 1
                }
                i += 1
            }
            return i
        }

        /// Blanks the literal whose opening quote is at `quote`; returns the index past it.
        mutating func string(at quote: Int, hashes: Int) -> Int {
            let n = src.count
            let multiline = quote + 2 < n && src[quote + 1] == 0x22 && src[quote + 2] == 0x22
            let quotes = multiline ? 3 : 1
            var i = quote + quotes
            var start = i
            while i < n {
                if run(of: 0x22, count: quotes, at: i), run(of: 0x23, count: hashes, at: i + quotes) {
                    blank(start, i)
                    return i + quotes + hashes
                }
                if src[i] == 0x5C, run(of: 0x23, count: hashes, at: i + 1) {
                    let k = i + 1 + hashes
                    if k < n, src[k] == 0x28 {                      // interpolation: keep its code
                        blank(start, k)
                        i = code(from: k + 1, stopAtUnbalancedParen: true) + 1
                        start = i
                        continue
                    }
                    i = k + 1
                    continue
                }
                if !multiline, src[i] == 0x0A {
                    blank(start, i)
                    return i
                }
                i += 1
            }
            blank(start, n)
            return n
        }

        func run(of byte: UInt8, count: Int, at i: Int) -> Bool {
            guard i + count <= src.count else { return false }
            var k = 0
            while k < count {
                if src[i + k] != byte { return false }
                k += 1
            }
            return true
        }
    }

    /// The call a trailing closure at `brace` is passed to, and the word before the
    /// whole call expression, its receiver chain included: `("write", "try")` for
    /// `try pool.write(label: "x") { db in`, `("enqueue", "if")` for
    /// `if queue.enqueue(item) {`, and `("write", "func")` for a declaration's own
    /// body. The name is empty when there is none.
    static func callee(before brace: Int, in units: [UInt16]) -> (name: String, wordBefore: String) {
        func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x0A || u == 0x09 || u == 0x0D }
        func isIdentifier(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
        }
        var j = brace - 1
        while j >= 0, isSpace(units[j]) { j -= 1 }
        if j >= 0, units[j] == 0x29 {
            var depth = 0
            while j >= 0 {
                if units[j] == 0x29 {
                    depth += 1
                } else if units[j] == 0x28 {
                    depth -= 1
                    if depth == 0 { break }
                }
                j -= 1
            }
            j -= 1
            while j >= 0, isSpace(units[j]) { j -= 1 }
        }
        var k = j
        while k >= 0, isIdentifier(units[k]) { k -= 1 }
        guard k < j else { return ("", "") }
        // Step back over the receiver chain (`self.queue?.`, `pools[0].`, `make().`).
        var p = k
        while true {
            while p >= 0, isSpace(units[p]) { p -= 1 }
            guard p >= 0, units[p] == 0x2E else { break }
            p -= 1
            while p >= 0, units[p] == 0x3F || units[p] == 0x21 { p -= 1 }
            if p >= 0, units[p] == 0x29 || units[p] == 0x5D {
                let close = units[p]
                let open: UInt16 = close == 0x29 ? 0x28 : 0x5B
                var depth = 0
                while p >= 0 {
                    if units[p] == close {
                        depth += 1
                    } else if units[p] == open {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    p -= 1
                }
                p -= 1
            }
            while p >= 0, isIdentifier(units[p]) { p -= 1 }
        }
        var q = p
        while q >= 0, isIdentifier(units[q]) { q -= 1 }
        let wordBefore = q < p ? String(decoding: units[(q + 1)...p], as: UTF16.self) : ""
        return (String(decoding: units[(k + 1)...j], as: UTF16.self), wordBefore)
    }

    /// Index of the `)` matching the `(` at `open`, or the end of the source.
    static func matchingParen(from open: Int, in units: [UInt16]) -> Int {
        var depth = 0
        var i = open
        while i < units.count {
            if units[i] == 0x28 {
                depth += 1
            } else if units[i] == 0x29 {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return units.count
    }

    /// Index just past the `}` matching the `{` at `open`, or the end of the source.
    static func pastMatchingBrace(from open: Int, in units: [UInt16]) -> Int {
        var depth = 0
        var i = open
        while i < units.count {
            if units[i] == 0x7B {
                depth += 1
            } else if units[i] == 0x7D {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return units.count
    }

    /// The `{` opening the body of a declaration whose parameter list closes at
    /// `close`, or nil for a body-less requirement.
    static func bodyBrace(after close: Int, in units: [UInt16], text: NSString, patterns: WriteContextPatterns) -> Int? {
        var i = close + 1
        while i < units.count, units[i] != 0x7B, units[i] != 0x7D, units[i] != 0x3B { i += 1 }
        guard i < units.count, units[i] == 0x7B else { return nil }
        let gap = text.substring(with: NSRange(location: close + 1, length: i - close - 1))
        return patterns.declarationKeyword.firstMatch(in: gap, range: NSRange(location: 0, length: gap.utf16.count)) == nil ? i : nil
    }

    // MARK: - Tests

    @Test("Every console sink in the app target is gated or registered as ungated by decision")
    func everyAppTargetSinkIsGated() throws {
        let tree = try Self.scanAppTarget()
        #expect(tree.total.violations.isEmpty,
                """
                global CLAUDE.md rule 12: these console sinks are not debug-gated. Route them \
                through `BackgroundSyncLogger.logDebug`, or — inside a database write context — \
                gate the console print with `if DebugModeManager.isLoggingEnabled() {` on its own line:
                \(tree.total.violations.joined(separator: "\n"))
                """)
        // Exactly the registered production-observability sinks, each one by identity.
        #expect(tree.total.decisionCalls.count == Self.registeredDecisions.count,
                "expected the registered UNGATED BY DECISION sinks, saw: \(tree.total.decisions)")
        for decision in Self.registeredDecisions {
            #expect(tree.total.decisionCalls.filter { $0.hasPrefix("\(decision.file)|\(decision.call)") }.count == 1,
                    "no single UNGATED BY DECISION sink \(decision.call)… in \(decision.file); saw: \(tree.total.decisions)")
        }
        // Non-vacuity: the walk reached the target, and it saw gated sinks, so a
        // lexer that recognised nothing would fail here rather than pass above.
        #expect(tree.files >= 350, "the walk reached only \(tree.files) Swift files under TabMail/")
        #expect(tree.total.gated >= 100, "only \(tree.total.gated) gated sinks seen — is the lexer recognising gates?")
    }

    @Test("The sink scan distinguishes gated, decision-marked, commented, qualified and ungated sinks")
    func theScanDiscriminates() {
        let fixture = """
        func a() {
            print("[A] ungated")
        }
        func b() {
            if DebugModeManager.isLoggingEnabled() {
                print("[B] gated")
            }
        }
        func c() {
            // 🚨 UNGATED BY DECISION (fixture).
            print("[C] registered")
            print("[C2] a second sink the marker does not license")
        }
        func d() {
            // print("[D] prose, not a call")
            NSLog("[D] ungated")
            Swift.print("[D2] module-qualified, still a sink")
            formatter.print("[D3] a method, not a sink")
        }
        """
        let result = Self.scan(source: fixture, file: "fixture")
        #expect(result.sinks == 6)
        #expect(result.gated == 1)
        #expect(result.decisions == ["fixture:11"])
        #expect(result.decisionCalls == [#"fixture|print("[C] registered")"#])
        #expect(result.violations == ["fixture:2", "fixture:12", "fixture:16", "fixture:17"])
    }

    @Test("No logDebug call sits inside a database write context")
    func noDebugLogLineInsideADatabaseWriteContext() throws {
        let patterns = try WriteContextPatterns()
        let sources = try Self.appTargetSources().map { (path: $0.relativePath, masked: Self.codeOnly($0.source)) }
        let writeCallees = Self.writeCallees(in: sources.map { $0.masked }, patterns: patterns)
        var contexts = 0
        var violations: [String] = []
        for file in sources {
            let result = Self.scanWriteContexts(masked: file.masked, file: file.path, patterns: patterns, writeCallees: writeCallees)
            contexts += result.contexts
            violations += result.violations
        }
        #expect(violations.isEmpty,
                """
                root rule 12, 2026-09-05 addendum: `logDebug` persists to `tabmail.log`, and no ROLLBACK \
                retracts a line. Inside a database write, keep a console print under \
                `if DebugModeManager.isLoggingEnabled() {` on its own line, or log after the write returns:
                \(violations.joined(separator: "\n"))
                """)
        // Non-vacuity: the target holds hundreds of write closures and functions
        // handed a `Database`, so a scan that recognised none fails here. It also
        // declares wrappers around GRDB's writes, so a wrapper scan that derived none
        // fails here too.
        #expect(contexts >= 300, "only \(contexts) database write contexts seen — is the scan recognising them?")
        #expect(writeCallees.isStrictSuperset(of: WriteContextPatterns.writeEntryPoints),
                "no write wrapper derived from the target — is the `(Database) … ->` parameter scan matching?")
    }

    @Test("The write-context scan finds a write by its callee or its db parameter, and not a read, another closure or quoted text")
    func theWriteContextScanDiscriminates() throws {
        let fixture = #"""
        func a(pool: DatabasePool) throws {
            try pool.write { db in
                let brace = "}"
                BackgroundSyncLogger.logDebug("[A] inside a write \(brace)")
            }
            BackgroundSyncLogger.logDebug("[A2] after the write returns")
        }
        func b(_ header: Header, db: GRDB.Database) throws {
            BackgroundSyncLogger.logDebug("[B] inside a func handed a Database")
        }
        func c(operation: @escaping (Database) throws -> Void) {
            BackgroundSyncLogger.logDebug("[C] a wrapper's own body is not a write")
        }
        func d(pool: DatabasePool) throws {
            try pool.read { db in
                BackgroundSyncLogger.logDebug("[D] a read cannot roll a write back")
            }
            migrator.registerMigration("v1") { (db: Database) in
                // BackgroundSyncLogger.logDebug("[D2] commented out")
                if DebugModeManager.isLoggingEnabled() {
                    print("{ db in BackgroundSyncLogger.logDebug(\"[D3] quoted\")")
                }
                BackgroundSyncLogger.logDebug("[D4] inside a migration")
            }
        }
        func enqueueWrite(_ work: @escaping () async -> Void) {}
        func readSnapshot<T>(_ body: (Database) throws -> T) rethrows -> T { try body(database) }
        func e(pool: DatabasePool, manager: Manager, store: Store) throws {
            try pool.write { conn in
                BackgroundSyncLogger.logDebug("[E] a write whose parameter is not db")
            }
            try pool.write {
                try save($0)
                BackgroundSyncLogger.logDebug("[E2] a write through $0")
            }
            let pair = try store.perform { db -> (
                ids: [String], count: Int
            ) in
                BackgroundSyncLogger.logDebug("[E3] a db closure whose return type spans lines")
                return ([], 0)
            }
            c { conn in
                BackgroundSyncLogger.logDebug("[E4] handed to a wrapper that takes a Database closure")
            }
            manager.enqueueWrite { [manager] in
                BackgroundSyncLogger.logDebug("[E5] an intention-queue closure receives no Database")
            }
            try readSnapshot { conn in
                BackgroundSyncLogger.logDebug("[E6] handed to a read wrapper")
            }
            view.transaction { $0.disablesAnimations = true; BackgroundSyncLogger.logDebug("[E7] SwiftUI") }
        }
        func admit(_ write: @escaping (Database) throws -> Void) -> Bool { true }
        func f(queue: Queue) {
            if queue.admit(save) {
                BackgroundSyncLogger.logDebug("[F] an if body is not a closure handed to admit")
            }
        }
        """#
        let patterns = try WriteContextPatterns()
        let masked = Self.codeOnly(fixture)
        let writeCallees = Self.writeCallees(in: [masked], patterns: patterns)
        #expect(writeCallees.isSuperset(of: ["c", "admit"]), "a function with a `(Database) throws -> Void` parameter is a write wrapper")
        #expect(!writeCallees.contains("enqueueWrite"), "a `() async -> Void` closure receives no Database")
        #expect(!writeCallees.contains("readSnapshot"), "a read wrapper cannot roll a write back")
        let result = Self.scanWriteContexts(masked: masked, file: "fixture", patterns: patterns, writeCallees: writeCallees)
        #expect(result.violations == ["fixture:4", "fixture:9", "fixture:23", "fixture:30", "fixture:34", "fixture:39", "fixture:43"])
    }
}
