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
final class PDFPageGlyphCounter {

    enum Verdict: Equatable {
        case withinBudget
        case overBudget
        case timedOut
    }

    enum Bounds {
        static let maxFormDepth = 4
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
        return counter.bytes > maxBytes || counter.formsTooDeep ? .overBudget : .withinBudget
    }

    private let maxBytes: Int
    private let deadline: ContinuousClock.Instant
    private var bytes = 0
    private var timedOut = false
    private var callbacksSinceCheck = 0
    private var formDepth = 0
    /// Set when a form is nested deeper than `Bounds.maxFormDepth`; its text is then not counted.
    private var formsTooDeep = false

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
        // Common operators that draw no text are registered only so a page made of millions of
        // them still reaches the deadline check.
        for name in ["q", "Q", "cm", "m", "l", "c", "re", "h", "f", "F", "f*", "S", "s", "n", "W", "BT", "ET", "Td", "TD", "Tm", "T*", "Tf", "gs"] {
            CGPDFOperatorTableSetCallback(table, name) { scanner, info in _ = enter(scanner, info) }
        }
        return table
    }()

    private static func enter(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) -> PDFPageGlyphCounter? {
        guard let info else { return nil }
        let counter = Unmanaged<PDFPageGlyphCounter>.fromOpaque(info).takeUnretainedValue()
        if !counter.timedOut, !counter.formsTooDeep, counter.bytes <= counter.maxBytes {
            counter.callbacksSinceCheck += 1
            if counter.callbacksSinceCheck >= Bounds.deadlineCheckInterval {
                counter.callbacksSinceCheck = 0
                if ContinuousClock.now >= counter.deadline || Task.isCancelled { counter.timedOut = true }
            }
        }
        if counter.timedOut || counter.formsTooDeep || counter.bytes > counter.maxBytes {
            CGPDFScannerStop(scanner)
            return nil
        }
        return counter
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
