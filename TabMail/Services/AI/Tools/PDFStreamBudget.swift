/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Compression
import Foundation

/// Refuses a PDF whose streams would decompress past a budget, before PDFKit or CoreGraphics opens
/// it. CoreGraphics inflates a stream such as a font's `ToUnicode` map whole, with no output cap,
/// ignores a false `/Length`, and keeps the result: a 1 MB file whose map inflates to 1 GB took
/// `PDFPage.string` to 2.7 GB, and ten 70 MB maps on one page to 1.6 GB. Libraries that own their
/// decoder cap it (pypdf: 75 MB per stream); Apple's API has no such setting, so the cap runs here.
///
/// Every stream is a top-level indirect object (never inside an object stream), so the raw bytes
/// show each one with its dictionary. Expanding filters (Flate, LZW, RunLength)
/// are decoded counting bytes only. A stream that is encrypted cannot be checked, because its
/// bytes are ciphertext: they fail to inflate and count as nothing.
enum PDFStreamBudget {

    enum Verdict: Equatable {
        case withinBudget
        case overBudget
        case timedOut
    }

    struct Caps {
        /// Decoded bytes allowed for any one stream.
        let streamBytes: Int
        /// Decoded bytes allowed for all streams together.
        let totalBytes: Int
    }

    static func check(_ data: Data, caps: Caps, deadline: ContinuousClock.Instant) -> Verdict {
        data.withUnsafeBytes { raw in
            var walker = Walker(bytes: raw.bindMemory(to: UInt8.self), caps: caps, deadline: deadline)
            return walker.run()
        }
    }

    /// How a stream's filter chain is checked.
    enum Plan: Equatable {
        /// Undo `textLayers` (ASCII encodings, decoded in full), then count `expander`'s output;
        /// with no expander, the text layers' output is the count.
        case count(textLayers: [TextFilter], expander: Expander?)
        /// A chain this check cannot follow: two expanding filters, an expanding filter behind a
        /// filter other than an ASCII encoding, or a filter given by indirect reference.
        case refuse
    }

    enum Expander: Equatable {
        case flate
        case lzw
        case runLength
    }

    enum TextFilter: Equatable {
        case hex
        case base85
    }

    static func plan(filters: [String], indirect: Bool) -> Plan {
        if indirect { return .refuse }
        var textLayers: [TextFilter] = []
        var expander: Expander?
        var blocked = false
        for name in filters {
            if let found = Self.expander(named: name) {
                if expander != nil || blocked { return .refuse }
                expander = found
            } else if expander == nil, !blocked, let text = textFilter(named: name) {
                textLayers.append(text)
            } else if expander == nil {
                // An image codec or similar, which nothing after can be counted behind. CoreGraphics
                // decodes it to read text only for a stream a font reaches, and
                // `PDFPageGlyphCounter` refuses a font reaching a stream `counts` rejects.
                blocked = true
            }
        }
        return .count(textLayers: textLayers, expander: expander)
    }

    /// Whether this check counts all that CoreGraphics decodes from a stream with these filters.
    static func counts(filters: [String]) -> Bool {
        filters.allSatisfy { expander(named: $0) != nil || textFilter(named: $0) != nil }
            && plan(filters: filters, indirect: false) != .refuse
    }

    private static func expander(named name: String) -> Expander? {
        switch name {
        case "FlateDecode", "Fl": return .flate
        case "LZWDecode", "LZW": return .lzw
        case "RunLengthDecode", "RL": return .runLength
        default: return nil
        }
    }

    private static func textFilter(named name: String) -> TextFilter? {
        switch name {
        case "ASCIIHexDecode", "AHx": return .hex
        case "ASCII85Decode", "A85": return .base85
        default: return nil
        }
    }

    /// Decoded size of the stream whose data starts `rest`, or nil past `cap` (or the deadline).
    static func decodedSize(
        _ rest: UnsafeBufferPointer<UInt8>, textLayers: [TextFilter], expander: Expander?,
        cap: Int, deadline: ContinuousClock.Instant
    ) -> Int? {
        var layer: [UInt8]?
        for text in textLayers {
            let decoded: [UInt8]?
            if let layer {
                decoded = layer.withUnsafeBufferPointer { text == .hex ? Counting.hex($0, cap: cap) : Counting.base85($0, cap: cap) }
            } else {
                decoded = text == .hex ? Counting.hex(rest, cap: cap) : Counting.base85(rest, cap: cap)
            }
            guard let decoded else { return nil }
            layer = decoded
        }
        guard let expander else { return layer?.count ?? 0 }
        let count = { (input: UnsafeBufferPointer<UInt8>) -> Int? in
            switch expander {
            case .flate: return Counting.inflated(input, cap: cap, deadline: deadline)
            case .lzw: return Counting.lzw(input, cap: cap)
            case .runLength: return Counting.runLength(input, cap: cap)
            }
        }
        if let layer { return layer.withUnsafeBufferPointer(count) }
        return count(rest)
    }

    // MARK: - Walking the file

    /// Finds every `N G obj`, reads the object's dictionary up to the next object header, and
    /// counts the stream that follows it. Lexing each object on its own keeps the walk linear; a
    /// dictionary that runs into the next header (an unclosed string, or a header inside a string or
    /// comment) is refused, because the walk cannot tell which object the bytes after it belong to.
    /// Each decoder is given the rest of the file and stops where its own data ends, as CoreGraphics
    /// does, so a stream's extent never depends on `/Length` or on finding `endstream`.
    ///
    /// A final sweep refuses the file when a `stream` keyword CoreGraphics would read belongs to no
    /// object the walk counted, such as one whose header CoreGraphics finds and this walk does not.
    private struct Walker {
        let bytes: UnsafeBufferPointer<UInt8>
        let caps: Caps
        let deadline: ContinuousClock.Instant

        mutating func run() -> Verdict {
            let headers = objectHeaders()
            var counted = Set<Int>()
            var total = 0
            for (offset, header) in headers.enumerated() {
                if ContinuousClock.now >= deadline || Task.isCancelled { return .timedOut }
                let limit = offset + 1 < headers.count ? headers[offset + 1].start : bytes.count
                var lexer = Lexer(bytes: bytes, index: header.bodyStart, limit: limit)
                let stream: Lexer.Stream
                switch lexer.streamAfterDictionary() {
                case .none: continue
                case .runsIntoNextObject: return .overBudget
                case .stream(let found): stream = found
                }
                counted.insert(stream.keyword)
                let rest = UnsafeBufferPointer(rebasing: bytes[stream.dataStart...])
                let cap = min(caps.streamBytes, caps.totalBytes - total)
                let decoded: Int?
                switch PDFStreamBudget.plan(filters: stream.filters, indirect: stream.indirect) {
                case .refuse: return .overBudget
                case .count(let textLayers, let expander):
                    if textLayers.isEmpty, expander == nil { continue }
                    decoded = PDFStreamBudget.decodedSize(rest, textLayers: textLayers, expander: expander, cap: cap, deadline: deadline)
                }
                guard let decoded else {
                    return ContinuousClock.now >= deadline || Task.isCancelled ? .timedOut : .overBudget
                }
                total += decoded
            }
            return sweepForUncountedStreams(counted)
        }

        /// One pass over the file for `stream` keywords CoreGraphics would read: the token
        /// `stream` after a dictionary's `>>`, with only whitespace or comments between. Whether a
        /// `%` starts a comment depends on string context this pass does not track, so a keyword
        /// whose line before it holds a `%` is taken as possibly following `>>`.
        private func sweepForUncountedStreams(_ counted: Set<Int>) -> Verdict {
            let keyword = Array("stream".utf8)
            var lineStart = 0
            var lastPercent = -1
            var lastToken = -1
            var lastTokenAfterPercent = false
            var index = 0
            while index < bytes.count {
                if index & 0xFFFFF == 0, ContinuousClock.now >= deadline || Task.isCancelled { return .timedOut }
                let byte = bytes[index]
                if byte == 0x0A || byte == 0x0D {
                    lineStart = index + 1
                } else if byte == UInt8(ascii: "%") {
                    lastPercent = index
                } else if byte == keyword[0], index + keyword.count <= bytes.count,
                          bytes[index..<(index + keyword.count)].elementsEqual(keyword),
                          index == 0 || PDFSyntax.isWhitespace(bytes[index - 1]) || PDFSyntax.isDelimiter(bytes[index - 1]),
                          index + keyword.count == bytes.count || PDFSyntax.isWhitespace(bytes[index + keyword.count])
                            || PDFSyntax.isDelimiter(bytes[index + keyword.count]) {
                    let afterDictionary = lastToken >= 1 && bytes[lastToken] == UInt8(ascii: ">") && bytes[lastToken - 1] == UInt8(ascii: ">")
                    if afterDictionary || lastTokenAfterPercent, !counted.contains(index) { return .overBudget }
                }
                if !PDFSyntax.isWhitespace(byte) {
                    lastToken = index
                    lastTokenAfterPercent = lastPercent >= lineStart
                }
                index += 1
            }
            return .withinBudget
        }

        /// Positions of `<number> <generation> obj` headers: where each starts and where its body begins.
        private func objectHeaders() -> [(start: Int, bodyStart: Int)] {
            guard let base = bytes.baseAddress else { return [] }
            let keyword = Array("obj".utf8)
            var headers: [(start: Int, bodyStart: Int)] = []
            var from = 0
            while from < bytes.count {
                guard let found = keyword.withUnsafeBytes({ k in memmem(base + from, bytes.count - from, k.baseAddress, k.count) }) else { break }
                let at = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - base
                from = at + 3
                if from < bytes.count, !PDFSyntax.isWhitespace(bytes[from]), !PDFSyntax.isDelimiter(bytes[from]) { continue }
                var cursor = at
                guard skipBackward(&cursor, while: PDFSyntax.isWhitespace),
                      skipBackward(&cursor, while: PDFSyntax.isDigit),
                      skipBackward(&cursor, while: PDFSyntax.isWhitespace),
                      skipBackward(&cursor, while: PDFSyntax.isDigit) else { continue }
                if cursor > 0, !PDFSyntax.isWhitespace(bytes[cursor - 1]), !PDFSyntax.isDelimiter(bytes[cursor - 1]) { continue }
                headers.append((cursor, from))
            }
            return headers
        }

        /// Moves `cursor` back over at least one byte matching `test`.
        private func skipBackward(_ cursor: inout Int, while test: (UInt8) -> Bool) -> Bool {
            let start = cursor
            while cursor > 0, test(bytes[cursor - 1]) { cursor -= 1 }
            return cursor < start
        }
    }

    /// Reads one object's dictionary: its `/Filter` (at the top level only, so a key inside a
    /// string or a nested dictionary does not count) and whether `stream` follows it.
    private struct Lexer {
        let bytes: UnsafeBufferPointer<UInt8>
        var index: Int
        let limit: Int

        struct Stream {
            let filters: [String]
            /// The filter, or an entry of its array, is not a name (an indirect reference).
            let indirect: Bool
            /// Where the `stream` keyword starts.
            let keyword: Int
            let dataStart: Int
        }

        enum Parse {
            case stream(Stream)
            /// Not a dictionary followed by `stream`.
            case none
            /// The dictionary is still open at the next object header.
            case runsIntoNextObject
        }

        mutating func streamAfterDictionary() -> Parse {
            skipWhitespaceAndComments()
            guard startsWith("<<") else { return .none }
            index += 2
            var depth = 1
            var filters: [String] = []
            var indirect = false
            var expectingFilter = false
            var inFilterArray = false
            while depth > 0 {
                skipWhitespaceAndComments()
                guard index < limit else { return .runsIntoNextObject }
                let byte = bytes[index]
                if startsWith("<<") {
                    index += 2
                    depth += 1
                    expectingFilter = false
                } else if startsWith(">>") {
                    index += 2
                    depth -= 1
                } else if byte == UInt8(ascii: "<") {
                    while index < limit, bytes[index] != UInt8(ascii: ">") { index += 1 }
                    index += 1
                    expectingFilter = false
                } else if byte == UInt8(ascii: "(") {
                    skipLiteralString()
                    expectingFilter = false
                } else if byte == UInt8(ascii: "[") {
                    index += 1
                    if expectingFilter, depth == 1 { inFilterArray = true; filters = [] }
                    expectingFilter = false
                } else if byte == UInt8(ascii: "]") {
                    index += 1
                    inFilterArray = false
                } else if byte == UInt8(ascii: "/") {
                    index += 1
                    let name = PDFSyntax.decodeName(word())
                    guard depth == 1 else { continue }
                    if inFilterArray {
                        filters.append(name)
                    } else if expectingFilter {
                        filters = [name]
                        expectingFilter = false
                    } else if name == "Filter" {
                        expectingFilter = true
                    }
                } else {
                    let start = index
                    let token = word()
                    if index == start { index += 1 }
                    // A number where the filter, or an entry of its array, belongs starts an
                    // indirect reference, which CoreGraphics follows.
                    if (expectingFilter || inFilterArray), depth == 1, let first = token.first, first.isNumber { indirect = true }
                    expectingFilter = false
                }
            }
            skipWhitespaceAndComments()
            let keyword = index
            guard word() == "stream" else { return .none }
            // CoreGraphics skips whatever else is on the keyword's line; the data starts after
            // its end of line (CR LF, LF or CR).
            while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            if index < bytes.count, bytes[index] == 0x0D { index += 1 }
            if index < bytes.count, bytes[index] == 0x0A, bytes[index - 1] != 0x0A { index += 1 }
            return .stream(Stream(filters: filters, indirect: indirect, keyword: keyword, dataStart: min(index, bytes.count)))
        }

        private func startsWith(_ text: String) -> Bool {
            let pattern = Array(text.utf8)
            guard index + pattern.count <= limit else { return false }
            return bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }

        private mutating func word() -> String {
            let start = index
            while index < limit, !PDFSyntax.isWhitespace(bytes[index]), !PDFSyntax.isDelimiter(bytes[index]) { index += 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        }

        private mutating func skipWhitespaceAndComments() {
            while index < limit {
                if PDFSyntax.isWhitespace(bytes[index]) {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "%") {
                    while index < limit, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                } else {
                    return
                }
            }
        }

        private mutating func skipLiteralString() {
            var nesting = 0
            while index < limit {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\\") {
                    index += 1
                } else if byte == UInt8(ascii: "(") {
                    nesting += 1
                } else if byte == UInt8(ascii: ")") {
                    nesting -= 1
                    if nesting == 0 { return }
                }
            }
        }
    }

    enum PDFSyntax {
        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        static func isDelimiter(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
                 UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
                 UInt8(ascii: "/"), UInt8(ascii: "%"):
                return true
            default:
                return false
            }
        }

        /// Resolves `#xx` escapes, so `/Fl#61teDecode` reads as `FlateDecode` as it does to CoreGraphics.
        static func decodeName(_ raw: String) -> String {
            guard raw.contains("#") else { return raw }
            var out: [UInt8] = []
            let bytes = Array(raw.utf8)
            var index = 0
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "#"), index + 2 < bytes.count,
                   let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    out.append(value)
                    index += 3
                } else {
                    out.append(bytes[index])
                    index += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: - Counting decoders

    /// Decoders that return how many bytes a stream decodes to, keeping none of them. Each returns
    /// nil once the count passes `cap`. Each stops where its data ends (end-of-data, or input that
    /// does not decode), which is also where CoreGraphics stops.
    enum Counting {

        static func inflated(_ body: UnsafeBufferPointer<UInt8>, cap: Int, deadline: ContinuousClock.Instant) -> Int? {
            // PDF Flate data is zlib-wrapped, and CoreGraphics inflates nothing without a valid
            // zlib header, so neither does this. Decoding such bytes as raw DEFLATE would also
            // count garbage: an owner-password PDF's streams are ciphertext.
            guard body.count >= 2, body[0] & 0x0F == 8, (UInt16(body[0]) << 8 | UInt16(body[1])) % 31 == 0,
                  let start = body.baseAddress else { return 0 }
            // Compression's ZLIB decoder reads raw DEFLATE, after the two header bytes.
            let source = start + 2
            let remaining = body.count - 2
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            var stream = compression_stream(dst_ptr: buffer, dst_size: bufferSize, src_ptr: source, src_size: remaining, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return 0 }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = source
            stream.src_size = remaining
            var produced = 0
            var rounds = 0
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let unread = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                produced += bufferSize - stream.dst_size
                if produced > cap { return nil }
                rounds += 1
                if rounds % 64 == 0, ContinuousClock.now >= deadline || Task.isCancelled { return nil }
                // Stop at the end of the data, on an error, or when a call made no progress at all.
                if status != COMPRESSION_STATUS_OK || (stream.dst_size == bufferSize && stream.src_size == unread) {
                    return produced
                }
            }
        }

        /// LZW as PDF uses it (9- to 12-bit codes). `/EarlyChange` lives in `/DecodeParms`, which
        /// this check does not read, so both settings are counted and the larger result is used.
        static func lzw(_ body: UnsafeBufferPointer<UInt8>, cap: Int) -> Int? {
            guard let early = lzw(body, cap: cap, earlyChange: 1), let late = lzw(body, cap: cap, earlyChange: 0) else { return nil }
            return max(early, late)
        }

        private static func lzw(_ body: UnsafeBufferPointer<UInt8>, cap: Int, earlyChange: Int) -> Int? {
            var lengths = [Int](repeating: 1, count: 4096)
            var next = 258
            var width = 9
            var previous: Int?
            var produced = 0
            var bitBuffer = 0
            var bitCount = 0
            for byte in body {
                bitBuffer = bitBuffer << 8 | Int(byte)
                bitCount += 8
                while bitCount >= width {
                    let code = (bitBuffer >> (bitCount - width)) & ((1 << width) - 1)
                    bitCount -= width
                    bitBuffer &= (1 << bitCount) - 1
                    if code == 256 {
                        next = 258
                        width = 9
                        previous = nil
                        continue
                    }
                    if code == 257 { return produced }
                    let length: Int
                    if code < 256 {
                        length = 1
                    } else if code < next {
                        length = lengths[code]
                    } else if code == next, let previous {
                        length = lengths[previous] + 1
                    } else {
                        return produced
                    }
                    produced += length
                    if produced > cap { return nil }
                    if let previous, next < 4096 {
                        lengths[next] = lengths[previous] + 1
                        next += 1
                    }
                    previous = code
                    if next + earlyChange >= 1 << width, width < 12 { width += 1 }
                }
            }
            return produced
        }

        /// ASCIIHexDecode output (it is needed as the next filter's input), up to its `>`.
        static func hex(_ body: UnsafeBufferPointer<UInt8>, cap: Int) -> [UInt8]? {
            var out: [UInt8] = []
            var high: UInt8?
            for byte in body {
                if byte == UInt8(ascii: ">") { break }
                if PDFSyntax.isWhitespace(byte) { continue }
                guard let nibble = hexValue(byte) else { break }
                if let h = high { out.append(h << 4 | nibble); high = nil } else { high = nibble }
                if out.count > cap { return nil }
            }
            if let high { out.append(high << 4) }
            return out.count > cap ? nil : out
        }

        /// ASCII85Decode output, up to its `~>`. A `z` stands for four zero bytes, so the output
        /// can be up to four times the input.
        static func base85(_ body: UnsafeBufferPointer<UInt8>, cap: Int) -> [UInt8]? {
            var out: [UInt8] = []
            var group: [UInt32] = []
            func flush(_ digits: [UInt32]) {
                var padded = digits
                while padded.count < 5 { padded.append(84) }
                let value = padded.reduce(UInt32(0)) { $0 &* 85 &+ $1 }
                let bytes = [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
                out.append(contentsOf: bytes.prefix(digits.count - 1))
            }
            for byte in body {
                if byte == UInt8(ascii: "~") { break }
                if PDFSyntax.isWhitespace(byte) { continue }
                if byte == UInt8(ascii: "z"), group.isEmpty {
                    out.append(contentsOf: [0, 0, 0, 0])
                } else if byte >= UInt8(ascii: "!"), byte <= UInt8(ascii: "u") {
                    group.append(UInt32(byte - UInt8(ascii: "!")))
                    if group.count == 5 { flush(group); group.removeAll(keepingCapacity: true) }
                } else {
                    break
                }
                if out.count > cap { return nil }
            }
            if group.count > 1 { flush(group) }
            return out.count > cap ? nil : out
        }

        private static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        static func runLength(_ body: UnsafeBufferPointer<UInt8>, cap: Int) -> Int? {
            var produced = 0
            var index = 0
            while index < body.count {
                let length = Int(body[index])
                if length == 128 { break }
                if length < 128 {
                    produced += length + 1
                    index += length + 2
                } else {
                    produced += 257 - length
                    index += 2
                }
                if produced > cap { return nil }
            }
            return produced
        }
    }
}
