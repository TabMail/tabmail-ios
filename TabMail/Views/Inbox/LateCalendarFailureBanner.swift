/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One calendar change that failed after its chat turn ended (`LateCalendarFailureStore`),
/// laid out like the inbox error banner. Dismiss is its only button, unless the change holds
/// files saved on this device that it could not attach again (#718,
/// `LateCalendarFailure.holdsFiles`): then a Save File button offers copies through the share
/// sheet, and Dismiss warns first that it deletes them (`SavedPutBackFilesWarning`).
struct LateCalendarFailureBanner: View {
    let failure: LateCalendarFailure
    let onDismiss: () -> Void
    /// Copies of the failure's saved files for the share sheet.
    let onExport: () throws -> [URL]

    @State private var confirmingDismiss = false
    @State private var exported: SavedPutBackFilesWarning.Export?

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(failure.bannerText)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if failure.holdsFiles {
                Button(SavedPutBackFilesWarning.saveTitle(failure.heldFiles.count)) { exported = SavedPutBackFilesWarning.export(onExport) }
                    .font(.caption)
            }
            Button {
                if failure.holdsFiles { confirmingDismiss = true } else { onDismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.errorBg)
        .foregroundStyle(Theme.errorFg)
        .confirmationDialog(
            SavedPutBackFilesWarning.dismissTitle, isPresented: $confirmingDismiss, titleVisibility: .visible
        ) {
            Button(SavedPutBackFilesWarning.saveTitle(failure.heldFiles.count)) { exported = SavedPutBackFilesWarning.export(onExport) }
            Button(SavedPutBackFilesWarning.deleteTitle(failure.heldFiles.count), role: .destructive, action: onDismiss)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SavedPutBackFilesWarning.dismissMessage(failure.heldFiles.count))
        }
        .sheet(item: $exported) { export in
            SavedPutBackFilesWarning.sheet(export)
        }
    }
}

/// The words and the share sheet of the warning before saved put-back files are deleted (#718):
/// on the failure banner's Dismiss and on account removal. The files are the only copy of what
/// the user had attached to events changed on their own, so the user is offered a copy first.
@MainActor
enum SavedPutBackFilesWarning {
    /// What the share sheet shares: copies of the files, or why there are none.
    struct Export: Identifiable {
        let id = UUID()
        let urls: [URL]
        let problem: String?
    }

    static let dismissTitle = "Delete the saved files?"

    static func saveTitle(_ count: Int) -> String { count == 1 ? "Save File" : "Save Files" }

    static func deleteTitle(_ count: Int) -> String { count == 1 ? "Dismiss and Delete File" : "Dismiss and Delete Files" }

    static func dismissMessage(_ count: Int) -> String {
        "\(PutBackFile.notRestoredMessage(count)) Dismissing deletes \(count == 1 ? "it" : "them") from this iPhone. Save \(count == 1 ? "it" : "them") first to keep a copy."
    }

    /// The account-removal alert's words for `count` saved files.
    static func accountRemovalMessage(_ count: Int, email: String) -> String {
        "\(PutBackFile.notRestoredMessage(count)) Removing \(email) deletes \(count == 1 ? "it" : "them") from this iPhone, with all its local data. Save \(count == 1 ? "it" : "them") first to keep a copy."
    }

    /// Runs `copies` for the share sheet.
    static func export(_ copies: () throws -> [URL]) -> Export {
        do {
            return Export(urls: try copies(), problem: nil)
        } catch {
            BackgroundSyncLogger.logError("[CalendarPutBack] could not copy saved files for sharing: \(error)", source: "CalendarQueue")
            return Export(urls: [], problem: "The saved files could not be read.")
        }
    }

    @ViewBuilder
    static func sheet(_ export: Export) -> some View {
        if let problem = export.problem {
            Text(problem).padding()
        } else {
            ActivityViewController(activityItems: export.urls)
        }
    }
}
