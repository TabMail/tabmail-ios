/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CoreGraphics
import Foundation

/// Measures how much text a page draws before `PDFPage.string` is asked for it. PDFKit builds the
/// page's whole selection layout first, at about 430 bytes per character with no limit: a 31 KB
/// PDF drawing 3.6M characters on one page took it to 1.5 GB. This pass uses CoreGraphics'
/// streaming content scanner, decodes no fonts, keeps no text and stops at the cap (the same page
/// stays under 10 MB), so only pages PDFKit can afford reach it.
///
/// It adds up the bytes of every string a text-showing operator draws, including in nested forms.
/// A character is one or two bytes, so the count is an upper bound on the characters. Every
/// invocation of a form counts, as PDFKit lays out every one (a real page drew forms 89,744
/// times); the deadline bounds the work. A page nesting forms deeper than the counter follows is
/// over budget.
///
/// It also checks every font the page selects (`Tf`, or an `ExtGState` font). To lay out text,
/// CoreGraphics decodes each stream a selected font reaches whole, whatever its filter: the
/// `/ToUnicode` map, the font program, an `/Encoding` CMap, a `/CIDToGIDMap`, the resources of a
/// Type 3 font. `PDFStreamBudget` counts only the filters it can decode, so a 5 KB CCITT
/// `/ToUnicode` map decoding to 40 MB took `PDFPage.string` to 212 MB. No font needs an image
/// codec, so a font reaching a stream the budget does not count is over budget. An image a
/// Type 3 glyph draws is not decoded to read text (measured), so it is not followed.
final class PDFPageGlyphCounter {

    enum Verdict: Equatable {
        case withinBudget
        case overBudget
        case timedOut
    }

    enum Bounds {
        static let maxFormDepth = 4
        /// How deep the objects a font reaches are followed; a deeper font is over budget.
        static let maxFontDepth = 16
        /// How many operator callbacks pass between deadline checks.
        static let deadlineCheckInterval = 256
    }

    static func check(_ page: CGPDFPage, maxBytes: Int, deadline: ContinuousClock.Instant) -> Verdict {
        if ContinuousClock.now >= deadline || Task.isCancelled { return .timedOut }
        let counter = PDFPageGlyphCounter(maxBytes: maxBytes, deadline: deadline)
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        _ = counter.run(content)
        if counter.timedOut { return .timedOut }
        return counter.bytes > maxBytes || counter.formsTooDeep || counter.uncountedFont ? .overBudget : .withinBudget
    }

    private let maxBytes: Int
    private let deadline: ContinuousClock.Instant
    private var bytes = 0
    private var timedOut = false
    private var callbacksSinceCheck = 0
    private var formDepth = 0
    /// Set when a form is nested deeper than `Bounds.maxFormDepth`; its text is then not counted.
    private var formsTooDeep = false
    /// Set when a selected font reaches a stream `PDFStreamBudget` does not count.
    private var uncountedFont = false
    /// The dictionaries already followed, each in the role it was followed in, as an image is
    /// skipped in one role and not in another.
    private var checked: Set<Checked> = []

    private init(maxBytes: Int, deadline: ContinuousClock.Instant) {
        self.maxBytes = maxBytes
        self.deadline = deadline
    }

    /// Scans one content stream (the page, or a form it draws).
    private func run(_ content: CGPDFContentStreamRef) -> Bool {
        guard let table = Self.operatorTable else { return false }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        return CGPDFScannerScan(scanner)
    }

    /// The shared callbacks. Every callback first passes through `enter`, which stops the scanner
    /// once the cap or the deadline has passed. Built once and only read by CoreGraphics afterwards.
    nonisolated(unsafe) private static let operatorTable: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        let showString: CGPDFOperatorCallback = { scanner, info in
            guard let counter = enter(scanner, info) else { return }
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { counter.add(CGPDFStringGetLength(string), scanner) }
        }
        for name in ["Tj", "'", "\""] { CGPDFOperatorTableSetCallback(table, name, showString) }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let counter = enter(scanner, info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &string), let string { counter.add(CGPDFStringGetLength(string), scanner) }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let counter = enter(scanner, info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            counter.drawForm(named: name, from: CGPDFScannerGetContentStream(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let counter = enter(scanner, info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name,
                  let font = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name) else { return }
            counter.checkFont(font, scanner)
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let counter = enter(scanner, info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name) else { return }
            var state: CGPDFDictionaryRef?
            var font: CGPDFArrayRef?
            var fontObject: CGPDFObjectRef?
            guard CGPDFObjectGetValue(object, .dictionary, &state), let state,
                  CGPDFDictionaryGetArray(state, "Font", &font), let font,
                  CGPDFArrayGetObject(font, 0, &fontObject), let fontObject else { return }
            counter.checkFont(fontObject, scanner)
        }
        // Common operators that draw no text are registered only so a page made of millions of
        // them still reaches the deadline check.
        for name in ["q", "Q", "cm", "m", "l", "c", "re", "h", "f", "F", "f*", "S", "s", "n", "W", "BT", "ET", "Td", "TD", "Tm", "T*"] {
            CGPDFOperatorTableSetCallback(table, name) { scanner, info in _ = enter(scanner, info) }
        }
        return table
    }()

    private static func enter(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) -> PDFPageGlyphCounter? {
        guard let info else { return nil }
        let counter = Unmanaged<PDFPageGlyphCounter>.fromOpaque(info).takeUnretainedValue()
        if !counter.timedOut, !counter.formsTooDeep, !counter.uncountedFont, counter.bytes <= counter.maxBytes {
            counter.tick()
        }
        if counter.timedOut || counter.formsTooDeep || counter.uncountedFont || counter.bytes > counter.maxBytes {
            CGPDFScannerStop(scanner)
            return nil
        }
        return counter
    }

    /// Counts one unit of work and checks the deadline every `Bounds.deadlineCheckInterval` units.
    private func tick() {
        callbacksSinceCheck += 1
        if callbacksSinceCheck >= Bounds.deadlineCheckInterval {
            callbacksSinceCheck = 0
            if ContinuousClock.now >= deadline || Task.isCancelled { timedOut = true }
        }
    }

    private func checkFont(_ font: CGPDFObjectRef, _ scanner: CGPDFScannerRef) {
        if !reachesOnlyCountedStreams(font, depth: 0, role: .other) {
            if !timedOut { uncountedFont = true }
            CGPDFScannerStop(scanner)
        }
    }

    /// Where an object sits: images are skipped only as the entries of an `/XObject` dictionary.
    private enum Role {
        case other
        case xObjects
        case xObject
    }

    private struct Checked: Hashable {
        let dictionary: CGPDFDictionaryRef
        let role: Role
    }

    /// Whether every stream `object` reaches has filters `PDFStreamBudget` counts. Each dictionary
    /// is followed once per role; past `Bounds.maxFontDepth`, or the deadline, the answer is no.
    private func reachesOnlyCountedStreams(_ object: CGPDFObjectRef, depth: Int, role: Role) -> Bool {
        tick()
        guard !timedOut, depth <= Bounds.maxFontDepth else { return false }
        var dictionary: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .stream, &stream), let stream {
            guard let streamDictionary = CGPDFStreamGetDictionary(stream) else { return false }
            var subtype: UnsafePointer<CChar>?
            if role == .xObject, CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype,
               strcmp(subtype, "Image") == 0 { return true }
            guard let filters = Self.filters(of: streamDictionary), PDFStreamBudget.counts(filters: filters) else { return false }
            dictionary = streamDictionary
        } else if CGPDFObjectGetValue(object, .array, &array), let array {
            for index in 0..<CGPDFArrayGetCount(array) {
                var element: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, index, &element), let element else { continue }
                if !reachesOnlyCountedStreams(element, depth: depth + 1, role: .other) { return false }
            }
            return true
        } else if !CGPDFObjectGetValue(object, .dictionary, &dictionary) {
            return true
        }
        guard let dictionary, checked.insert(Checked(dictionary: dictionary, role: role)).inserted else { return true }
        var counted = true
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            let child: Role = strcmp(key, "XObject") == 0 ? .xObjects : role == .xObjects ? .xObject : .other
            counted = self.reachesOnlyCountedStreams(value, depth: depth + 1, role: child)
            return counted
        }, nil)
        return counted
    }

    /// A stream's filter names, or nil when `/Filter` is neither a name nor an array of names.
    private static func filters(of dictionary: CGPDFDictionaryRef) -> [String]? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name { return [String(cString: name)] }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array {
            var names: [String] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                guard CGPDFArrayGetName(array, index, &name), let name else { return nil }
                names.append(String(cString: name))
            }
            return names
        }
        var other: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, "Filter", &other) ? nil : []
    }

    private func add(_ length: Int, _ scanner: CGPDFScannerRef) {
        bytes += length
        if bytes > maxBytes { CGPDFScannerStop(scanner) }
    }

    private func drawForm(named name: UnsafePointer<CChar>, from content: CGPDFContentStreamRef) {
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
              strcmp(subtype, "Form") == 0 else { return }
        guard formDepth < Bounds.maxFormDepth else {
            formsTooDeep = true
            return
        }
        var resources: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources) { resources = nil }
        formDepth += 1
        defer { formDepth -= 1 }
        let formContent = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        defer { CGPDFContentStreamRelease(formContent) }
        _ = run(formContent)
    }
}
