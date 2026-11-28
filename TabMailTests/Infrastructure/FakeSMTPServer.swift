/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A minimal SMTP server on a loopback ephemeral port that speaks plain TCP
/// only and records every line a client sends.
///
/// By default it offers no STARTTLS, and it advertises `AUTH PLAIN` and answers
/// a whole submission, so a client willing to send without encryption goes all
/// the way through: its AUTH line and message are recorded here. Given a
/// `StartTLSAnswer` it offers STARTTLS but never completes a TLS handshake.
///
/// Socket ownership follows `FakeIMAPServer`: only a connection's own thread
/// closes its descriptor; `stop()` shuts the sockets down, so a descriptor
/// number is never closed twice.
final class FakeSMTPServer: @unchecked Sendable {
    enum ServerError: Error { case setup(String) }

    /// How the server answers STARTTLS when it offers it.
    enum StartTLSAnswer {
        /// Refuse the upgrade with this reply line (CRLF appended).
        case refuse(String)
        /// Never answer, but keep the connection open and keep reading.
        case silence
        /// Accept with 220, wait for the client's first TLS bytes, answer them
        /// with these raw bytes instead of a handshake, then close once the
        /// client has.
        case acceptThenAnswerHandshake([UInt8])
    }

    /// A fatal TLS alert record (type 21, version 3.1, length 2, level fatal,
    /// description protocol_version): what a server that cannot speak the
    /// client's minimum TLS version answers its ClientHello with.
    static let protocolVersionAlert: [UInt8] = [0x15, 0x03, 0x01, 0x00, 0x02, 0x02, 0x46]

    private(set) var port: Int = 0

    private let startTLSAnswer: StartTLSAnswer?
    private let startTLSKeyword: String

    /// `startTLSKeyword` is the EHLO line that offers STARTTLS, as the server
    /// spells it; it is advertised only with a `startTLSAnswer`.
    init(startTLSAnswer: StartTLSAnswer? = nil, startTLSKeyword: String = "STARTTLS") {
        self.startTLSAnswer = startTLSAnswer
        self.startTLSKeyword = startTLSKeyword
    }

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFds: [Int32] = []
    private var lines: [String] = []
    private var upgradeBytes: [[UInt8]] = []
    private let queue = DispatchQueue(label: "FakeSMTPServer")

    /// Every line received, in order, without its CRLF.
    func receivedLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// For each connection whose STARTTLS was accepted, every byte the client
    /// sent after the STARTTLS line, including bytes it sent before the 220.
    func bytesAfterSTARTTLS() -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return upgradeBytes
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.setup("socket() failed: \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            close(fd)
            throw ServerError.setup("bind/listen failed: \(errno)")
        }
        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: boundAddr.sin_port))
        listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        lock.lock()
        for fd in clientFds { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    private func acceptClient() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        // A late reply written after `stop()` shut the socket down fails with
        // EPIPE instead of raising SIGPIPE in the test host.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        clientFds.append(fd)
        lock.unlock()
        // Strong: only `serve` closes a connection's descriptor (`stop()` shuts
        // it down), so it must run even if the server is released first.
        DispatchQueue.global().async { self.serve(fd) }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            clientFds.removeAll { $0 == fd }
            lock.unlock()
            close(fd)
        }
        reply(fd, "220 smtp.example.com ESMTP\r\n")
        var buffer = Data()
        var inData = false
        while let line = readLine(fd, &buffer) {
            lock.lock()
            lines.append(line)
            lock.unlock()
            if inData {
                if line == "." {
                    inData = false
                    reply(fd, "250 2.0.0 Queued\r\n")
                }
                continue
            }
            switch line.split(separator: " ").first.map({ $0.uppercased() }) ?? "" {
            case "EHLO":
                let offer = startTLSAnswer == nil ? "" : "250-\(startTLSKeyword)\r\n"
                reply(fd, "250-smtp.example.com\r\n\(offer)250-AUTH PLAIN\r\n250 8BITMIME\r\n")
            case "STARTTLS" where startTLSAnswer != nil:
                if !answerStartTLS(fd, pending: buffer) { return }
            case "AUTH": reply(fd, "235 2.7.0 Accepted\r\n")
            case "DATA":
                inData = true
                reply(fd, "354 End data with <CR><LF>.<CR><LF>\r\n")
            case "QUIT":
                reply(fd, "221 2.0.0 Bye\r\n")
                return
            default: reply(fd, "250 2.0.0 OK\r\n")
            }
        }
    }

    /// Answers STARTTLS; false when the connection is over. `pending` is what
    /// the client sent after the STARTTLS line and was already read.
    private func answerStartTLS(_ fd: Int32, pending: Data) -> Bool {
        switch startTLSAnswer {
        case .refuse(let line)?:
            reply(fd, line + "\r\n")
            return true
        case .silence?:
            return true
        case .acceptThenAnswerHandshake(let bytes)?:
            reply(fd, "220 2.0.0 Ready to start TLS\r\n")
            var received = [UInt8](pending)
            var chunk = [UInt8](repeating: 0, count: 4096)
            defer {
                lock.lock()
                upgradeBytes.append(received)
                lock.unlock()
            }
            // The client's first TLS bytes, then the scripted answer.
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return false }
            received += chunk[0..<count]
            _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            // Half-close and wait for the client to hang up, so unread client
            // bytes never turn the close into a reset that could discard the
            // answer before the client reads it.
            _ = shutdown(fd, SHUT_WR)
            while true {
                let more = recv(fd, &chunk, chunk.count, 0)
                guard more > 0 else { break }
                received += chunk[0..<more]
            }
            return false
        case nil:
            return true
        }
    }

    private func reply(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// The next CRLF-terminated line, or nil at end of stream.
    private func readLine(_ fd: Int32, _ buffer: inout Data) -> String? {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
