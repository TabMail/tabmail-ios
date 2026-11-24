import Foundation

/// Static census of every database query site in the production sources (`TabMail`,
/// `TabMailNotificationService`, `Shared`), the input of the query-plan fence
/// (`QueryRegistryFenceTests`). Pure Foundation, so the same file also runs on the
/// host (`swiftc` with a small driver) to regenerate the registry skeleton.
///
/// Two kinds of site:
/// - `sql`: a string literal whose text reads as SQL (the statement keywords below).
///   Interpolations are kept as `\(…)`, whitespace runs collapse to one space.
/// - `call`: a Swift statement that runs a query: one of its lines names a GRDB API
///   (`fetchAll`, `execute`, …), calls a database handle (`db.x(…)`), or passes a
///   handle as an argument (`record.insert(db)`, `helper(db: db)`). Handles are the
///   names a file binds to a `Database` (a `: Database` parameter, or the parameter of
///   a closure passed to `read`/`write`/…, `$0` included). The statement runs from the
///   first line of its expression (a query-interface chain `Type\n.filter(…)\n.fetchAll(db)`
///   is one statement) to its last argument line; the text is its code with comments
///   removed, string literals blanked to `""` and multi-line closure bodies shown as `…`
///   (each statement inside a closure body is a site of its own).
///
/// A site is identified by file, enclosing declaration (`Type.function`), kind, text
/// and an ordinal among identical sites in the same declaration, never by line, so
/// unrelated edits above it do not move it. `line` (the first line) is for messages.
enum QueryCensusScanner {

    struct Site: Hashable, Sendable {
        let file: String
        let context: String
        let kind: String
        let text: String
        let ordinal: Int
        let line: Int
        let lastLine: Int
        /// For a `sql` site, the statement as SQLite receives it: the literal with the
        /// escapes of a non-raw string resolved, whitespace collapsed. Empty for `call`.
        let sql: String

        /// Identity without the lines.
        var key: String { [file, context, kind, String(ordinal), text].joined(separator: "\t") }

        static func == (a: Site, b: Site) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    static let sourceDirectories = ["TabMail", "TabMailNotificationService", "Shared"]

    /// Every site of every production Swift file under `root`, in file then line order.
    static func scan(root: URL) throws -> [Site] {
        var files: [String] = []
        for dir in sourceDirectories {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        files.sort()
        var sites: [Site] = []
        let patterns = Patterns()
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            sites.append(contentsOf: scan(file: file, source: text, patterns: patterns))
        }
        return sites
    }

    /// The sites of one file.
    static func scan(file: String, source: String) -> [Site] {
        scan(file: file, source: source, patterns: Patterns())
    }

    // MARK: - Patterns

    struct Patterns {
        let sql: NSRegularExpression
        let api: NSRegularExpression
        let declaration: NSRegularExpression
        let typedHandle: NSRegularExpression
        let closureHandle: NSRegularExpression
        let shorthandHandle: NSRegularExpression

        init() {
            // Same statement keywords as the census that produced the registry.
            sql = Self.regex(#"(?is)\b(select\b.+\bfrom|update\s+\w+\s+set|delete\s+from|insert\s+(or\s+\w+\s+)?into|replace\s+into|create\s+(unique\s+)?index|drop\s+(index|table)|create\s+(virtual\s+)?table|alter\s+table|with\s+\w+\s+as|analyze|pragma\s+\w+|vacuum|\bmatch\b)"#)
            api = Self.regex(#"\.(fetchAll|fetchOne|fetchCount|fetchCursor|fetchSet|fetchSingle|deleteAll|deleteOne|updateAll|updateChanges|execute|makeStatement|cachedStatement|insertAndFetch|upsertAndFetch|isEmpty|exists)\s*\("#)
            // `class func` / `class var` are members, not a type named `func`.
            declaration = Self.regex(#"\b(?:(struct|class|enum|actor|extension|protocol)\s+(?!(?:func|var|let|subscript|init)\b)([A-Za-z_][\w.]*)|func\s+([^\s(<]+)|(init)[?!]?\s*[(<]|(deinit)\b|(subscript)\s*[(<])"#)
            typedHandle = Self.regex(#"\b([A-Za-z_]\w*)\s*:\s*(?:GRDB\.)?Database\b(?!\w|\.)"#)
            closureHandle = Self.regex(#"\.(?:"# + Self.handleMethods + #")\b[^{\n]*\{\s*(?:\[[^\]]*\]\s*)?\(?\s*([A-Za-z_]\w*)\s*(?::\s*[\w.]+)?\s*\)?\s*(?:throws\s*)?(?:->\s*[^{}\n]*?)?\s+in\b"#)
            shorthandHandle = Self.regex(#"\.(?:"# + Self.handleMethods + #")\b[^{\n]*\{(?![^\n]*\bin\b)"#)
        }

        /// The database-access methods whose closure receives a `Database`.
        static let handleMethods = "read|write|inDatabase|writeWithoutTransaction|barrierWriteWithoutTransaction|unsafeRead|unsafeReentrantRead|unsafeReentrantWrite|asyncRead|asyncWrite|asyncWriteWithoutTransaction|asyncUnsafeRead|asyncBarrierWriteWithoutTransaction|tracking|trackingConstantRegion|inTransaction|inSavepoint|writeInBackground|readInBackground|uncheckedWrite|spawnConcurrentRead|asyncConcurrentRead"

        static func regex(_ pattern: String) -> NSRegularExpression {
            // The patterns are literals of this file; a bad one is a programming error.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern)
        }

        func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        }

        func first(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    // MARK: - Lexing

    /// One string literal: its first line, its text (interpolations as `\(…)`), the same
    /// text with the escapes of a non-raw literal resolved (what SQLite receives), and the
    /// declaration it sits in.
    private struct Literal {
        let line: Int
        let text: String
        let resolved: String
        let context: String
    }

    /// An open bracket: the character and the 0-based line it opened on.
    private struct Open {
        let char: Character
        let line: Int
    }

    private struct Lexed {
        /// Code per line (index 0 = line 1), comments removed, literals blanked.
        var code: [String] = [""]
        /// The declaration context in force at the start of each line's first code.
        var lineContext: [String] = [""]
        /// The brackets open at the start of each line, outermost first.
        var startStack: [[Open]] = [[]]
        var literals: [Literal] = []
    }

    private final class Lexer {
        let s: [Character]
        var i = 0
        var line = 1
        var out = Lexed()
        var depth = 0
        var stack: [(name: String, depth: Int)] = []
        var brackets: [Open] = []
        var pending = ""
        let patterns: Patterns

        init(_ source: String, patterns: Patterns) {
            s = Array(source)
            self.patterns = patterns
        }

        var context: String { stack.map(\.name).joined(separator: ".") }

        func peek(_ k: Int = 0) -> Character? { i + k < s.count ? s[i + k] : nil }

        func emitCode(_ c: Character) {
            if c == "\n" {
                line += 1
                out.code.append("")
                out.lineContext.append(context)
                out.startStack.append(brackets)
                return
            }
            if out.code[line - 1].isEmpty { out.lineContext[line - 1] = context }
            out.code[line - 1].append(c)
            switch c {
            case "(", "[":
                brackets.append(Open(char: c, line: line - 1))
                pending.append(c)
            case ")", "]":
                if !brackets.isEmpty { brackets.removeLast() }
                pending.append(c)
            case "{":
                brackets.append(Open(char: c, line: line - 1))
                depth += 1
                if let name = declarationName(pending) { stack.append((name, depth)) }
                pending = ""
            case "}":
                if !brackets.isEmpty { brackets.removeLast() }
                while let top = stack.last, top.depth >= depth { stack.removeLast() }
                depth -= 1
                pending = ""
            case ";":
                pending = ""
            default:
                pending.append(c)
            }
        }

        /// The name a `{` opens, from the code since the previous brace: the last
        /// declaration keyword in it.
        func declarationName(_ text: String) -> String? {
            guard let m = patterns.matches(patterns.declaration, text).last else { return nil }
            for group in 2...6 {
                let r = m.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: text) {
                    return String(text[range])
                }
            }
            return nil
        }

        func run() -> Lexed {
            while let c = peek() {
                if c == "/" && peek(1) == "/" {
                    while let d = peek(), d != "\n" { i += 1 }
                } else if c == "/" && peek(1) == "*" {
                    skipBlockComment()
                } else if c == "#" || c == "\"" {
                    if !lexString() { emitCode(c); i += 1 }
                } else {
                    emitCode(c)
                    i += 1
                }
            }
            return out
        }

        func skipBlockComment() {
            var level = 0
            while let c = peek() {
                if c == "/" && peek(1) == "*" { level += 1; i += 2; continue }
                if c == "*" && peek(1) == "/" { level -= 1; i += 2; if level == 0 { return }; continue }
                if c == "\n" { emitCode("\n") }
                i += 1
            }
        }

        /// Lexes a string literal starting at `i` (optionally raw: `#…"`), records it,
        /// and emits `""` into the code. Returns false when `i` is not a literal start.
        func lexString() -> Bool {
            var hashes = 0
            while peek(hashes) == "#" { hashes += 1 }
            guard peek(hashes) == "\"" else { return false }
            let startLine = line
            let startContext = context
            let multiline = peek(hashes + 1) == "\"" && peek(hashes + 2) == "\""
            i += hashes + (multiline ? 3 : 1)
            var text = ""
            var resolved = ""
            var newlines = 0
            loop: while let c = peek() {
                if c == "\\" && matchesHashes(at: i + 1, hashes) {
                    let after = i + 1 + hashes
                    if after < s.count, s[after] == "(" {
                        i = after + 1
                        newlines += skipInterpolation()
                        text += "\\(…)"
                        resolved += "\\(…)"
                        continue
                    }
                    if hashes == 0 {
                        if let n = peek(1) {
                            text.append(c)
                            text.append(n)
                            if n == "\n" { newlines += 1 }
                            resolved.append(Self.escaped(n))
                        }
                        i += 2
                        continue
                    }
                }
                if c == "\"" {
                    if multiline {
                        if peek(1) == "\"" && peek(2) == "\"" && matchesHashes(at: i + 3, hashes) {
                            i += 3 + hashes
                            break loop
                        }
                    } else if matchesHashes(at: i + 1, hashes) {
                        i += 1 + hashes
                        break loop
                    }
                }
                if c == "\n" {
                    newlines += 1
                    if !multiline { i += 1; break loop }
                }
                text.append(c)
                resolved.append(c)
                i += 1
            }
            out.literals.append(Literal(line: startLine, text: text, resolved: resolved, context: startContext))
            emitCode("\"")
            emitCode("\"")
            for _ in 0..<newlines { emitCode("\n") }
            return true
        }

        /// The character a Swift escape `\<n>` stands for. A line-continuation
        /// backslash (`\` before a newline) and the whitespace escapes become a space;
        /// `\u{…}` and `\0` keep their letter, which no SQL statement of ours uses.
        static func escaped(_ n: Character) -> Character {
            switch n {
            case "n", "t", "r", "\n": return " "
            default: return n
            }
        }

        func matchesHashes(at index: Int, _ hashes: Int) -> Bool {
            guard hashes > 0 else { return true }
            for k in 0..<hashes where index + k >= s.count || s[index + k] != "#" { return false }
            return true
        }

        /// Skips an interpolation's code up to its closing parenthesis; nested string
        /// literals are skipped whole. Returns the newlines passed.
        func skipInterpolation() -> Int {
            var level = 1
            var newlines = 0
            while let c = peek() {
                if c == "\"" || c == "#", let passed = skipNestedString() {
                    newlines += passed
                    continue
                }
                if c == "(" { level += 1 }
                if c == ")" { level -= 1; if level == 0 { i += 1; return newlines } }
                if c == "\n" { newlines += 1 }
                i += 1
            }
            return newlines
        }

        /// A string literal nested in an interpolation: skipped, not recorded. Returns the
        /// newlines passed, or nil when `i` is not a literal start.
        func skipNestedString() -> Int? {
            var hashes = 0
            while peek(hashes) == "#" { hashes += 1 }
            guard peek(hashes) == "\"" else { return nil }
            let multiline = peek(hashes + 1) == "\"" && peek(hashes + 2) == "\""
            i += hashes + (multiline ? 3 : 1)
            var newlines = 0
            while let c = peek() {
                if c == "\\" && matchesHashes(at: i + 1, hashes) {
                    let after = i + 1 + hashes
                    if after < s.count, s[after] == "(" { i = after + 1; newlines += skipInterpolation(); continue }
                    if hashes == 0 { if peek(1) == "\n" { newlines += 1 }; i += 2; continue }
                }
                if c == "\"" {
                    if multiline {
                        if peek(1) == "\"" && peek(2) == "\"" && matchesHashes(at: i + 3, hashes) { i += 3 + hashes; return newlines }
                    } else if matchesHashes(at: i + 1, hashes) { i += 1 + hashes; return newlines }
                }
                if c == "\n" {
                    newlines += 1
                    if !multiline { i += 1; return newlines }
                }
                i += 1
            }
            return newlines
        }
    }

    // MARK: - Sites

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    private static func scan(file: String, source: String, patterns: Patterns) -> [Site] {
        let lexed = Lexer(source, patterns: patterns).run()
        var raw: [(line: Int, lastLine: Int, context: String, kind: String, text: String, sql: String)] = []

        for literal in lexed.literals where patterns.first(patterns.sql, literal.text) {
            raw.append((literal.line, literal.line, literal.context, "sql", normalize(literal.text), normalize(literal.resolved)))
        }

        let allCode = lexed.code.joined(separator: "\n")
        var handles = Set<String>()
        for m in patterns.matches(patterns.typedHandle, allCode) + patterns.matches(patterns.closureHandle, allCode) {
            if let r = Range(m.range(at: 1), in: allCode) {
                let name = String(allCode[r])
                if name != "_" && name != "self" { handles.insert(name) }
            }
        }
        let handleUse: NSRegularExpression? = handles.isEmpty ? nil : Self.useRegex(
            handles.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"))
        // `$0` is a handle only inside a shorthand closure of a database-access method.
        let dollarUse = Self.useRegex(#"\$0"#)
        let hasShorthand = patterns.first(patterns.shorthandHandle, allCode)

        var starts = Set<Int>()
        for (index, code) in lexed.code.enumerated() {
            var isCall = patterns.first(patterns.api, code) || (handleUse.map { patterns.first($0, code) } ?? false)
            if !isCall, hasShorthand, patterns.first(dollarUse, code) {
                let closureLine = lexed.startStack[index].last(where: { $0.char == "{" })?.line
                isCall = patterns.first(patterns.shorthandHandle, code)
                    || closureLine.map { patterns.first(patterns.shorthandHandle, lexed.code[$0]) } == true
            }
            guard isCall else { continue }
            let span = statementSpan(containing: index, lexed)
            guard starts.insert(span.lowerBound).inserted else { continue }
            raw.append((span.lowerBound + 1, span.upperBound + 1, lexed.lineContext[span.lowerBound], "call", render(span, lexed), ""))
        }

        raw.sort { ($0.line, $0.kind) < ($1.line, $1.kind) }
        var seen: [String: Int] = [:]
        return raw.map { r in
            let identity = [r.context, r.kind, r.text].joined(separator: "\t")
            let ordinal = seen[identity, default: 0]
            seen[identity] = ordinal + 1
            return Site(file: file, context: r.context, kind: r.kind, text: r.text, ordinal: ordinal,
                        line: r.line, lastLine: r.lastLine, sql: r.sql)
        }
    }

    /// A use of one of `names` (an alternation) on a code line: the base of a call that is
    /// not a database-access scope (`db.execute(`; not `db.write {`, not `ctx.db.read(`),
    /// or a whole argument (`fetchAll(db)`, `helper(x, db: db)`, and an argument alone on
    /// its line of a multi-line call).
    private static func useRegex(_ names: String) -> NSRegularExpression {
        Patterns.regex(
            #"(?:(?<![.\w$])(?:"# + names + #")\s*\.\s*(?!(?:"# + Patterns.handleMethods + #")\b)\w+\s*[({]"#
                + #"|(?:^|[(,])\s*(?:\w+\s*:\s*)?(?:"# + names + #")\s*(?:[),]|$))"#)
    }

    // MARK: - Statements

    /// Line starts that continue the statement above: a chained member, an infix operator.
    private static let continuingStarts = [".", "?.", "&&", "||", "??", "?", ":", "+", "==", "!=", "..."]
    /// Line ends that leave the statement open: an infix operator, an assignment, a list comma.
    private static let continuingEnds = ["=", "&&", "||", "??", "+", ",", "."]

    private static func trimmed(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces)
    }

    private static func previousCodeLine(before line: Int, _ lexed: Lexed) -> Int? {
        var k = line - 1
        while k >= 0 {
            if !trimmed(lexed.code[k]).isEmpty { return k }
            k -= 1
        }
        return nil
    }

    private static func nextCodeLine(after line: Int, _ lexed: Lexed) -> Int? {
        var k = line + 1
        while k < lexed.code.count {
            if !trimmed(lexed.code[k]).isEmpty { return k }
            k += 1
        }
        return nil
    }

    private static func startsContinuing(_ line: Int, _ lexed: Lexed) -> Bool {
        let t = trimmed(lexed.code[line])
        return continuingStarts.contains { t.hasPrefix($0) }
    }

    private static func endsContinuing(_ line: Int, _ lexed: Lexed) -> Bool {
        let t = trimmed(lexed.code[line])
        return continuingEnds.contains { t.hasSuffix($0) } && !t.hasSuffix("...")
    }

    /// The 0-based first and last line of the statement that `line` belongs to. Inside an
    /// open `(` or `[` the statement is the one that opened it; a line inside a closure body
    /// (`{` innermost) starts a statement of its own.
    private static func statementSpan(containing line: Int, _ lexed: Lexed) -> ClosedRange<Int> {
        var start = line
        while true {
            let stack = lexed.startStack[start]
            if let top = stack.last, top.char != "{" {
                start = top.line
                continue
            }
            guard let prev = previousCodeLine(before: start, lexed),
                  startsContinuing(start, lexed) || endsContinuing(prev, lexed) else { break }
            let prevStack = lexed.startStack[prev]
            // The line above sits inside a bracket opened after this statement's level
            // (`})` closing an argument closure): continue from where that bracket opened.
            start = prevStack.count > stack.count ? prevStack[stack.count].line : prev
        }
        let base = lexed.startStack[start].count
        var end = start
        while let next = nextCodeLine(after: end, lexed),
              lexed.startStack[next].count > base || startsContinuing(next, lexed) || endsContinuing(end, lexed) {
            end = next
        }
        return start...max(end, line)
    }

    /// The statement's code on one line; lines inside a closure body it opens are `…`.
    private static func render(_ span: ClosedRange<Int>, _ lexed: Lexed) -> String {
        let base = lexed.startStack[span.lowerBound].count
        var parts: [String] = []
        var skipping = false
        for k in span {
            if lexed.startStack[k].dropFirst(base).contains(where: { $0.char == "{" }) {
                if !skipping { parts.append("…"); skipping = true }
                continue
            }
            skipping = false
            parts.append(lexed.code[k])
        }
        return normalize(parts.joined(separator: " "))
    }
}
