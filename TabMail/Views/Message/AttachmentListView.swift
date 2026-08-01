/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import QuickLook
import UIKit

struct AttachmentListView: View {
    let message: MessageHeader
    let attachments: [AttachmentInfo]
    /// Rendered HTML of the parent message (MessageBody.htmlContent). Used to power
    /// `.eml` attachment previews — the embedded email is already inside this string
    /// as a `<div class="tm-eml-section" data-filename="…">` marker, so the preview
    /// sheet just re-renders it with preview-mode CSS. `nil` means .eml taps fall
    /// back to the old QuickLook flow (which shows a file, not a rendered email).
    let bodyHtml: String?

    @State private var downloadingSection: String?
    @State private var downloadedFiles: [String: URL] = [:]
    @State private var emlPreview: EmlPreviewState?
    @State private var error: String?

    private let manager = AccountManager.shared

    init(message: MessageHeader, attachments: [AttachmentInfo], bodyHtml: String? = nil) {
        self.message = message
        self.attachments = attachments
        self.bodyHtml = bodyHtml
    }

    private struct EmlPreviewState: Identifiable {
        let id = UUID()
        let html: String
        let filename: String
        let nestedAttachments: [AttachmentInfo]
    }

    private func isEmlAttachment(_ attachment: AttachmentInfo) -> Bool {
        attachment.contentType.lowercased().hasPrefix("message/rfc822")
            || attachment.filename.lowercased().hasSuffix(".eml")
    }

    /// Attachments shown at this level — only top-level. Nested attachments
    /// (those inside an attached `.eml`) are surfaced inside
    /// `EmlAttachmentPreview` instead, so they appear in the context of the
    /// `.eml` that carries them (matching Mail.app / Thunderbird behavior).
    private var visibleAttachments: [AttachmentInfo] {
        attachments.filter { $0.parentEmlSection == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !visibleAttachments.isEmpty {
                Text("Attachments")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(visibleAttachments, id: \.section) { attachment in
                HStack(spacing: 0) {
                    Button {
                        if attachment.contentType.lowercased().contains("text/calendar") {
                            downloadAndImportICS(attachment)
                        } else if isEmlAttachment(attachment), let html = bodyHtml {
                            // .eml has no QuickLook renderer — use our own sheet that
                            // re-renders the already-stored body HTML with preview-mode
                            // CSS showing only this attachment's section. Pass along
                            // the nested attachments (filtered by parentEmlSection
                            // matching this .eml's section) so the preview sheet can
                            // surface them as a mini attachment strip.
                            PreviewFreezeGate.shared.begin()
                            let nested = attachments.filter { $0.parentEmlSection == attachment.section }
                            emlPreview = EmlPreviewState(
                                html: html,
                                filename: attachment.filename,
                                nestedAttachments: nested
                            )
                        } else if let existing = downloadedFiles[attachment.section] {
                            // Imperative QuickLook — detached from this re-rendering
                            // List row (see AttachmentQuickLook). It raises the
                            // freeze gate for the duration and releases on dismiss.
                            AttachmentQuickLook.present(url: existing)
                        } else {
                            downloadAndPreview(attachment)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: iconName(for: attachment.contentType))
                                .font(.body)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.filename)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)

                                if attachment.size > 0 {
                                    Text(formatSize(attachment.size))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }

                            Spacer()

                            if downloadingSection == attachment.section {
                                ProgressView()
                                    .controlSize(.small)
                            } else if downloadedFiles[attachment.section] != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.body)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadingSection != nil)

                    if let fileURL = downloadedFiles[attachment.section] {
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .foregroundStyle(Theme.accent)
                                .padding(.leading, 10)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(item: $emlPreview) { preview in
            EmlAttachmentPreview(
                html: preview.html,
                filename: preview.filename,
                nestedAttachments: preview.nestedAttachments,
                parentMessage: message
            ) {
                emlPreview = nil
            }
        }
        .onDisappear {
            // Safety net: if the view tears down with the .eml sheet still
            // presented, release the gate so the app doesn't stay frozen. The
            // QuickLook path is imperative (AttachmentQuickLook owns its own gate
            // release on dismiss, independent of this view's lifetime).
            if emlPreview != nil {
                PreviewFreezeGate.shared.end()
            }
        }
        .onChange(of: emlPreview?.id) { old, new in
            // .eml preview dismissal: id flips to nil → release the freeze gate.
            if old != nil && new == nil {
                PreviewFreezeGate.shared.end()
            }
        }
    }

    private func downloadAndImportICS(_ attachment: AttachmentInfo) {
        downloadingSection = attachment.section
        error = nil
        Task {
            do {
                let data = try await manager.fetchAttachment(for: message, section: attachment.section, encoding: attachment.encoding)
                ICSCalendarImporter.presentCalendarImport(icsData: data)
            } catch {
                self.error = SyncEngine.isConnectionError(error) ? "Download failed. Check your connection and try again." : "Download failed: \(error.localizedDescription)"
                print("[Attachment] ICS download failed: \(error)")
            }
            downloadingSection = nil
        }
    }

    private func downloadAndPreview(_ attachment: AttachmentInfo) {
        downloadingSection = attachment.section
        error = nil
        print("[Attachment] Starting download: section=\(attachment.section) contentType=\(attachment.contentType) filename=\(attachment.filename) encoding=\(attachment.encoding ?? "nil")")
        Task {
            // Freeze UI BEFORE any work that could precede the QL presentation, so
            // the sync cascade is quiet by the time QuickLook first lays out.
            // `defer` guarantees release on every exit path that does NOT end in a
            // presented preview — success path flips `presented = true`, and
            // `AttachmentQuickLook` owns the release (via its dismiss delegate)
            // once QuickLook is dismissed. `present()` re-raising the gate is a
            // no-op (idempotent), so a single dismiss balances both begins.
            PreviewFreezeGate.shared.begin()
            var presented = false
            defer {
                if !presented {
                    PreviewFreezeGate.shared.end()
                }
            }

            // Store-first: if BodyAssetStore has this attachment cached, skip the network.
            // User tap on a cached attachment counts as a message access, so bump LRU.
            if let assetId = BodyAssetStore.attachmentAssetId(
                contentKey: ContentKey(rawValue: message.id), section: attachment.section),
               let storedURL = BodyAssetStore.urlOnDisk(assetId: assetId) {
                print("[Attachment] Cache HIT for \(attachment.filename) — skipping network")
                BodyAssetStore.bumpMessageAccess(contentKey: ContentKey(rawValue: message.id))
                let fileURL = makePreviewURL(from: storedURL, originalFilename: attachment.filename)
                downloadedFiles[attachment.section] = fileURL
                AttachmentQuickLook.present(url: fileURL)
                presented = true
                downloadingSection = nil
                return
            }

            do {
                let data = try await manager.fetchAttachment(for: message, section: attachment.section, encoding: attachment.encoding)
                print("[Attachment] Downloaded \(data.count) bytes for \(attachment.filename)")
                // Cache to BodyAssetStore — best-effort. If write fails, fall back
                // to a tmp file so the preview still works.
                let cachedAssetId = BodyAssetStore.writeAttachment(
                    contentKey: ContentKey(rawValue: message.id),
                    section: attachment.section,
                    contentType: attachment.contentType,
                    data: data
                )
                BodyAssetStore.bumpMessageAccess(contentKey: ContentKey(rawValue: message.id))
                let fileURL: URL
                if let cachedAssetId, let storedURL = BodyAssetStore.urlOnDisk(assetId: cachedAssetId) {
                    fileURL = makePreviewURL(from: storedURL, originalFilename: attachment.filename)
                } else {
                    let tempDir = FileManager.default.temporaryDirectory
                    let tmpURL = tempDir.appendingPathComponent(attachment.filename)
                    try data.write(to: tmpURL)
                    fileURL = tmpURL
                }
                print("[Attachment] Written to \(fileURL.path), presenting QuickLook")
                downloadedFiles[attachment.section] = fileURL
                AttachmentQuickLook.present(url: fileURL)
                presented = true
            } catch {
                self.error = SyncEngine.isConnectionError(error) ? "Download failed. Check your connection and try again." : "Download failed: \(error.localizedDescription)"
                print("[Attachment] Download failed: \(error)")
            }
            downloadingSection = nil
        }
    }

    /// Materializes a QuickLook-friendly URL from a stored asset.
    ///
    /// We always copy to `NSTemporaryDirectory()` rather than handing QuickLook the
    /// raw App Group path for two reasons:
    /// 1. The store path is `<headerHash>/<assetHash>` (no extension, no friendly
    ///    name) — QuickLook would show the asset hash as the title and lose its
    ///    UTType-from-extension hint.
    /// 2. iOS Simulator (iOS 13+) has a documented bug where QLPreviewController's
    ///    `quicklookd` XPC service can't issue sandbox extensions for paths outside
    ///    `Documents/`/`tmp/`/`Caches/`, rendering App-Group-located previews as a
    ///    blank gray sheet.
    private func makePreviewURL(from storedURL: URL, originalFilename: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tmpURL = tempDir.appendingPathComponent(originalFilename)
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            try FileManager.default.copyItem(at: storedURL, to: tmpURL)
            return tmpURL
        } catch {
            print("[Attachment] copy-to-tmp failed for preview, falling back to stored URL: \(error)")
            return storedURL
        }
    }

    private func iconName(for contentType: String) -> String {
        let lower = contentType.lowercased()
        if lower.hasPrefix("message/rfc822") { return "envelope" }
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "film" }
        if lower.hasPrefix("audio/") { return "waveform" }
        if lower.contains("pdf") { return "doc.richtext" }
        if lower.contains("zip") || lower.contains("compressed") { return "doc.zipper" }
        if lower.contains("spreadsheet") || lower.contains("excel") { return "tablecells" }
        if lower.contains("presentation") || lower.contains("powerpoint") { return "rectangle.on.rectangle" }
        if lower.contains("word") || lower.contains("document") { return "doc.text" }
        if lower.contains("calendar") { return "calendar" }
        return "doc"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

/// Imperative QuickLook presentation, deliberately detached from the SwiftUI
/// view tree.
///
/// SwiftUI's `.quickLookPreview` modifier must be hosted on a view; here that
/// view (`AttachmentListView`) lives inside the message-detail `List` row. When
/// that row's tree re-renders (background sync, label reloads, the inbox/detail
/// re-evaluating, even QL's own presentation layout passes), SwiftUI
/// reconfigures the hosted preview — the out-of-process QuickLook *extension*
/// gets interrupted and relaunched, which the user sees as the preview
/// "blinking / reloading." This reproduced for BOTH a `.xlsx` and a PDF
/// (different QL extensions → common cause is the host, not the file), and it
/// happened even with `PreviewFreezeGate` holding (logmain.log 2026-06-24:
/// repeated `QLOverlayDefaultActionBut…` re-layouts + `Connection to appex
/// interrupted`), because the gate only suppresses *some* re-render sources.
///
/// Presenting a `QLPreviewController` imperatively from the top view controller
/// (same pattern as `ICSCalendarImporter`) removes the preview from the SwiftUI
/// tree entirely, so no re-render at any level can touch it. `PreviewFreezeGate`
/// is still raised for the duration — defense-in-depth, and it quiets background
/// sync while the preview is up.
@MainActor
enum AttachmentQuickLook {
    /// `QLPreviewController.dataSource`/`.delegate` are `weak`, so the controller
    /// and its data source must be retained for the lifetime of the
    /// presentation (mirrors `ICSCalendarImporter.activeSafari`). Only one
    /// QuickLook can be on screen at a time (it's full-screen modal), so a
    /// single static slot is sufficient.
    private static var activeController: QLPreviewController?
    private static var activeSource: PreviewSource?

    /// Present `url` in QuickLook. No-op if a preview is already on screen.
    static func present(url: URL) {
        guard activeController == nil else {
            print("[Attachment] QuickLook already presented — ignoring tap")
            return
        }
        guard let presenter = topViewController() else {
            print("[Attachment] QuickLook: no view controller to present from")
            return
        }
        let source = PreviewSource(url: url)
        let controller = QLPreviewController()
        controller.dataSource = source
        controller.delegate = DismissDelegate.shared
        activeController = controller
        activeSource = source
        PreviewFreezeGate.shared.begin()
        print("[Attachment] QuickLook presenting \(url.lastPathComponent) from \(type(of: presenter))")
        presenter.present(controller, animated: true)
    }

    /// Release the freeze gate + retained refs once the preview dismisses.
    /// Idempotent — guarded so a stray call can't unbalance the gate.
    fileprivate static func handleDismiss() {
        guard activeController != nil else { return }
        activeController = nil
        activeSource = nil
        PreviewFreezeGate.shared.end()
        print("[Attachment] QuickLook dismissed — freeze released")
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var vc = window.rootViewController else { return nil }
        while let next = vc.presentedViewController { vc = next }
        return vc
    }

    /// Single-item data source. `NSURL` conforms to `QLPreviewItem` (returns
    /// itself as `previewItemURL`), so no wrapper object is needed.
    private final class PreviewSource: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }

    /// `@unchecked Sendable`: stateless delegate singleton (no mutable members),
    /// same pattern as `ICSCalendarImporter.SafariDelegate`.
    private final class DismissDelegate: NSObject, QLPreviewControllerDelegate, @unchecked Sendable {
        static let shared = DismissDelegate()
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            Task { @MainActor in AttachmentQuickLook.handleDismiss() }
        }
    }
}
