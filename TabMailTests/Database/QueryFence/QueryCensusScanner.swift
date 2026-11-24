import Foundation

/// Static census of every database query site in the production sources (`TabMail`,
/// `TabMailNotificationService`, `Shared`), the input of the query-plan fence
/// (`DatabaseIndexTests`, files in `QueryFence/`). Pure Foundation.
///
/// Three kinds of site:
/// - `sql`: a string literal whose text reads as SQL (the statement keywords below). Its
///   text keeps each interpolation with its source (`\(folderId)`), whitespace runs
///   collapsed to one space. `sql` is the statement as SQLite receives it: the escapes of
///   the literal resolved, nothing else changed, interpolations as `\(…)`.
/// - `call`: one call expression that runs a query: a GRDB API (`fetchAll(`, `execute(`,
///   …) with its receiver chain, a member call on a database handle (`db.x(…)`), or a
///   call that passes a handle as an argument (`record.insert(db)`, `helper(db: held.db)`).
///   Handles are the names a file binds to a database: a parameter, property or tuple
///   element typed `Database`, `DatabaseQueue`, `DatabasePool`, `DatabaseReader`,
///   `DatabaseWriter` or `PrioritizedDatabase`; a `let`/`var` set to a new queue or pool;
///   and the parameter of a closure passed to `read`/`write`/… (`$0` included). Every
///   call is a site of its own, two calls on one line included. Its text runs from the
///   start of its receiver chain to its closing bracket: comments removed, string
///   literals with their contents, a closure body that spans lines shown as `{ … }` (each
///   call inside it is a site of its own). A call that reads a local binding, as its
///   receiver (`request.fetchAll(db)`) or as the leading name of an argument
///   (`helper(db, inbox)`, `fetchAll(db, inScope.limit(9))`), also carries the binding's
///   initializer and each plain reassignment of it before the call (` ⟨request = …⟩`), and
///   so on for the bindings those read (`inScope` = `inbox.filter(…)` brings `inbox`). A
///   binding is the last of its name before the use, in the use's declaration or one
///   enclosing it.
/// - `request`: a function or computed property that returns a `QueryInterfaceRequest`,
///   `SQLRequest` or `SQLExpression`, keyed by its whole text from `func`/`var` to its
///   closing brace, so an edit of the request it builds changes the key; its context is
///   its own name.
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
        /// For a `sql` site, the statement as SQLite receives it. Empty for `call`.
        let sql: String

        /// Identity without the lines.
        var key: String { [file, context, kind, String(ordinal), text].joined(separator: "\t") }

        static func == (a: Site, b: Site) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    enum ScanError: Error, CustomStringConvertible {
        case missingDirectory(String)
        case unreadable(String)
        case walk([String])

        var description: String {
            switch self {
            case .missingDirectory(let path): "source directory missing: \(path)"
            case .unreadable(let path): "source directory cannot be listed: \(path)"
            case .walk(let errors): "source walk failed:\n\(errors.joined(separator: "\n"))"
            }
        }
    }

    static let sourceDirectories = ["TabMail", "TabMailNotificationService", "Shared"]

    /// The errors a directory walk reports, collected from the enumerator's handler.
    private final class WalkErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Every site of every production Swift file under `root`, in file then line order.
    /// A missing source directory, or a file the walk cannot read, fails the scan.
    static func scan(root: URL) throws -> [Site] {
        var files: [String] = []
        let rootPath = root.standardizedFileURL.path
        for dir in sourceDirectories {
            let base = root.appendingPathComponent(dir)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ScanError.missingDirectory(base.path)
            }
            let errors = WalkErrors()
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil, options: [],
                errorHandler: { url, error in errors.add("\(url.path): \(error)"); return true }
            ) else { throw ScanError.unreadable(base.path) }
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1)))
            }
            if !errors.all.isEmpty { throw ScanError.walk(errors.all) }
        }
        files.sort()
        let sources = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        let patterns = Patterns()
        let builds = requestBuilders(sources, patterns)
        var sites: [Site] = []
        for (file, text) in zip(files, sources) {
            sites.append(contentsOf: scan(file: file, source: text, patterns: patterns, builds: builds))
        }
        return sites
    }

    /// The sites of one file, alone (its request helpers are the only ones it knows).
    static func scan(file: String, source: String) -> [Site] {
        let patterns = Patterns()
        return scan(file: file, source: source, patterns: patterns, builds: requestBuilders([source], patterns))
    }

    static let requestFunctionName = Patterns.regex(#"\bfunc\s+([A-Za-z_]\w*)(?:(?!\bfunc\b)[^{};])*?->\s*(?:some\s+|any\s+)?(?:GRDB\.)?(?:QueryInterfaceRequest|SQLRequest|SQLExpression)\b"#)
    static let requestPropertyName = Patterns.regex(#"\bvar\s+([A-Za-z_]\w*)\s*:\s*(?:some\s+|any\s+)?(?:GRDB\.)?(?:QueryInterfaceRequest|SQLRequest|SQLExpression)\b"#)

    /// `requestTokens`, plus a use of any request helper the sources declare.
    private static func requestBuilders(_ sources: [String], _ patterns: Patterns) -> NSRegularExpression {
        var names = Set<String>()
        for source in sources {
            for regex in [requestFunctionName, requestPropertyName] {
                for m in patterns.matches(regex, source) { names.insert((source as NSString).substring(with: m.range(at: 1))) }
            }
        }
        let uses = names.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return Patterns.regex(requestTokens + (uses.isEmpty ? "" : #"|\b(?:"# + uses + #")\b"#))
    }

    // MARK: - Patterns

    struct Patterns {
        let sql: NSRegularExpression
        let api: NSRegularExpression
        let declaration: NSRegularExpression
        let typedHandle: NSRegularExpression
        let newHandle: NSRegularExpression
        let closureHandle: NSRegularExpression
        let shorthandHandle: NSRegularExpression

        init() {
            // Same statement keywords as the census that produced the registry.
            sql = Self.regex(#"(?is)\b(select\b.+\bfrom|update\s+\w+\s+set|delete\s+from|insert\s+(or\s+\w+\s+)?into|replace\s+into|create\s+(unique\s+)?index|drop\s+(index|table)|create\s+(virtual\s+)?table|alter\s+table|with\s+\w+\s+as|analyze|pragma\s+\w+|vacuum|\bmatch\b)"#)
            api = Self.regex(#"\.(fetchAll|fetchOne|fetchCount|fetchCursor|fetchSet|fetchSingle|deleteAll|deleteOne|updateAll|updateChanges|execute|makeStatement|cachedStatement|insertAndFetch|upsertAndFetch|isEmpty|exists)\s*\("#)
            // `class func` / `class var` are members, not a type named `func`; `.init(` is a call.
            declaration = Self.regex(#"\b(?:(struct|class|enum|actor|extension|protocol)\s+(?!(?:func|var|let|subscript|init)\b)([A-Za-z_][\w.]*)|func\s+([^\s(<]+)|(?<![.\w])(init)[?!]?\s*[(<]|(deinit)\b|(subscript)\s*[(<])"#)
            typedHandle = Self.regex(#"\b([A-Za-z_]\w*)\s*:\s*(?:any\s+|some\s+)?(?:GRDB\.)?(?:Database|DatabaseQueue|DatabasePool|DatabaseReader|DatabaseWriter|PrioritizedDatabase)\b(?![\w.])"#)
            newHandle = Self.regex(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=\s*(?:try[?!]?\s+)?(?:GRDB\.)?(?:DatabaseQueue|DatabasePool)\s*\("#)
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
            regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }

        func first(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    // MARK: - Lexing

    /// One string literal: its first line, its key text (interpolations with their
    /// source), the text SQL detection reads (as written, interpolations `\(…)`, so an
    /// interpolated expression's names never make a literal look like SQL), and the
    /// statement SQLite receives (escapes resolved, interpolations `\(…)`).
    private struct Literal {
        let line: Int
        let text: String
        let detect: String
        let resolved: String
        let context: String
    }

    private struct Lexed {
        /// Code per line (index 0 = line 1), comments removed, each literal a `""` placeholder.
        var code: [String] = [""]
        var literals: [Literal] = []
        /// UTF-16 offset in the joined code of each placeholder's first quote -> literal index.
        var placeholders: [Int: Int] = [:]
        /// (UTF-16 offset, declaration context in force from there on), in offset order.
        var contexts: [(offset: Int, context: String)] = [(0, "")]
    }

    private final class Lexer {
        let s: [Character]
        var i = 0
        var line = 1
        var offset = 0
        var out = Lexed()
        var depth = 0
        var stack: [(name: String, depth: Int)] = []
        /// The pending code before each open brace that sits inside a parenthesis, with its depth.
        var held: [(pending: String, depth: Int)] = []
        var pending = ""
        let patterns: Patterns

        init(_ source: String, patterns: Patterns) {
            s = Array(source)
            self.patterns = patterns
        }

        var context: String { stack.map(\.name).joined(separator: ".") }

        func peek(_ k: Int = 0) -> Character? { i + k < s.count ? s[i + k] : nil }

        func emitCode(_ c: Character) {
            offset += c.utf16.count
            if c == "\n" {
                line += 1
                out.code.append("")
                // A line break separates words: `import GRDB` then `struct X {` must not
                // read as `GRDBstruct X`, nor a property line then `init(` as `Intinit(`.
                pending.append(" ")
                return
            }
            out.code[line - 1].append(c)
            switch c {
            case "{":
                depth += 1
                // A brace inside an open parenthesis is a closure argument, or a parameter's
                // default value (`after: () -> Void = { … }`): it opens no declaration, and
                // the code before it stays pending, so the `{` after the parameter list still
                // names its function.
                if pending.filter({ $0 == "(" }).count > pending.filter({ $0 == ")" }).count {
                    held.append((pending, depth))
                    pending = ""
                    return
                }
                if let name = declarationName(pending) {
                    stack.append((name, depth))
                    out.contexts.append((offset, context))
                }
                pending = ""
            case "}":
                let before = stack.count
                while let top = stack.last, top.depth >= depth { stack.removeLast() }
                if stack.count != before { out.contexts.append((offset, context)) }
                if let outer = held.last, outer.depth == depth {
                    held.removeLast()
                    depth -= 1
                    pending = outer.pending + "{}"
                    return
                }
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
        /// and emits a `""` placeholder into the code. Returns false when `i` is not a
        /// literal start.
        func lexString() -> Bool {
            var hashes = 0
            while peek(hashes) == "#" { hashes += 1 }
            guard peek(hashes) == "\"" else { return false }
            let startLine = line
            let startContext = context
            let multiline = peek(hashes + 1) == "\"" && peek(hashes + 2) == "\""
            i += hashes + (multiline ? 3 : 1)
            var text = ""
            var detect = ""
            var resolved = ""
            var newlines = 0
            loop: while let c = peek() {
                if c == "\\" && matchesHashes(at: i + 1, hashes) {
                    let after = i + 1 + hashes
                    if after < s.count, s[after] == "(" {
                        i = after + 1
                        let sourceStart = i
                        newlines += skipInterpolation()
                        let source = String(s[sourceStart..<max(sourceStart, i - 1)])
                        text += "\\(" + QueryCensusScanner.normalize(source) + ")"
                        detect += "\\(…)"
                        resolved += "\\(…)"
                        continue
                    }
                    if after < s.count {
                        let (written, value, consumed) = escape(at: after)
                        text += "\\" + String(repeating: "#", count: hashes) + written
                        detect += "\\" + String(repeating: "#", count: hashes) + written
                        resolved += value
                        if written.contains("\n") { newlines += 1 }
                        i = after + consumed
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
                detect.append(c)
                resolved.append(c)
                i += 1
            }
            out.placeholders[offset] = out.literals.count
            out.literals.append(Literal(line: startLine, text: text, detect: detect, resolved: resolved, context: startContext))
            emitCode("\"")
            emitCode("\"")
            for _ in 0..<newlines { emitCode("\n") }
            return true
        }

        /// The escape whose letter is at `index` (after `\` and the raw hashes): its text
        /// as written, the characters it stands for, and how many source characters it
        /// spans from `index`. A backslash before a line break continues the line.
        func escape(at index: Int) -> (written: String, value: String, consumed: Int) {
            let n = s[index]
            switch n {
            case "n": return ("n", "\n", 1)
            case "t": return ("t", "\t", 1)
            case "r": return ("r", "\r", 1)
            case "0": return ("0", "\0", 1)
            case "\n": return ("\n", "", 1)
            case "u":
                guard index + 1 < s.count, s[index + 1] == "{" else { return ("u", "u", 1) }
                var k = index + 2
                var digits = ""
                while k < s.count, s[k] != "}" { digits.append(s[k]); k += 1 }
                let value = UInt32(digits, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
                return ("u{" + digits + "}", value, k - index + 1)
            default: return (String(n), String(n), 1)
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
                    if after < s.count { if s[after] == "\n" { newlines += 1 }; i = after + 1; continue }
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

    // MARK: - Code

    /// The lexed code joined into one text, with its brackets paired.
    private struct Code {
        let text: String
        let ns: NSString
        let u: [UInt16]
        let lineStarts: [Int]
        /// The partner of every bracket, -1 when unpaired.
        let partner: [Int]
        /// The innermost bracket open at each offset (an opening bracket's own entry is
        /// the bracket around it), -1 at the top level.
        let enclosing: [Int]

        static let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t")), newline = UInt16(UInt8(ascii: "\n"))
        static let dot = UInt16(UInt8(ascii: ".")), question = UInt16(UInt8(ascii: "?")), bang = UInt16(UInt8(ascii: "!"))
        static let lt = UInt16(UInt8(ascii: "<")), gt = UInt16(UInt8(ascii: ">")), comma = UInt16(UInt8(ascii: ","))
        static let semicolon = UInt16(UInt8(ascii: ";")), equals = UInt16(UInt8(ascii: "="))
        static let openParen = UInt16(UInt8(ascii: "(")), closeParen = UInt16(UInt8(ascii: ")"))
        static let openBracket = UInt16(UInt8(ascii: "[")), closeBracket = UInt16(UInt8(ascii: "]"))
        static let openBrace = UInt16(UInt8(ascii: "{")), closeBrace = UInt16(UInt8(ascii: "}"))
        static let keywords: Set<String> = [
            "return", "try", "await", "throw", "in", "else", "case", "if", "guard", "while", "let", "var",
            "as", "is", "where", "switch", "defer", "do", "repeat", "for", "some", "any",
        ]

        init(_ lexed: Lexed) {
            text = lexed.code.joined(separator: "\n")
            ns = text as NSString
            u = Array(text.utf16)
            var starts = [0]
            for (k, c) in u.enumerated() where c == Self.newline { starts.append(k + 1) }
            lineStarts = starts
            var partner = Array(repeating: -1, count: u.count)
            var enclosing = Array(repeating: -1, count: u.count)
            var stack: [Int] = []
            for (k, c) in u.enumerated() {
                enclosing[k] = stack.last ?? -1
                switch c {
                case Self.openParen, Self.openBracket, Self.openBrace:
                    stack.append(k)
                case Self.closeParen, Self.closeBracket, Self.closeBrace:
                    let opener = c == Self.closeParen ? Self.openParen : c == Self.closeBracket ? Self.openBracket : Self.openBrace
                    if let top = stack.last, u[top] == opener {
                        stack.removeLast()
                        partner[top] = k
                        partner[k] = top
                        enclosing[k] = stack.last ?? -1
                    }
                default:
                    break
                }
            }
            self.partner = partner
            self.enclosing = enclosing
        }

        /// The 0-based line of an offset.
        func line(of offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        func isIdent(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
        }

        func isSpace(_ c: UInt16) -> Bool { c == Self.space || c == Self.tab || c == Self.newline }

        func substring(_ from: Int, _ to: Int) -> String {
            to > from ? ns.substring(with: NSRange(location: from, length: to - from)) : ""
        }

        /// The start of the expression whose last part begins at `p`: back over member
        /// dots, identifiers, postfix `?`/`!`, generic arguments and bracketed groups.
        func calleeStart(_ p: Int) -> Int {
            var start = p
            while true {
                var j = start - 1
                while j >= 0, isSpace(u[j]) { j -= 1 }
                guard j >= 0 else { return start }
                let c = u[j]
                let head = u[start]
                let wantsOperand = head == Self.dot || head == Self.openParen || head == Self.openBracket
                    || head == Self.question || head == Self.bang || head == Self.lt
                if wantsOperand {
                    if c == Self.closeParen || c == Self.closeBracket {
                        guard partner[j] >= 0 else { return start }
                        start = partner[j]
                        continue
                    }
                    if c == Self.gt, let opener = genericOpen(closing: j) { start = opener; continue }
                    if (c == Self.question || c == Self.bang) && head == Self.dot { start = j; continue }
                    if isIdent(c) {
                        var k = j
                        while k > 0, isIdent(u[k - 1]) { k -= 1 }
                        // A keyword is not an operand: `return .queue(q)`, `try (x)`.
                        if Self.keywords.contains(substring(k, j + 1)) { return start }
                        start = k
                        continue
                    }
                    return start
                }
                if c == Self.dot { start = j; continue }
                return start
            }
        }

        /// The `<` of a generic argument list closed by the `>` at `closing`.
        func genericOpen(closing: Int) -> Int? {
            var level = 0
            var k = closing
            while k >= 0 {
                let c = u[k]
                if c == Self.gt { level += 1 } else if c == Self.lt { level -= 1; if level == 0 { return k } }
                else if !(isIdent(c) || isSpace(c) || c == Self.dot || c == Self.comma || c == Self.question || c == Self.openBracket || c == Self.closeBracket) { return nil }
                k -= 1
            }
            return nil
        }
    }

    // MARK: - Sites

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    private static func scan(file: String, source: String, patterns: Patterns, builds: NSRegularExpression) -> [Site] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lexed = Lexer(normalized, patterns: patterns).run()
        let code = Code(lexed)
        var raw: [(line: Int, lastLine: Int, start: Int, context: String, kind: String, text: String, sql: String)] = []

        for literal in lexed.literals where patterns.first(patterns.sql, literal.detect) {
            raw.append((literal.line, literal.line, -1, literal.context, "sql", normalize(literal.text), literal.resolved))
        }

        var handles = Set<String>()
        for regex in [patterns.typedHandle, patterns.newHandle, patterns.closureHandle] {
            for m in patterns.matches(regex, code.text) {
                let name = code.ns.substring(with: m.range(at: 1))
                if name != "_" && name != "self" { handles.insert(name) }
            }
        }

        var calls: [(start: Int, end: Int)] = []
        var seen = Set<Int>()
        func add(_ start: Int, _ end: Int) {
            guard end > start, seen.insert(start &* 1_000_003 &+ end).inserted else { return }
            calls.append((start, end))
        }
        /// The call whose argument list holds `position`: its `(` and partner.
        func argumentCall(_ position: Int) -> (open: Int, close: Int)? {
            var b = code.enclosing[position]
            while b >= 0 {
                if code.u[b] == Code.openParen { return code.partner[b] >= 0 ? (b, code.partner[b]) : nil }
                if code.u[b] == Code.openBrace { return nil }
                b = code.enclosing[b]
            }
            return nil
        }

        for m in patterns.matches(patterns.api, code.text) {
            let open = m.range.location + m.range.length - 1
            guard code.partner[open] >= 0 else { continue }
            add(code.calleeStart(m.range.location), code.partner[open])
        }

        func addUses(_ names: String, where admits: (Int) -> Bool) {
            for m in patterns.matches(Self.baseUse(names), code.text) where admits(m.range(at: 1).location) {
                let opener = m.range.location + m.range.length - 1
                guard code.partner[opener] >= 0 else { continue }
                add(m.range(at: 1).location, code.partner[opener])
            }
            for m in patterns.matches(Self.argumentUse(names), code.text) where admits(m.range(at: 1).location) {
                guard let call = argumentCall(m.range(at: 1).location) else { continue }
                add(code.calleeStart(call.open), call.close)
            }
        }
        if !handles.isEmpty {
            addUses(handles.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"), where: { _ in true })
        }
        // `$0` is a handle only inside a shorthand closure of a database-access method.
        addUses(#"\$0"#) { position in
            var b = code.enclosing[position]
            while b >= 0, code.u[b] != Code.openBrace { b = code.enclosing[b] }
            guard b >= 0 else { return false }
            let lineStart = code.lineStarts[code.line(of: b)]
            let lineEnd = code.line(of: b) + 1 < code.lineStarts.count ? code.lineStarts[code.line(of: b) + 1] - 1 : code.u.count
            let window = code.substring(lineStart, lineEnd)
            guard let m = patterns.shorthandHandle.firstMatch(in: window, range: NSRange(location: 0, length: (window as NSString).length)) else { return false }
            return lineStart + m.range.location + m.range.length - 1 == b
        }

        let bindings = Bindings(code, patterns)
        for call in calls {
            let text = render(call.start, call.end, code, lexed) + bindingSuffix(call.start, call.end, code, lexed, handles, bindings, builds)
            raw.append((code.line(of: call.start) + 1, code.line(of: call.end) + 1, call.start,
                        context(at: call.start, lexed), "call", text, ""))
        }

        for helper in requestHelpers(code, patterns) {
            let owner = context(at: helper.start, lexed)
            raw.append((code.line(of: helper.start) + 1, code.line(of: helper.close) + 1, helper.start,
                        owner.isEmpty ? helper.name : owner + "." + helper.name, "request",
                        render(helper.start, helper.close, code, lexed, collapsing: false), ""))
        }

        raw.sort { ($0.line, $0.kind, $0.start) < ($1.line, $1.kind, $1.start) }
        var ordinals: [String: Int] = [:]
        return raw.map { r in
            let identity = [r.context, r.kind, r.text].joined(separator: "\t")
            let ordinal = ordinals[identity, default: 0]
            ordinals[identity] = ordinal + 1
            return Site(file: file, context: r.context, kind: r.kind, text: r.text, ordinal: ordinal,
                        line: r.line, lastLine: r.lastLine, sql: r.sql)
        }
    }

    /// A member call on a handle that is not a database-access scope (`db.execute(`,
    /// `held.db` excluded; not `db.write {`). Group 1 is the handle.
    private static func baseUse(_ names: String) -> NSRegularExpression {
        Patterns.regex(#"(?<![.\w$])("# + names + #")\s*\.\s*(?!(?:"# + Patterns.handleMethods + #")\b)\w+\s*[({]"#)
    }

    /// A handle passed as a whole argument (`fetchAll(db)`, `helper(x, db: held.db)`, an
    /// argument alone on its line of a multi-line call). Group 1 is the handle.
    private static func argumentUse(_ names: String) -> NSRegularExpression {
        Patterns.regex(#"(?m)(?:^|[(,])[ \t]*(?:\w+[ \t]*:[ \t]*)?(?:[A-Za-z_]\w*[ \t]*\.[ \t]*)*("# + names + #")[ \t]*(?=[),]|$)"#)
    }

    private static func context(at offset: Int, _ lexed: Lexed) -> String {
        var lo = 0, hi = lexed.contexts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lexed.contexts[mid].offset <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lexed.contexts[lo].context
    }

    /// The code from `start` through `end` on one line: literals with their contents, a
    /// closure body that spans lines as `{ … }` (whole when `collapsing` is false).
    private static func render(_ start: Int, _ end: Int, _ code: Code, _ lexed: Lexed, collapsing: Bool = true) -> String {
        var out = ""
        var p = start
        var segment = start
        while p <= end {
            if let literal = lexed.placeholders[p] {
                out += code.substring(segment, p) + "\"" + lexed.literals[literal].text + "\""
                p += 2
                segment = p
                continue
            }
            if collapsing, code.u[p] == Code.openBrace, code.partner[p] > p, code.partner[p] <= end,
               code.line(of: code.partner[p]) > code.line(of: p) {
                out += code.substring(segment, p) + "{ … }"
                p = code.partner[p] + 1
                segment = p
                continue
            }
            p += 1
        }
        out += code.substring(segment, min(end + 1, code.u.count))
        return normalize(out)
    }

    // MARK: - Local bindings

    /// The `let`/`var` bindings of a file by name (where the keyword is, where the
    /// initializer starts, whether it is a condition: `if let x = y {` opens no closure),
    /// and the plain reassignments of each name (`x = …`).
    private struct Bindings {
        struct Binding {
            let location: Int
            let from: Int
            let conditional: Bool
        }

        var byName: [String: [Binding]] = [:]
        var reassignments: [String: [(location: Int, from: Int)]] = [:]

        static let binding = Patterns.regex(#"(?<![.\w])(if\s+|guard\s+|while\s+)?(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=(?!=)\s*"#)
        static let assignment = Patterns.regex(#"(?<![.\w$])([a-z_]\w*)[ \t]*=(?!=)\s*"#)

        init(_ code: Code, _ patterns: Patterns) {
            for m in patterns.matches(Self.binding, code.text) {
                var b = m.range.location - 1
                while b >= 0, code.isSpace(code.u[b]) { b -= 1 }
                // A second clause of a condition list (`if let a = x, let b = y {`) is a condition too.
                let conditional = m.range(at: 1).location != NSNotFound || (b >= 0 && code.u[b] == Code.comma)
                byName[code.ns.substring(with: m.range(at: 2)), default: []].append(
                    Binding(location: m.range.location, from: m.range.location + m.range.length, conditional: conditional))
            }
            for m in patterns.matches(Self.assignment, code.text) {
                var b = m.range.location
                while b > 0, code.isSpace(code.u[b - 1]) { b -= 1 }
                var w = b
                while w > 0, code.isIdent(code.u[w - 1]) { w -= 1 }
                // `let x =` / `var x =` / `case x =` declare; only a plain `x = …` reassigns.
                if ["let", "var", "case"].contains(code.substring(w, b)) { continue }
                reassignments[code.ns.substring(with: m.range(at: 1)), default: []].append(
                    (m.range.location, m.range.location + m.range.length))
            }
        }
    }

    /// Words that are never a local binding a site reads.
    private static let notBindings = Code.keywords.union(["self", "super", "true", "false", "nil", "inout", "throws", "rethrows", "async"])

    /// Whether a binding at `binding` is in scope at `use`: it is in the use's declaration
    /// or one enclosing it (a binding of another function of the file is not).
    private static func encloses(_ binding: Int, _ use: Int, _ lexed: Lexed) -> Bool {
        let outer = context(at: binding, lexed)
        let inner = context(at: use, lexed)
        return outer.isEmpty || outer == inner || inner.hasPrefix(outer + ".")
    }

    /// The local names the code from `from` up to `to` reads: each name at its own level that
    /// is not a member (`.name`), and the leading name of each argument of a parenthesis at
    /// its own level (after its label, `try`, `await`, a prefix `!` or `&`). Deeper names
    /// (`Column("x") == y`'s `y`) are values, not the request.
    private static func readNames(_ from: Int, _ to: Int, _ code: Code, _ handles: Set<String>) -> [String] {
        let colon = UInt16(UInt8(ascii: ":")), ampersand = UInt16(UInt8(ascii: "&"))
        var names: [String] = []
        func wordEnd(_ p: Int) -> Int {
            var e = p
            while e < code.u.count, code.isIdent(code.u[e]) { e += 1 }
            return e
        }
        func admit(_ name: String) {
            guard let first = name.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) || first == "_",
                  name != "_", !handles.contains(name), !notBindings.contains(name) else { return }
            names.append(name)
        }
        func leadingName(_ start: Int, _ end: Int) {
            var p = start
            func skipSpace() { while p < end, code.isSpace(code.u[p]) { p += 1 } }
            skipSpace()
            if p < end, code.isIdent(code.u[p]) {
                var c = wordEnd(p)
                while c < end, code.isSpace(code.u[c]) { c += 1 }
                if c < end, code.u[c] == colon, !(c + 1 < end && code.u[c + 1] == colon) { p = c + 1 }
            }
            while true {
                skipSpace()
                guard p < end else { return }
                if code.u[p] == Code.bang || code.u[p] == ampersand { p += 1; continue }
                guard code.isIdent(code.u[p]) else { return }
                let e = wordEnd(p)
                let word = code.substring(p, e)
                guard word == "try" || word == "await" else { admit(word); return }
                p = e
                if p < end, code.u[p] == Code.question || code.u[p] == Code.bang { p += 1 }
            }
        }
        var p = from
        while p < to {
            let c = code.u[p]
            if c == Code.openParen, code.partner[p] > p, code.partner[p] < to {
                var argument = p + 1
                var q = p + 1
                while q < code.partner[p] {
                    let d = code.u[q]
                    if d == Code.openParen || d == Code.openBracket || d == Code.openBrace, code.partner[q] > q {
                        q = code.partner[q] + 1
                        continue
                    }
                    if d == Code.comma { leadingName(argument, q); argument = q + 1 }
                    q += 1
                }
                leadingName(argument, code.partner[p])
                p = code.partner[p] + 1
                continue
            }
            if (c == Code.openBracket || c == Code.openBrace), code.partner[p] > p {
                p = code.partner[p] + 1
                continue
            }
            if code.isIdent(c), p == 0 || !code.isIdent(code.u[p - 1]) {
                let e = wordEnd(p)
                var b = p - 1
                while b >= from, code.isSpace(code.u[b]) { b -= 1 }
                if !(b >= from && code.u[b] == Code.dot) { admit(code.substring(p, e)) }
                p = e
                continue
            }
            p += 1
        }
        return names
    }

    /// Whether the line that ends at `newline` runs on into the next, whose first character
    /// is at `next`: the next line starts with a member `.` or a binary operator, or this
    /// line ends with one.
    private static func continues(_ newline: Int, _ next: Int, _ code: Code) -> Bool {
        let leading = Set(".?:&|=+*/".utf16)
        if leading.contains(code.u[next]) { return true }
        if code.u[next] == Code.bang, next + 1 < code.u.count, code.u[next + 1] == Code.equals { return true }
        var b = newline - 1
        while b >= 0, code.u[b] == Code.space || code.u[b] == Code.tab { b -= 1 }
        return b >= 0 && Set("&|=+*".utf16).contains(code.u[b])
    }

    /// The end (exclusive) of the expression that starts at `from`, before `limit`: up to a
    /// `,`, `;` or closing bracket of its own level, `else`, or a line end the next line does
    /// not continue; each bracketed group whole (a brace only when not `conditional`).
    private static func expressionEnd(_ from: Int, limit: Int, conditional: Bool, _ code: Code) -> Int {
        var q = from
        scan: while q < code.u.count, q < limit {
            let c = code.u[q]
            switch c {
            case Code.openParen, Code.openBracket:
                guard code.partner[q] > q, code.partner[q] < limit else { break scan }
                q = code.partner[q] + 1
            case Code.openBrace:
                guard !conditional, code.partner[q] > q, code.partner[q] < limit else { break scan }
                q = code.partner[q] + 1
            case Code.newline:
                var n = q + 1
                while n < code.u.count, code.isSpace(code.u[n]) { n += 1 }
                guard n < code.u.count, continues(q, n, code) else { break scan }
                q = n
            case Code.semicolon, Code.comma, Code.closeParen, Code.closeBracket, Code.closeBrace:
                break scan
            default:
                if code.isIdent(c), q == 0 || !code.isIdent(code.u[q - 1]) {
                    var e = q
                    while e < code.u.count, code.isIdent(code.u[e]) { e += 1 }
                    if code.substring(q, e) == "else" { break scan }
                    q = e
                } else {
                    q += 1
                }
            }
        }
        return q
    }

    /// What builds a request or a filter expression: a GRDB request method, `SQLRequest`,
    /// `SQL(`, `Column(`, the request types. A call of a request helper is added per scan.
    static let requestTokens = #"\.(?:filter|order|select|limit|all|none|including|joining|group|having|annotated|matching|distinct|aliased|orderByPrimaryKey)\s*\(|\b(?:SQLRequest|QueryInterfaceRequest|SQLExpression|SQL|Column)\b"#

    /// The code from `from` up to `to` with every brace group left out.
    private static func outsideClosures(_ from: Int, _ to: Int, _ code: Code) -> String {
        var out = ""
        var segment = from
        var p = from
        while p < to {
            if code.u[p] == Code.openBrace, code.partner[p] > p {
                out += code.substring(segment, p) + " "
                p = code.partner[p] + 1
                segment = p
                continue
            }
            p += 1
        }
        return out + code.substring(segment, max(segment, min(to, code.u.count)))
    }

    /// The words of a code text.
    private static func names(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }.map(String.init)
    }

    /// One definition of a binding: its initializer or a plain reassignment, with where it is.
    private struct Definition {
        let location: Int
        let from: Int
        let end: Int
    }

    /// The binding of `name` in scope at `use`, and its definitions before `use`: the
    /// initializer, then each plain reassignment.
    private static func definitions(_ name: String, _ use: Int, _ code: Code, _ lexed: Lexed, _ bindings: Bindings) -> (binding: Int, definitions: [Definition])? {
        guard let binding = bindings.byName[name]?.last(where: { $0.location < use && encloses($0.location, use, lexed) }) else { return nil }
        var found: [Definition] = []
        let end = expressionEnd(binding.from, limit: use, conditional: binding.conditional, code)
        if end > binding.from { found.append(Definition(location: binding.location, from: binding.from, end: end)) }
        for assignment in bindings.reassignments[name] ?? []
        where assignment.location > binding.from && assignment.location < use && encloses(binding.location, assignment.location, lexed) {
            let end = expressionEnd(assignment.from, limit: use, conditional: false, code)
            if end > assignment.from { found.append(Definition(location: assignment.location, from: assignment.from, end: end)) }
        }
        return (binding.location, found)
    }

    /// ` ⟨name = …⟩` for the request bindings a call reads, so an edit of the request it
    /// runs, wherever it was built, changes the key: its receiver's binding (whatever it
    /// holds, as a record a write persists), and each binding read as an argument's leading
    /// name (`readNames`) that builds a request: outside its closures it has a
    /// `requestTokens` match or reads a binding that builds one, and names no database handle
    /// (one that does runs a query, a site of its own, and holds its result). Each comes with
    /// its plain reassignments before the call, then the same for the request bindings those
    /// read. A binding is the last one of its name before the use, in the use's declaration or
    /// one enclosing it. A binding that only holds a value (`accountId`, fetched rows) is not
    /// carried: its edits change no query.
    private static func bindingSuffix(_ start: Int, _ end: Int, _ code: Code, _ lexed: Lexed, _ handles: Set<String>,
                                      _ bindings: Bindings, _ builds: NSRegularExpression) -> String {
        var memo: [Int: Bool] = [:]
        func buildsRequest(_ name: String, _ use: Int, _ visiting: Set<Int>) -> Bool {
            guard let defined = definitions(name, use, code, lexed, bindings) else { return false }
            let binding = defined.binding
            if let known = memo[binding] { return known }
            guard !visiting.contains(binding) else { return false }
            // Each definition outside its closures (their queries are sites of their own); one
            // that names a handle runs a query and holds its result, a value.
            let texts = defined.definitions.map { outsideClosures($0.from, $0.end, code) }
            let result = !texts.contains { names(in: $0).contains { handles.contains($0) } }
                && zip(defined.definitions, texts).contains { definition, text in
                    builds.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
                        || readNames(definition.from, definition.end, code, handles).contains {
                            buildsRequest($0, definition.location, visiting.union([binding]))
                        }
                }
            memo[binding] = result
            return result
        }

        var receiverEnd = start
        while receiverEnd < code.u.count, code.isIdent(code.u[receiverEnd]) { receiverEnd += 1 }
        var afterReceiver = receiverEnd
        while afterReceiver < code.u.count, code.isSpace(code.u[afterReceiver]) { afterReceiver += 1 }
        let receiver = afterReceiver < code.u.count && code.u[afterReceiver] == Code.dot ? code.substring(start, receiverEnd) : ""

        var out = ""
        var rendered = Set<Int>()
        var pending = readNames(start, end + 1, code, handles).map { (name: $0, use: start) }
        var next = 0
        while next < pending.count {
            let (name, use) = pending[next]
            next += 1
            guard let defined = definitions(name, use, code, lexed, bindings), !rendered.contains(defined.binding),
                  (next == 1 && name == receiver) || buildsRequest(name, use, []) else { continue }
            rendered.insert(defined.binding)
            for definition in defined.definitions {
                out += " ⟨\(name) = \(render(definition.from, definition.end - 1, code, lexed))⟩"
                pending += readNames(definition.from, definition.end, code, handles).map { ($0, definition.location) }
            }
        }
        return out
    }

    // MARK: - Request helpers

    static let requestFunction = Patterns.regex(#"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^(){}]*>)?\s*\("#)
    static let requestReturn = Patterns.regex(#"(?s)^(?!.*\b(?:func|var|let|init|subscript|case)\b)\s*(?:async\s+)?(?:(?:re)?throws(?:\s*\([^)]*\))?\s+)?->\s*(?:some\s+|any\s+)?(?:GRDB\.)?(?:QueryInterfaceRequest|SQLRequest|SQLExpression)\b[^{};]*$"#)
    static let requestProperty = Patterns.regex(#"\bvar\s+([A-Za-z_]\w*)\s*:\s*(?:some\s+|any\s+)?(?:GRDB\.)?(?:QueryInterfaceRequest|SQLRequest|SQLExpression)\b[^={}\n]*\{"#)

    /// Each function or computed property that returns a request or an SQL expression: where
    /// its `func`/`var` is, its name, and its body's braces.
    private static func requestHelpers(_ code: Code, _ patterns: Patterns) -> [(start: Int, name: String, open: Int, close: Int)] {
        var found: [(start: Int, name: String, open: Int, close: Int)] = []
        for m in patterns.matches(requestFunction, code.text) {
            let paren = m.range.location + m.range.length - 1
            guard code.partner[paren] > paren else { continue }
            var brace = code.partner[paren] + 1
            while brace < code.u.count, code.u[brace] != Code.openBrace, code.u[brace] != Code.closeBrace { brace += 1 }
            guard brace < code.u.count, code.u[brace] == Code.openBrace, code.partner[brace] > brace,
                  patterns.first(requestReturn, code.substring(code.partner[paren] + 1, brace)) else { continue }
            found.append((m.range.location, code.ns.substring(with: m.range(at: 1)), brace, code.partner[brace]))
        }
        for m in patterns.matches(requestProperty, code.text) {
            let brace = m.range.location + m.range.length - 1
            guard code.partner[brace] > brace else { continue }
            found.append((m.range.location, code.ns.substring(with: m.range(at: 1)), brace, code.partner[brace]))
        }
        return found
    }
}
