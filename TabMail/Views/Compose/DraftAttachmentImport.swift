/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
import UniformTypeIdentifiers

/// How a photo, a camera shot or a file the user picks becomes a `DraftAttachment`: its name, its
/// MIME type, and the label a failure is reported under. Compose and the chat's new email share it,
/// so an attachment is named the same way wherever it is added.
///
/// The bytes are kept whole: nothing here shortens or re-encodes a picked item or a file. The
/// camera's photo is encoded once, as JPEG, because the camera hands over an image, not a file.
enum DraftAttachmentImport {
    /// The camera photo's JPEG quality.
    static let cameraJPEGQuality: CGFloat = 0.85
    /// The type of a picked item or file whose type says nothing more.
    static let unknownMIMEType = "application/octet-stream"
    /// The extension of a picked item whose type has none.
    static let unknownExtension = "dat"
    /// The failure label of a camera photo that could not be encoded.
    static let cameraFailureLabel = "Camera photo"

    /// A photo or video from the photo picker: named `photo_<n>.<ext>`, where `n` counts the
    /// attachments already there plus one, and typed by the item's first content type.
    static func pickedAttachment(data: Data, contentType: UTType?, existingCount: Int) -> DraftAttachment {
        let mimeType = contentType?.preferredMIMEType ?? unknownMIMEType
        let ext = contentType?.preferredFilenameExtension ?? unknownExtension
        return DraftAttachment(filename: "photo_\(existingCount + 1).\(ext)", mimeType: mimeType, data: data)
    }

    /// The failure label of the picker's item at `index` (zero-based), counted from one.
    static func pickedFailureLabel(index: Int) -> String {
        "Selected photo or video \(index + 1)"
    }

    /// The photo picker's items, loaded one after another in the order picked. Each item that
    /// loads becomes an attachment (`pickedAttachment`, counted from `existingCount()` as it
    /// lands) handed to `add`; each that throws or loads no data is handed to `fail` under its
    /// label (`pickedFailureLabel`). `settled` is told after each item, after its `add` or `fail`,
    /// whether it loaded, so the caller settles its carry gate and shows failures. The caller
    /// counts the items into its gate before calling, and shows the failures its own way.
    @MainActor
    static func loadPicked<Item>(
        _ items: [Item],
        load: @MainActor (Item) async throws -> (data: Data?, type: UTType?),
        existingCount: @MainActor () -> Int,
        add: @MainActor (DraftAttachment) -> Void,
        fail: @MainActor (String) -> Void,
        settled: @MainActor (_ succeeded: Bool) -> Void
    ) async {
        for (index, item) in items.enumerated() {
            var succeeded = false
            do {
                let loaded = try await load(item)
                if let data = loaded.data {
                    add(pickedAttachment(data: data, contentType: loaded.type, existingCount: existingCount()))
                    succeeded = true
                } else {
                    fail(pickedFailureLabel(index: index))
                }
            } catch {
                fail(pickedFailureLabel(index: index))
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DraftAttachmentImport] Picked item \(index + 1) failed to load: \(error)")
                }
            }
            settled(succeeded)
        }
    }

    /// The camera's photo as JPEG, named `photo_<n>.jpg` like a picked photo; nil when the image
    /// cannot be encoded (report it under `cameraFailureLabel`).
    static func cameraAttachment(_ image: UIImage, existingCount: Int) -> DraftAttachment? {
        guard let data = image.jpegData(compressionQuality: cameraJPEGQuality) else { return nil }
        return DraftAttachment(filename: "photo_\(existingCount + 1).jpg", mimeType: "image/jpeg", data: data)
    }

    /// A file from the Files picker, under its own name, typed by its extension.
    static func fileAttachment(data: Data, url: URL) -> DraftAttachment {
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? unknownMIMEType
        return DraftAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data)
    }

    /// The failure label of a file that could not be opened or read: its own name.
    static func fileFailureLabel(_ url: URL) -> String {
        url.lastPathComponent
    }

    /// The files the Files picker returned, read in order: each one that reads is an attachment,
    /// each one that does not is a failure label, so the caller reports every failure at once.
    /// `read` opens one file (`readSecurityScoped` for the picker's URLs).
    static func importFiles(
        _ urls: [URL],
        read: (URL) throws -> Data = readSecurityScoped
    ) -> (attachments: [DraftAttachment], failures: [String]) {
        var attachments: [DraftAttachment] = []
        var failures: [String] = []
        for url in urls {
            do {
                attachments.append(fileAttachment(data: try read(url), url: url))
            } catch {
                failures.append(fileFailureLabel(url))
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[DraftAttachmentImport] File import failed for \(DebugModeManager.escapedForLogLine(url.lastPathComponent)): \(error)")
                }
            }
        }
        return (attachments, failures)
    }

    /// The Files picker hands over security-scoped URLs: a file is read only while access to it is
    /// granted, and refused access is a failure like an unreadable file.
    struct AccessRefused: Error {}

    static func readSecurityScoped(_ url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else { throw AccessRefused() }
        defer { url.stopAccessingSecurityScopedResource() }
        return try Data(contentsOf: url)
    }
}
