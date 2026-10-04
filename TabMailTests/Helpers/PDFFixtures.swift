/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

/// Builds PDFs in memory for the PDF-reading tests, so no real document is ever committed.
enum PDFFixtures {

    enum Page {
        /// Text drawn with a real font, so its text can be extracted.
        case text(String)
        /// A page with nothing on it.
        case empty
        /// A page that only carries a bitmap, like a scan.
        case image
    }

    static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    static func make(_ pages: [Page], userPassword: String? = nil, ownerPassword: String? = nil, title: String? = nil) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [:]
        if let userPassword { info[kCGPDFContextUserPassword as String] = userPassword }
        if let ownerPassword { info[kCGPDFContextOwnerPassword as String] = ownerPassword }
        if let title { info[kCGPDFContextTitle as String] = title }
        format.documentInfo = info

        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        return renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                switch page {
                case .text(let text):
                    (text as NSString).draw(
                        in: pageBounds.insetBy(dx: 36, dy: 36),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                case .empty:
                    break
                case .image:
                    scanImage.draw(in: CGRect(x: 72, y: 72, width: 300, height: 300))
                }
            }
        }
    }

    // MARK: - Raw objects

    /// Bytes as a PDF FlateDecode filter stores them: zlib-wrapped DEFLATE (the Adler-32
    /// trailer is left off; readers do not need it).
    static func flate(_ data: Data) -> Data {
        let deflated = (try? (data as NSData).compressed(using: .zlib)) as Data? ?? Data()
        return Data([0x78, 0x9C]) + deflated
    }

    /// Zero bytes, compressed: `count` bytes once inflated.
    static func flateZeros(_ count: Int) -> Data {
        flate(Data(count: count))
    }

    /// One `N 0 obj` with a dictionary and stream data, written as given so tests can lie in
    /// the dictionary or the data.
    static func streamObject(_ number: Int, dictionary: String, data: Data) -> Data {
        Data("\(number) 0 obj\n\(dictionary)\nstream\n".utf8) + data + Data("\nendstream\nendobj\n".utf8)
    }

    /// One `N 0 obj` holding `body`.
    static func object(_ number: Int, _ body: String) -> Data {
        Data("\(number) 0 obj\n\(body)\nendobj\n".utf8)
    }

    /// One page drawing `text` in Helvetica, whose font carries `toUnicode` (already filtered
    /// with FlateDecode) as its `/ToUnicode` map when given.
    static func textDocument(_ text: String, toUnicode: Data?) -> Data {
        let content = Data("BT /F1 12 Tf 72 700 Td (\(text)) Tj ET".utf8)
        var objects = [
            object(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"),
            streamObject(4, dictionary: "<< /Length \(content.count) >>", data: content),
        ]
        if let toUnicode {
            objects.append(object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R >>"))
            objects.append(streamObject(6, dictionary: "<< /Length \(toUnicode.count) /Filter /FlateDecode >>", data: toUnicode))
        } else {
            objects.append(object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))
        }
        return document(objects)
    }

    /// This process's memory footprint (`phys_footprint`, what jetsam counts), in bytes.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A file a PDF reader can open: `objects` must be numbered 1, 2, … in order, with object 1
    /// the catalog. Adds the cross-reference table and trailer.
    static func document(_ objects: [Data]) -> Data {
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for object in objects {
            offsets.append(out.count)
            out += object
        }
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(out.count)\n%%EOF\n"
        return out + Data(table.utf8)
    }

    private static var scanImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 16))
        }
    }
}
