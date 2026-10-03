/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

/// Builds PDFs in memory for the PDF-reading tests, so no real document is ever committed.
enum PDFFixtures {

    enum Page {
        /// Text drawn with a real font, so PDFKit can extract it.
        case text(String)
        /// A page with nothing on it.
        case empty
        /// A page that only carries a bitmap, like a scan.
        case image
    }

    static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    static func make(_ pages: [Page], userPassword: String? = nil, ownerPassword: String? = nil) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [:]
        if let userPassword { info[kCGPDFContextUserPassword as String] = userPassword }
        if let ownerPassword { info[kCGPDFContextOwnerPassword as String] = ownerPassword }
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

    private static var scanImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 16))
        }
    }
}
