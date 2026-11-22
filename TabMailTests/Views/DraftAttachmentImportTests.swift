/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import TabMail

/// How a picked photo, a camera shot and a file become attachments. These are compose's rules as
/// they stood before the conversion moved into `DraftAttachmentImport`: the names, the types and
/// the failure labels must not change for compose, and the chat's new email gets the same ones.
@Suite("Draft attachment import")
struct DraftAttachmentImportTests {
    private struct ReadFailed: Error {}

    @Test("A picked photo is named photo_<n> after the attachments already there, typed by its content type")
    func pickedPhotoNameAndType() {
        let data = Data([1, 2, 3])
        let attachment = DraftAttachmentImport.pickedAttachment(data: data, contentType: .png, existingCount: 0)
        #expect(attachment.filename == "photo_1.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.data == data)
        #expect(attachment.isAlternative == false)
    }

    @Test("A picked video counts on from the attachments already there")
    func pickedVideoCountsOn() {
        let attachment = DraftAttachmentImport.pickedAttachment(
            data: Data([4]), contentType: .quickTimeMovie, existingCount: 2)
        #expect(attachment.filename == "photo_3.mov")
        #expect(attachment.mimeType == "video/quicktime")
    }

    @Test("A picked item with no content type is application/octet-stream, extension dat")
    func pickedItemWithoutType() {
        let attachment = DraftAttachmentImport.pickedAttachment(data: Data([5]), contentType: nil, existingCount: 4)
        #expect(attachment.filename == "photo_5.dat")
        #expect(attachment.mimeType == "application/octet-stream")
    }

    @Test("A picked item that fails is reported by its place in the selection, counted from one")
    func pickedFailureLabel() {
        #expect(DraftAttachmentImport.pickedFailureLabel(index: 0) == "Selected photo or video 1")
        #expect(DraftAttachmentImport.pickedFailureLabel(index: 3) == "Selected photo or video 4")
    }

    @Test("The camera's photo is a JPEG at quality 0.85, named photo_<n>.jpg")
    func cameraPhoto() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let expected = try #require(image.jpegData(compressionQuality: 0.85))
        let attachment = try #require(DraftAttachmentImport.cameraAttachment(image, existingCount: 1))
        #expect(attachment.filename == "photo_2.jpg")
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.data == expected)
        #expect(DraftAttachmentImport.cameraJPEGQuality == 0.85)
    }

    @Test("A camera photo that cannot be encoded is reported as Camera photo")
    func cameraFailureLabel() {
        #expect(DraftAttachmentImport.cameraFailureLabel == "Camera photo")
        #expect(DraftAttachmentImport.cameraAttachment(UIImage(), existingCount: 0) == nil)
    }

    @Test("A file keeps its own name and is typed by its extension")
    func fileNameAndType() {
        let url = URL(fileURLWithPath: "/tmp/import/Quarterly Report.pdf")
        let data = Data([9, 9])
        let attachment = DraftAttachmentImport.fileAttachment(data: data, url: url)
        #expect(attachment.filename == "Quarterly Report.pdf")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.data == data)
    }

    @Test("A file whose extension names no type is application/octet-stream")
    func fileWithUnknownExtension() {
        let unknown = DraftAttachmentImport.fileAttachment(
            data: Data([1]), url: URL(fileURLWithPath: "/tmp/import/notes.zzqqunknown"))
        #expect(unknown.mimeType == "application/octet-stream")
        let bare = DraftAttachmentImport.fileAttachment(
            data: Data([1]), url: URL(fileURLWithPath: "/tmp/import/README"))
        #expect(bare.filename == "README")
        #expect(bare.mimeType == "application/octet-stream")
    }

    @Test("A file that fails is reported by its own name")
    func fileFailureLabel() {
        let url = URL(fileURLWithPath: "/tmp/import/budget.xlsx")
        #expect(DraftAttachmentImport.fileFailureLabel(url) == "budget.xlsx")
    }

    @Test("Importing files keeps every readable one, in order and whole, and reports every one that fails")
    func importFilesKeepsOrderAndReportsFailures() {
        let first = URL(fileURLWithPath: "/tmp/import/a.pdf")
        let broken = URL(fileURLWithPath: "/tmp/import/b.txt")
        let last = URL(fileURLWithPath: "/tmp/import/c.png")
        let large = Data(repeating: 7, count: 300_000)
        let result = DraftAttachmentImport.importFiles([first, broken, last]) { url in
            if url == broken { throw ReadFailed() }
            return url == last ? large : Data([1])
        }
        let names = result.attachments.map(\.filename)
        #expect(names == ["a.pdf", "c.png"])
        #expect(result.failures == ["b.txt"])
        guard result.attachments.count == 2 else { return }
        #expect(result.attachments[1].data == large)
        #expect(result.attachments[1].mimeType == "image/png")
    }

    @Test("Compose names its picked photos, camera shots and files only through DraftAttachmentImport")
    func composeUsesTheSharedRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"), encoding: .utf8)
        #expect(source.contains("DraftAttachmentImport.loadPicked("))
        #expect(!source.contains("DraftAttachmentImport.pickedAttachment("), "picked items load only through loadPicked")
        #expect(source.contains("DraftAttachmentImport.cameraAttachment("))
        #expect(source.contains("DraftAttachmentImport.importFiles("))
        #expect(!source.contains("\"photo_\\("))
        #expect(!source.contains("jpegData(compressionQuality:"))
    }

    @Test("Picked items load in order: each one that loads is added, named by what is there as it lands; each that throws or has no data fails under its place; each settles after its add or fail")
    @MainActor
    func loadPickedOrderNamesAndSettles() async {
        var attachments = [DraftAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data([1]))]
        var events: [String] = []
        await DraftAttachmentImport.loadPicked(
            ["first", "broken", "empty", "last"],
            load: { item in
                if item == "broken" { throw ReadFailed() }
                if item == "empty" { return (data: nil, type: UTType.png) }
                return (data: Data(item.utf8), type: item == "last" ? UTType.quickTimeMovie : UTType.png)
            },
            existingCount: { attachments.count },
            add: { attachment in
                attachments.append(attachment)
                events.append("add \(attachment.filename)")
            },
            fail: { label in events.append("fail \(label)") },
            settled: { succeeded in events.append("settled \(succeeded)") })
        let names = attachments.map(\.filename)
        let contents = attachments.map(\.data)
        #expect(names == ["report.pdf", "photo_2.png", "photo_3.mov"])
        #expect(contents == [Data([1]), Data("first".utf8), Data("last".utf8)])
        #expect(events == [
            "add photo_2.png", "settled true",
            "fail Selected photo or video 2", "settled false",
            "fail Selected photo or video 3", "settled false",
            "add photo_3.mov", "settled true",
        ])
    }

    @Test("Loading no picked items does nothing")
    @MainActor
    func loadPickedNothing() async {
        var calls = 0
        await DraftAttachmentImport.loadPicked(
            [String](),
            load: { _ in (data: Data([1]), type: UTType.png) },
            existingCount: { 0 },
            add: { _ in calls += 1 },
            fail: { _ in calls += 1 },
            settled: { _ in calls += 1 })
        #expect(calls == 0)
    }

    @Test("Importing no files gives nothing and no failures")
    func importNoFiles() {
        let result = DraftAttachmentImport.importFiles([]) { _ in Data() }
        #expect(result.attachments.isEmpty)
        #expect(result.failures.isEmpty)
    }
}
