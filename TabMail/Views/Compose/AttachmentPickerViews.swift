/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The photo library and Files pickers as views a sheet presents, as `CameraPickerView` is for the
// camera. A pick that opens something next (the chat's paperclip opens the reply's card) waits for
// the sheet's `onDismiss`: UIKit refuses a presentation while its presenter is still closing the
// picker, and the SwiftUI `photosPicker` and `fileImporter` modifiers say only that a pick landed,
// not when their picker has gone.

/// The photo library picker: photos and videos, any number. `onPick` gets what was picked (nothing
/// on Cancel); the picker then closes itself.
struct PhotoLibraryPickerView: UIViewControllerRepresentable {
    let onPick: ([NSItemProvider]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        // 0: no limit, as compose's own Photos button allows.
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoLibraryPickerView
        init(_ parent: PhotoLibraryPickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if !results.isEmpty {
                parent.onPick(results.map(\.itemProvider))
            }
            parent.dismiss()
        }
    }
}

/// The Files picker: any file, any number. `onPick` gets the files picked (nothing on Cancel); the
/// picker then closes itself. The files are opened in place, as the `fileImporter` gives them.
struct FilePickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FilePickerView
        init(_ parent: FilePickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty {
                parent.onPick(urls)
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
