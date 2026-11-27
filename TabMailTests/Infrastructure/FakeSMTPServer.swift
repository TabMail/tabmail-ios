/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A minimal SMTP server on a loopback ephemeral port that speaks plain TCP
/// only and records every line a client sends.
///
/// It never offers STARTTLS (it could not upgrade), and it advertises
/// `AUTH PLAIN` and answers a whole submission, so a client willing to send
/// without encryption goes all the way through: its AUTH line and message are
/// recorded here.
///
/// Socket ownership follows `FakeIMAPServer`: only a connection's own thread
/// closes its descriptor; `stop()` shuts the sockets down, so a descriptor
/// number is never closed twice.
final class FakeSMTPServer: @unchecked Sendable {
    enum ServerError: Error { case setup(String) }

    private(set) var port: Int = 0

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFds: [Int32] = []
    private var lines: [String] = []
    private let queue = DispatchQueue(label: "FakeSMTPServer")

    /// Every line received, in order, without its CRLF.
    func receivedLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
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
        lock.lock()
        clientFds.append(fd)
        lock.unlock()
        DispatchQueue.global().async { [weak self] in self?.serve(fd) }
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
            case "EHLO": reply(fd, "250-smtp.example.com\r\n250-AUTH PLAIN\r\n250 8BITMIME\r\n")
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
