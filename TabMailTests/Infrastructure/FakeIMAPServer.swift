/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail
#if canImport(Glibc)
import Glibc
#endif

/// A minimal IMAP4rev1 server for provider-level tests, adapted from
/// `IMAPTestServer.swift` in the SwiftMail fork's `Tests/SwiftIMAPTests/`
/// (github.com/TabMail/SwiftMail).
/// Uses POSIX sockets directly because `Network.framework`'s NWListener has
/// known issues in the iOS simulator.
///
/// Differences from the SwiftMail reference:
/// - Accepts an in-memory `[Message]` array instead of loading from a Maildir.
/// - BODYSTRUCTURE builder will grow to emit nested `message/rfc822` parts as
///   test coverage expands. Today it emits single-part
///   BODYSTRUCTURE for flat messages only — enough to prove the IMAPProvider
///   round-trip works against a fake server on localhost:ephemeral-port.
///
/// Wire format references (for every response this server emits):
/// - RFC 3501 §6.4.5 (FETCH), §7.4.2 (FETCH response), §7.1 (OK/BAD/NO/BYE)
/// - RFC 9051 (IMAP4rev2)
/// - RFC 2087 (QUOTA), RFC 2177 (IDLE) — if/when added
///
/// Discipline: do NOT invent response shapes. Every literal below is checked
/// against the cited RFC sections in `TabMailTests/Fixtures/README.md`.
final class FakeIMAPServer: @unchecked Sendable {
    struct Message: Sendable {
        let uid: Int
        let raw: Data            // full RFC 2822 message bytes (must use CRLF line endings)
        let subject: String
        let from: String
        let to: String
        let date: String          // RFC 2822 Date header value
        let internalDate: String  // IMAP format: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
        let messageID: String
        let contentType: String
        let charset: String
        let body: Data
        let headerData: Data
        /// When set, the fake server emits this raw BODYSTRUCTURE literal
        /// instead of its auto-generated flat single-part structure. Used by
        /// tests that need multipart or nested `message/rfc822` BODYSTRUCTURE
        /// shapes.
        /// The literal must be a valid RFC 3501 §7.4.2 body-type-1part or
        /// body-type-mpart — no outer parentheses added by the server.
        let customBodystructure: String?
        /// When set, requests for `BODY[N]` / `BODY.PEEK[N]` look up the raw
        /// bytes here (keyed by section string, e.g. `"1"`, `"2"`, `"2.1"`).
        /// Falls back to slicing `body` only when nil.
        let partBodies: [String: Data]?

        func replacingUID(_ uid: Int) -> Message {
            Message(
                uid: uid,
                raw: raw,
                subject: subject,
                from: from,
                to: to,
                date: date,
                internalDate: internalDate,
                messageID: messageID,
                contentType: contentType,
                charset: charset,
                body: body,
                headerData: headerData,
                customBodystructure: customBodystructure,
                partBodies: partBodies
            )
        }
    }

    private struct State {
        var messagesByMailbox: [String: [Message]]
        var flagsByMailbox: [String: [Int: Set<String>]] = [:]
        var commandLog: [String] = []
        var injectedFailureCountdowns: [String: [Int]] = [:]
        var consumedInjectedFailureCount = 0
        /// Mailboxes SELECT must reject as gone. Value = whether the NO
        /// response carries the RFC 5530 `[NONEXISTENT]` response code (the
        /// "hint" shape) or is a plain unstructured NO (the non-RFC-5530
        /// shape some real servers send). LIST also excludes these names
        /// regardless of shape — the LIST probe is the authority either way.
        var deletedMailboxes: [String: Bool] = [:]
    }

    let host: String
    let username: String
    let password: String
    private(set) var port: Int

    /// Wire-order CAPABILITY tokens this server advertises, both in the
    /// connection greeting and the `CAPABILITY` command response. Defaults
    /// to the original hardcoded set. SPEC-B4 constructs a server WITHOUT
    /// `MOVE`/`UIDPLUS` to force SwiftMail's COPY+STORE+EXPUNGE fallback
    /// (RFC 6851 — see `IMAPServer+Manipulation.swift`'s `move` in the
    /// pinned SwiftMail fork).
    static let defaultCapabilities = ["IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "UIDPLUS", "MOVE", "IDLE"]
    private let capabilities: [String]

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "FakeIMAPServer")
    private let stateLock = NSLock()
    private var state: State
    private var clientFds: [Int32] = []

    init(
        host: String = "localhost", port: Int = 0, username: String = "testuser", password: String = "testpass",
        capabilities: [String] = FakeIMAPServer.defaultCapabilities, messages: [Message]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.capabilities = capabilities
        self.state = State(messagesByMailbox: ["INBOX": messages])
    }

    init(
        host: String = "localhost", port: Int = 0, username: String = "testuser", password: String = "testpass",
        capabilities: [String] = FakeIMAPServer.defaultCapabilities, mailboxes: [String: [Message]]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.capabilities = capabilities
        self.state = State(messagesByMailbox: mailboxes)
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    func messageIDs(in mailbox: String) -> [String] {
        withState { state in
            (state.messagesByMailbox[mailbox] ?? []).map(\.messageID)
        }
    }

    func flags(in mailbox: String, uid: Int) -> Set<String> {
        withState { state in
            state.flagsByMailbox[mailbox]?[uid] ?? []
        }
    }

    func recordedCommands() -> [String] {
        withState { $0.commandLog }
    }

    func consumedInjectedFailureCount() -> Int {
        withState { $0.consumedInjectedFailureCount }
    }

    func failNextCommand(containing fragment: String) {
        failCommand(containing: fragment, onMatch: 1)
    }

    func failCommand(containing fragment: String, onMatch: Int) {
        withState { state in
            state.injectedFailureCountdowns[fragment.uppercased(), default: []]
                .append(max(0, onMatch - 1))
        }
    }

    func setFlags(_ flags: Set<String>, in mailbox: String, uid: Int) {
        withState { state in
            state.flagsByMailbox[mailbox, default: [:]][uid] = flags
        }
    }

    /// Simulate a mailbox deleted remotely between enqueue and drain: SELECT
    /// (and EXAMINE) of `name` now fails with a NO response, and LIST no
    /// longer reports it present. `includeNonexistentCode`:
    ///   - `true` — NO response carries `[NONEXISTENT]` (RFC 5530 §3), the
    ///     shape some servers send.
    ///   - `false` — plain unstructured `NO select failed` with no response
    ///     code, the non-RFC-5530 shape other real servers send. The provider
    ///     adapter must not rely on parsing this shape at all — the LIST
    ///     probe is the sole authority in both cases.
    func markMailboxDeleted(_ name: String, includeNonexistentCode: Bool) {
        withState { $0.deletedMailboxes[name] = includeNonexistentCode }
    }

    enum ServerError: Error {
        case setup(String)
    }

    func start() throws {
        #if os(Linux)
        listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listenFd >= 0 else { throw ServerError.setup("socket() failed: \(errno)") }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if !os(Linux)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            throw ServerError.setup("bind() failed: \(errno)")
        }

        guard listen(listenFd, 5) == 0 else {
            close(listenFd)
            throw ServerError.setup("listen() failed: \(errno)")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFd, $0, &addrLen)
            }
        }
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFd, fd >= 0 {
                close(fd)
                self?.listenFd = -1
            }
        }
        self.acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for fd in clientFds { close(fd) }
        clientFds.removeAll()
    }

    // MARK: - Message Builder

    /// Build a `Message` from an RFC 2822 text document with CRLF line endings.
    /// Parses a minimum set of headers and splits header/body on the first
    /// `CRLF CRLF`. `contentType` defaults to text/plain when the Content-Type
    /// header is missing.
    static func makeMessage(uid: Int, rfc822Text: String) -> Message {
        let raw = Data(rfc822Text.utf8)
        let headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
            ?? raw.range(of: Data("\n\n".utf8))
        let headerData: Data
        let body: Data
        if let r = headerEnd {
            headerData = Data(raw[..<r.upperBound])
            body = Data(raw[r.upperBound...])
        } else {
            headerData = raw
            body = Data()
        }
        let headers = String(data: headerData, encoding: .utf8) ?? ""

        func header(_ name: String) -> String {
            let pattern = "(?m)^\(name):[ \t]*(.+?)[ \t]*$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
                  let range = Range(match.range(at: 1), in: headers) else { return "" }
            return String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let ctRaw = header("Content-Type")
        let ct: String
        let charset: String
        if ctRaw.contains(";") {
            let parts = ctRaw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            ct = parts[0]
            charset = parts.first(where: { $0.lowercased().hasPrefix("charset=") })
                .map { String($0.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? "utf-8"
        } else {
            ct = ctRaw.isEmpty ? "text/plain" : ctRaw
            charset = "utf-8"
        }

        let dateStr = header("Date")
        let internalDate: String
        // Use the shared RFC 2822 parser — accepts both "1 Oct" and "01 Oct"
        // (single-digit and zero-padded days), per RFC 5322 §3.3.
        if let date = EmailDateParsing.rfc2822.date(from: dateStr) {
            let imap = DateFormatter()
            imap.locale = Locale(identifier: "en_US_POSIX")
            imap.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
            internalDate = imap.string(from: date)
        } else {
            internalDate = "01-Jan-2026 00:00:00 +0000"
        }

        return Message(
            uid: uid,
            raw: raw,
            subject: header("Subject"),
            from: header("From"),
            to: header("To"),
            date: dateStr,
            internalDate: internalDate,
            messageID: header("Message-ID"),
            contentType: ct,
            charset: charset,
            body: body,
            headerData: headerData,
            customBodystructure: nil,
            partBodies: nil
        )
    }

    /// Build a `Message` with a custom multipart/rfc822 BODYSTRUCTURE and
    /// per-section body bodies. Use when the auto-parsed flat shape from
    /// `makeMessage(uid:rfc822Text:)` is insufficient — e.g., multipart
    /// bodies or nested `message/rfc822` parts.
    ///
    /// `headerData` is the top-level RFC 2822 headers (the part the client
    /// gets when it asks for `BODY[HEADER]`). `raw` is the full message bytes.
    static func makeMultipartMessage(
        uid: Int,
        subject: String,
        from: String,
        to: String,
        date: String,
        internalDate: String,
        messageID: String,
        rawHeader: String,
        fullMessage: Data,
        bodystructure: String,
        partBodies: [String: Data]
    ) -> Message {
        let header = Data(rawHeader.utf8)
        return Message(
            uid: uid,
            raw: fullMessage,
            subject: subject,
            from: from,
            to: to,
            date: date,
            internalDate: internalDate,
            messageID: messageID,
            contentType: "multipart/mixed",
            charset: "utf-8",
            body: Data(),
            headerData: header,
            customBodystructure: bodystructure,
            partBodies: partBodies
        )
    }

    // MARK: - Connection Handling

    private func acceptClient() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        clientFds.append(clientFd)

        DispatchQueue.global().async { [weak self] in
            self?.handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        sendLine(fd: fd, "* OK [CAPABILITY \(capabilities.joined(separator: " "))] FakeIMAP ready\r\n")

        var buffer = Data()
        var authenticated = false
        var selectedMailbox: String?
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        var idleTag: String? = nil

        /// Blocking read of more bytes into `buffer`. Returns false when the
        /// connection closed (caller must stop processing this client).
        func readMore() -> Bool {
            let n = read(fd, readBuf, 65536)
            guard n > 0 else { return false }
            buffer.append(readBuf, count: n)
            return true
        }

        clientLoop: while true {
            if !readMore() { break }

            while let crlfRange = buffer.range(of: Data("\r\n".utf8)) {
                var lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                var consumedThrough = crlfRange.upperBound

                // IMAP literal handling (RFC 3501 §4.3, RFC 7888 non-
                // synchronizing literals). NIOIMAP switches a long/otherwise
                // "unsafe" quoted-string argument (e.g. a HEADER search
                // criterion value) to a trailing `{N}` / `{N+}` literal
                // marker followed by exactly N raw bytes, then the command's
                // own terminating CRLF. This fake only ever needs to splice
                // ONE trailing literal per logical command line back in as a
                // quoted string — the CAPABILITY response above already
                // advertises LITERAL+, so a client is entitled to send one.
                while let spec = Self.trailingLiteralSpec(lineData) {
                    if spec.needsContinuationResponse {
                        sendLine(fd: fd, "+ OK\r\n")
                    }
                    while buffer.count < consumedThrough + spec.length {
                        if !readMore() { break clientLoop }
                    }
                    let literalBytes = buffer[consumedThrough..<(consumedThrough + spec.length)]
                    let literalString = String(data: literalBytes, encoding: .utf8) ?? ""
                    var afterLiteral = consumedThrough + spec.length
                    while buffer.count < afterLiteral + 2 {
                        if !readMore() { break clientLoop }
                    }
                    // The literal's raw bytes are followed by the command's
                    // own terminating CRLF (RFC 3501 literal syntax — no
                    // other separator is valid here).
                    guard buffer[afterLiteral] == 0x0D, buffer[afterLiteral + 1] == 0x0A else { break clientLoop }
                    afterLiteral += 2
                    lineData = Self.splicingLiteral(into: lineData, literal: literalString)
                    consumedThrough = afterLiteral
                }

                buffer = Data(buffer[consumedThrough...])
                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                if let tag = idleTag, line.uppercased() == "DONE" {
                    sendLine(fd: fd, "\(tag) OK IDLE terminated\r\n")
                    idleTag = nil
                    continue
                }

                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    sendLine(fd: fd, "* BAD Invalid command\r\n")
                    continue
                }

                let tag = parts[0]
                let command = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""
                let recordedCommand = ([command] + (args.isEmpty ? [] : [args])).joined(separator: " ")
                let shouldFail = withState { state -> Bool in
                    state.commandLog.append(recordedCommand)
                    let upper = recordedCommand.uppercased()
                    guard let key = state.injectedFailureCountdowns.keys.sorted().first(where: {
                        upper.contains($0) && !(state.injectedFailureCountdowns[$0] ?? []).isEmpty
                    }), var countdowns = state.injectedFailureCountdowns[key]
                    else { return false }
                    if countdowns[0] == 0 {
                        countdowns.removeFirst()
                        state.injectedFailureCountdowns[key] = countdowns
                        state.consumedInjectedFailureCount += 1
                        return true
                    }
                    countdowns[0] -= 1
                    state.injectedFailureCountdowns[key] = countdowns
                    return false
                }
                if shouldFail {
                    sendLine(fd: fd, "\(tag) NO Injected test failure\r\n")
                    continue
                }

                if command == "IDLE" {
                    sendLine(fd: fd, "+ idling\r\n")
                    idleTag = tag
                    continue
                }

                let response = handleCommand(
                    tag: tag, command: command, args: args,
                    authenticated: &authenticated, selectedMailbox: &selectedMailbox
                )
                sendLine(fd: fd, response)

                if command == "LOGOUT" {
                    close(fd)
                    return
                }
            }
        }

        close(fd)
    }

    private func sendLine(fd: Int32, _ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr + sent, data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    // MARK: - Command Handling

    private func handleCommand(tag: String, command: String, args: String, authenticated: inout Bool, selectedMailbox: inout String?) -> String {
        switch command {
        case "CAPABILITY":
            return "* CAPABILITY \(capabilities.joined(separator: " "))\r\n\(tag) OK CAPABILITY completed\r\n"
        case "LOGIN":
            authenticated = true
            return "\(tag) OK LOGIN completed\r\n"
        case "SELECT", "EXAMINE":
            guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
            let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
            if let includeNonexistentCode = withState({ $0.deletedMailboxes[mailbox] }) {
                // Deliberately two distinct real-world shapes: `[NONEXISTENT]`
                // (RFC 5530 §3) is a fast-path HINT the adapter may use, but
                // never the sole authority — a plain, code-less NO is exactly
                // as authoritative-refusable once the adapter's LIST probe
                // (not this response text) confirms absence.
                return includeNonexistentCode
                    ? "\(tag) NO [NONEXISTENT] Mailbox does not exist\r\n"
                    : "\(tag) NO Mailbox does not exist\r\n"
            }
            selectedMailbox = mailbox
            let messages = withState { $0.messagesByMailbox[mailbox] ?? [] }
            let count = messages.count
            let uidnext = (messages.map(\.uid).max() ?? 0) + 1
            return """
            * \(count) EXISTS\r
            * 0 RECENT\r
            * OK [UIDVALIDITY 1] UIDs valid\r
            * OK [UIDNEXT \(uidnext)] Predicted next UID\r
            * FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r
            * OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Flags permitted\r
            \(tag) OK [READ-WRITE] SELECT completed\r

            """
        case "UID":
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            return handleUID(tag: tag, args: args, mailbox: selectedMailbox)
        case "FETCH":
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            return handleFetch(tag: tag, args: args, uidMode: false, mailbox: selectedMailbox)
        case "NAMESPACE":
            return "* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n\(tag) OK NAMESPACE completed\r\n"
        case "LIST":
            // Reflects actual mailbox presence (unlike the old static "always
            // INBOX" stub) so `mailboxConfirmedAbsent`'s LIST probe is
            // meaningfully exercised: a name is "present" only if it has a
            // `messagesByMailbox` entry and was never `markMailboxDeleted`.
            let pattern = args.replacingOccurrences(of: "\"", with: "")
                .split(separator: " ").map(String.init).last ?? "*"
            let matches: [String] = withState { state in
                state.messagesByMailbox.keys
                    .filter { state.deletedMailboxes[$0] == nil }
                    .filter { Self.imapListPatternMatches(pattern: pattern, name: $0) }
                    .sorted()
            }
            var response = matches.map { "* LIST (\\HasNoChildren) \"/\" \"\($0)\"\r\n" }.joined()
            response += "\(tag) OK LIST completed\r\n"
            return response
        case "ID":
            return "* ID NIL\r\n\(tag) OK ID completed\r\n"
        case "EXPUNGE":
            // Plain (non-UID) EXPUNGE — RFC 3501 §6.4.3. Mailbox-WIDE: removes
            // every \Deleted-flagged message in the SELECTed mailbox, not just
            // a targeted set. This is what SwiftMail's MOVE fallback issues
            // when UIDPLUS is absent (`expungeMoveFallback`, SPEC-B4).
            guard let selectedMailbox else { return "\(tag) NO No mailbox selected\r\n" }
            withState { state in
                let sourceMessages = state.messagesByMailbox[selectedMailbox] ?? []
                let mailboxFlags = state.flagsByMailbox[selectedMailbox] ?? [:]
                let deletedUIDs = Set(sourceMessages.map(\.uid).filter { mailboxFlags[$0]?.contains("\\Deleted") ?? false })
                state.messagesByMailbox[selectedMailbox] = sourceMessages.filter { !deletedUIDs.contains($0.uid) }
                for uid in deletedUIDs {
                    state.flagsByMailbox[selectedMailbox]?.removeValue(forKey: uid)
                }
            }
            return "\(tag) OK EXPUNGE completed\r\n"
        case "NOOP":
            return "\(tag) OK NOOP completed\r\n"
        case "LOGOUT":
            return "* BYE IMAP server shutting down\r\n\(tag) OK LOGOUT completed\r\n"
        default:
            return "\(tag) BAD Unknown command \(command)\r\n"
        }
    }

    private func handleUID(tag: String, args: String, mailbox: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard let subcmd = parts.first?.uppercased() else {
            return "\(tag) BAD Missing UID subcommand\r\n"
        }
        let subargs = parts.count > 1 ? parts[1] : ""
        switch subcmd {
        case "FETCH":
            return handleFetch(tag: tag, args: subargs, uidMode: true, mailbox: mailbox)
        case "SEARCH":
            // Honor HEADER "Message-ID" "<...>" criterion when present; otherwise
            // return all UIDs (legacy behavior). Minimal filter to support
            // IMAPProvider's messageExistsInFolder / idempotentMove probe path.
            let upper = subargs.uppercased()
            if let range = upper.range(of: "HEADER \"MESSAGE-ID\"") {
                // Next quoted string after the criterion is the Message-ID pattern.
                let after = subargs[range.upperBound...]
                let quoted = Self.firstQuoted(String(after)) ?? ""
                // Strip any angle brackets on both sides. `messageID` comes
                // from the raw header value and typically includes "<...>".
                let bracketSet = CharacterSet(charactersIn: "<>")
                let bareQuery = quoted.trimmingCharacters(in: bracketSet)
                let matched = withState { $0.messagesByMailbox[mailbox] ?? [] }
                    .filter {
                        $0.messageID.trimmingCharacters(in: bracketSet).contains(bareQuery)
                    }
                    .map { String($0.uid) }
                return "* SEARCH \(matched.joined(separator: " "))\r\n\(tag) OK UID SEARCH completed\r\n"
            }
            let uids = withState { $0.messagesByMailbox[mailbox] ?? [] }
                .map { String($0.uid) }
                .joined(separator: " ")
            return "* SEARCH \(uids)\r\n\(tag) OK UID SEARCH completed\r\n"
        case "STORE":
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID STORE\r\n" }
            let uids = parseUIDSet(components[0])
            let operation = components[1].uppercased()
            let flags = Self.parenthesizedTokens(components[1])
            withState { state in
                var mailboxFlags = state.flagsByMailbox[mailbox] ?? [:]
                for uid in uids {
                    var current = mailboxFlags[uid] ?? []
                    if operation.contains("+FLAGS") {
                        current.formUnion(flags)
                    } else if operation.contains("-FLAGS") {
                        current.subtract(flags)
                    } else {
                        current = flags
                    }
                    mailboxFlags[uid] = current
                }
                state.flagsByMailbox[mailbox] = mailboxFlags
            }
            return "\(tag) OK UID STORE completed\r\n"
        case "MOVE":
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID MOVE\r\n" }
            let uids = Set(parseUIDSet(components[0]))
            let destination = components[1].trimmingCharacters(in: .init(charactersIn: "\""))
            withState { state in
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                let moving = sourceMessages.filter { uids.contains($0.uid) }
                state.messagesByMailbox[mailbox] = sourceMessages.filter { !uids.contains($0.uid) }

                var destinationMessages = state.messagesByMailbox[destination] ?? []
                var nextUID = (destinationMessages.map(\.uid).max() ?? 0) + 1
                var sourceFlags = state.flagsByMailbox[mailbox] ?? [:]
                var destinationFlags = state.flagsByMailbox[destination] ?? [:]
                for message in moving {
                    destinationMessages.append(message.replacingUID(nextUID))
                    destinationFlags[nextUID] = sourceFlags.removeValue(forKey: message.uid) ?? []
                    nextUID += 1
                }
                state.messagesByMailbox[destination] = destinationMessages
                state.flagsByMailbox[mailbox] = sourceFlags
                state.flagsByMailbox[destination] = destinationFlags
            }
            return "\(tag) OK UID MOVE completed\r\n"
        case "EXPUNGE":
            let uids = Set(parseUIDSet(subargs))
            withState { state in
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                state.messagesByMailbox[mailbox] = sourceMessages.filter { !uids.contains($0.uid) }
                for uid in uids {
                    state.flagsByMailbox[mailbox]?.removeValue(forKey: uid)
                }
            }
            return "\(tag) OK UID EXPUNGE completed\r\n"
        case "COPY":
            // RFC 3501 §6.4.7 — leaves the SOURCE untouched, unlike MOVE.
            // This is the first step of SwiftMail's no-MOVE-capability
            // fallback (COPY + STORE \Deleted + EXPUNGE, SPEC-B4).
            let components = subargs.split(separator: " ", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return "\(tag) BAD Invalid UID COPY\r\n" }
            let uids = Set(parseUIDSet(components[0]))
            let destination = components[1].trimmingCharacters(in: .init(charactersIn: "\""))
            withState { state in
                let sourceMessages = state.messagesByMailbox[mailbox] ?? []
                let copying = sourceMessages.filter { uids.contains($0.uid) }
                var destinationMessages = state.messagesByMailbox[destination] ?? []
                var nextUID = (destinationMessages.map(\.uid).max() ?? 0) + 1
                let sourceFlags = state.flagsByMailbox[mailbox] ?? [:]
                var destinationFlags = state.flagsByMailbox[destination] ?? [:]
                for message in copying {
                    destinationMessages.append(message.replacingUID(nextUID))
                    destinationFlags[nextUID] = sourceFlags[message.uid] ?? []
                    nextUID += 1
                }
                state.messagesByMailbox[destination] = destinationMessages
                state.flagsByMailbox[destination] = destinationFlags
            }
            return "\(tag) OK UID COPY completed\r\n"
        default:
            return "\(tag) BAD Unknown UID subcommand\r\n"
        }
    }

    private func parseUIDSet(_ value: String) -> [Int] {
        value.split(separator: ",").flatMap { component -> [Int] in
            let bounds = component.split(separator: ":").compactMap { Int($0) }
            if bounds.count == 2 {
                return Array(bounds[0]...bounds[1])
            }
            return bounds.first.map { [$0] } ?? []
        }
    }

    private static func parenthesizedTokens(_ value: String) -> Set<String> {
        guard let open = value.firstIndex(of: "("),
              let close = value[open...].firstIndex(of: ")") else { return [] }
        return Set(value[value.index(after: open)..<close].split(separator: " ").map(String.init))
    }

    /// Extract the first quoted token from a fragment. Used to parse
    /// `HEADER "Message-ID" "<id>"` arguments without a full tokenizer.
    private static func firstQuoted(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "\"") else { return nil }
        let afterOpen = s.index(after: open)
        guard let close = s[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(s[afterOpen..<close])
    }

    /// Detects a trailing IMAP literal marker (`{N}` or `{N+}`, RFC 3501
    /// §4.3 / RFC 7888) at the end of a not-yet-terminated command line.
    /// `needsContinuationResponse` is true for the synchronizing `{N}` form
    /// (server must send `+ OK` before the client sends the N bytes) and
    /// false for the non-synchronizing `{N+}` form (client sends immediately
    /// — this fake's CAPABILITY advertises LITERAL+, so real clients use
    /// this form here).
    private static func trailingLiteralSpec(_ lineData: Data) -> (length: Int, needsContinuationResponse: Bool)? {
        guard let line = String(data: lineData, encoding: .utf8), line.hasSuffix("}"),
              let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        let needsContinuationResponse: Bool
        if digits.hasSuffix("+") {
            needsContinuationResponse = false
            digits = digits.dropLast()
        } else {
            needsContinuationResponse = true
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let length = Int(digits) else { return nil }
        return (length, needsContinuationResponse)
    }

    /// Replace a trailing `{N[+]}` literal marker with a quoted, escaped
    /// form of its now-known bytes, so the existing quoted-string-based
    /// command handlers (SELECT/SEARCH/etc.) parse the reconstructed line
    /// exactly as they would a client that chose quoted-string encoding.
    private static func splicingLiteral(into lineData: Data, literal: String) -> Data {
        guard let line = String(data: lineData, encoding: .utf8),
              let open = line.lastIndex(of: "{") else { return lineData }
        let prefix = line[line.startIndex..<open]
        let escaped = literal
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data("\(prefix)\"\(escaped)\"".utf8)
    }

    /// Minimal IMAP LIST pattern match (RFC 3501 §6.3.8): `*` matches any run
    /// of characters (including none), `%` likewise (this fake has no
    /// mailbox hierarchy to distinguish them from `*`). Every mailbox name
    /// this test infra uses is a flat identifier with no wildcard
    /// metacharacters of its own, so an exact match is used whenever the
    /// pattern itself has none.
    private static func imapListPatternMatches(pattern: String, name: String) -> Bool {
        guard !pattern.isEmpty, pattern != "*" else { return true }
        guard pattern.contains("*") || pattern.contains("%") else { return pattern == name }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\%", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private func handleFetch(tag: String, args: String, uidMode: Bool, mailbox: String) -> String {
        let seqStr: String
        let itemsStr: String

        if let parenOpen = args.firstIndex(of: "("),
           let parenClose = args.lastIndex(of: ")") {
            seqStr = String(args[args.startIndex..<parenOpen]).trimmingCharacters(in: .whitespaces)
            itemsStr = String(args[args.index(after: parenOpen)..<parenClose]).uppercased()
        } else {
            let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
            guard fetchParts.count == 2 else { return "\(tag) BAD Invalid FETCH arguments\r\n" }
            seqStr = fetchParts[0]
            itemsStr = fetchParts[1].uppercased()
        }

        let snapshot = withState { state in
            (
                messages: state.messagesByMailbox[mailbox] ?? [],
                flags: state.flagsByMailbox[mailbox] ?? [:]
            )
        }
        let matched = parseSequenceSet(seqStr, uidMode: uidMode, messages: snapshot.messages)
        var response = ""

        for msg in matched {
            let seqnum = (snapshot.messages.firstIndex(where: { $0.uid == msg.uid }) ?? 0) + 1
            var fetchItems: [String] = []

            if itemsStr.contains("UID") || uidMode {
                fetchItems.append("UID \(msg.uid)")
            }
            if itemsStr.contains("FLAGS") {
                let flags = (snapshot.flags[msg.uid] ?? []).sorted().joined(separator: " ")
                fetchItems.append("FLAGS (\(flags))")
            }
            if itemsStr.contains("ENVELOPE") {
                fetchItems.append("ENVELOPE \(buildEnvelope(msg))")
            }
            if itemsStr.contains("INTERNALDATE") {
                fetchItems.append("INTERNALDATE \"\(msg.internalDate)\"")
            }
            if itemsStr.contains("RFC822.SIZE") {
                fetchItems.append("RFC822.SIZE \(msg.raw.count)")
            }
            if itemsStr.contains("BODYSTRUCTURE") {
                let bs = msg.customBodystructure ?? buildBodystructure(msg)
                fetchItems.append("BODYSTRUCTURE \(bs)")
            }
            if itemsStr.contains("BODY[]") || itemsStr.contains("BODY.PEEK[]") {
                let rawStr = String(data: msg.raw, encoding: .utf8) ?? ""
                fetchItems.append("BODY[] {\(msg.raw.count)}\r\n\(rawStr)")
            }
            if itemsStr.contains("BODY[HEADER]") || itemsStr.contains("BODY.PEEK[HEADER]") {
                let headerStr = String(data: msg.headerData, encoding: .utf8) ?? ""
                fetchItems.append("BODY[HEADER] {\(msg.headerData.count)}\r\n\(headerStr)")
            }
            if itemsStr.contains("BODY[TEXT]") || itemsStr.contains("BODY.PEEK[TEXT]") {
                let bodyStr = String(data: msg.body, encoding: .utf8) ?? ""
                fetchItems.append("BODY[TEXT] {\(msg.body.count)}\r\n\(bodyStr)")
            }
            // BODY[N] / BODY.PEEK[N] / BODY[N.M] — numeric section specifier.
            // Match sections registered in partBodies; emit literal-length bytes.
            if let sections = msg.partBodies {
                for (section, bytes) in sections {
                    // RFC 3501 §7.4.2: BODY[section] response echoes the section.
                    // Both peek and non-peek forms get the same BODY[<s>] key on
                    // the response side.
                    let patterns = [
                        "BODY[\(section)]",
                        "BODY.PEEK[\(section)]"
                    ]
                    if patterns.contains(where: { itemsStr.contains($0) }) {
                        let str = String(data: bytes, encoding: .utf8) ?? ""
                        fetchItems.append("BODY[\(section)] {\(bytes.count)}\r\n\(str)")
                    }
                }
            }

            response += "* \(seqnum) FETCH (\(fetchItems.joined(separator: " ")))\r\n"
        }

        response += "\(tag) OK \(uidMode ? "UID " : "")FETCH completed\r\n"
        return response
    }

    private func parseSequenceSet(_ seqStr: String, uidMode: Bool, messages: [Message]) -> [Message] {
        var results: [Message] = []
        for part in seqStr.split(separator: ",").map(String.init) {
            if part.contains(":") {
                let range = part.split(separator: ":").map(String.init)
                let start = Int(range[0]) ?? 1
                let end: Int
                if range.count > 1, range[1] != "*" {
                    end = Int(range[1]) ?? messages.count
                } else {
                    end = uidMode ? (messages.last?.uid ?? 0) : messages.count
                }
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val >= start && val <= end { results.append(msg) }
                }
            } else if part == "*" {
                if let last = messages.last { results.append(last) }
            } else if let num = Int(part) {
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val == num { results.append(msg) }
                }
            }
        }
        return results
    }

    // MARK: - Response Builders

    private func buildEnvelope(_ msg: Message) -> String {
        let date = quote(msg.date)
        let subject = quote(msg.subject)
        let fromAddr = buildAddrList(msg.from)
        let toAddr = buildAddrList(msg.to)
        let msgID = quote(msg.messageID)
        return "(\(date) \(subject) \(fromAddr) \(fromAddr) \(fromAddr) \(toAddr) NIL NIL NIL \(msgID))"
    }

    private func buildAddrList(_ header: String) -> String {
        guard !header.isEmpty else { return "NIL" }
        let name: String
        let email: String
        if let angleOpen = header.firstIndex(of: "<"),
           let angleClose = header.firstIndex(of: ">") {
            name = String(header[header.startIndex..<angleOpen]).trimmingCharacters(in: .whitespaces)
            email = String(header[header.index(after: angleOpen)..<angleClose])
        } else {
            name = ""
            email = header.trimmingCharacters(in: .whitespaces)
        }
        guard email.contains("@") else { return "NIL" }
        let parts = email.split(separator: "@")
        let local = String(parts[0])
        let domain = String(parts[1])
        let nameQ = name.isEmpty ? "NIL" : quote(name)
        return "((\(nameQ) NIL \(quote(local)) \(quote(domain))))"
    }

    private func buildBodystructure(_ msg: Message) -> String {
        let ct = msg.contentType
        let parts = ct.split(separator: "/")
        let maintype = parts.first.map(String.init)?.uppercased() ?? "TEXT"
        let subtype = parts.count > 1 ? String(parts[1]).uppercased() : "PLAIN"
        let charset = msg.charset.uppercased()
        let size = msg.body.count
        let lines = msg.body.filter { $0 == UInt8(ascii: "\n") }.count
        return "(\"\(maintype)\" \"\(subtype)\" (\"CHARSET\" \"\(charset)\") NIL NIL \"7BIT\" \(size) \(lines))"
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
