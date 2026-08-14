/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import QuickLook

/// Sheet that previews an embedded `.eml` attachment as a proper message card.
///
/// The envelope (subject, from, date, to/cc) is rendered natively in SwiftUI from
/// `data-*` attributes on the `.tm-eml-section` marker — no HTML duplicate. The
/// body is the already-stored `MessageBody.htmlContent`, re-rendered by the same
/// `AutoSizingHTMLView` used for the main message (quote-collapse, dark-mode,
/// cleanup-JS, and table-block CSS all apply identically). No re-fetch, no re-parse.
///
/// Nested attachments (files inside the `.eml`, e.g. a PDF attached to a forwarded
/// email) are surfaced HERE — not in the parent message's attachment list — so the
/// user sees each attachment in the context of the message that actually carries
/// it. Tapping a nested attachment uses the same fetchAttachment + QuickLook flow
/// that `AttachmentListView` uses for regular attachments.
struct EmlAttachmentPreview: View {
    let html: String
    let filename: String
    let nestedAttachments: [AttachmentInfo]
    let parentMessage: MessageHeader
    let onDismiss: () -> Void

    /// Parsed once on init — envelope metadata carried on the marker div.
    private let metadata: EmailFilter.EmlSectionMetadata?

    @State private var downloadingSection: String?
    @State private var downloadedFiles: [String: URL] = [:]
    @State private var previewURL: URL?
    @State private var error: String?

    private let manager = AccountManager.shared

    init(
        html: String,
        filename: String,
        nestedAttachments: [AttachmentInfo] = [],
        parentMessage: MessageHeader,
        onDismiss: @escaping () -> Void
    ) {
        self.html = html
        self.filename = filename
        self.nestedAttachments = nestedAttachments
        self.parentMessage = parentMessage
        self.onDismiss = onDismiss
        self.metadata = EmailFilter.parseEmlSectionMetadata(html: html, filename: filename)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    AutoSizingHTMLView(html: html, previewFilename: filename)
                    if !nestedAttachments.isEmpty {
                        nestedAttachmentStrip
                            .padding(.horizontal)
                            .padding(.top, 12)
                    }
                }
                .padding(.top, 12)
            }
            .background(Theme.cardBackground)
            // The LABEL. `filename` itself must stay RAW everywhere else on
            // this view — `AutoSizingHTMLView(previewFilename:)` and
            // `parseEmlSectionMetadata` MATCH it against the `data-filename`
            // attribute the renderer wrote from the same MIME parameter, so
            // labelling it there would stop the section from being found. Only
            // the human-readable title is checked.
            .navigationTitle(AttachmentFilename.displayLabel(filename))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .quickLookPreview($previewURL)
    }

    // MARK: - Native header (mirrors MessageCardView.expandedHeaderDetails)

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let from = metadata?.from {
                Text(MessageViewHelpers.extractNames(from))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
            }
            if let date = metadata?.date {
                Text(MessageViewHelpers.formatExpandedDate(date))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let to = metadata?.toList, !to.isEmpty {
                Text("To: \(MessageViewHelpers.extractNames(to))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cc = metadata?.ccList, !cc.isEmpty {
                Text("Cc: \(MessageViewHelpers.extractNames(cc))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subject = metadata?.subject {
                Text(subject)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    // MARK: - Nested attachment strip

    @ViewBuilder
    private var nestedAttachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attachments")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)
            ForEach(nestedAttachments, id: \.section) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: attachment.contentType))
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        // The LABEL — same reason as the top-level attachment
                        // row in `AttachmentListView`: the raw value is a
                        // sender-authored MIME parameter, and a bidi override or
                        // mark in it makes this label claim a type the bytes do
                        // not have. See `AttachmentFilename.displayLabel`.
                        Text(AttachmentFilename.displayLabel(attachment.filename))
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
                        ProgressView().controlSize(.small)
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
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let existing = downloadedFiles[attachment.section] {
                        previewURL = existing
                    } else {
                        downloadAndPreview(attachment)
                    }
                }
                .disabled(downloadingSection != nil)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func downloadAndPreview(_ attachment: AttachmentInfo) {
        downloadingSection = attachment.section
        error = nil
        Task {
            await downloadAndPreview(attachment) { part in
                try await manager.fetchAttachment(
                    for: parentMessage, section: part.section, encoding: part.encoding
                )
            }
            downloadingSection = nil
        }
    }

    /// Fetch → disk → preview, with the fetch supplied by the caller.
    ///
    /// `fetch` is required rather than defaulted: this is the only place a nested
    /// `.eml` attachment reaches the filesystem, and a seam that could be omitted
    /// would let a test silently exercise the live account instead of the write
    /// path it means to pin.
    func downloadAndPreview(
        _ attachment: AttachmentInfo,
        fetch: (AttachmentInfo) async throws -> Data
    ) async {
        // Refused BEFORE the fetch, for the same reason as the top-level row in
        // `AttachmentListView.downloadAndPreview`: the staged file's last path
        // component is this name, the stager will not create an attempt for a name
        // `AttachmentFilename` refuses, and fetching bytes nothing can open costs
        // the user data for nothing. The strip already reads
        // `AttachmentFilename.unsupportedLabel` for this attachment.
        guard AttachmentFilename.isSafeFileComponent(attachment.filename) else {
            error = AttachmentFilename.unsupportedMessage
            return
        }
        do {
            let data = try await fetch(attachment)
            // `attachment.filename` is a raw MIME parameter authored by whoever
            // sent the `.eml`, so it may carry path separators — joining it onto
            // a directory lets it escape (`../Library/Application Support/TabMail/
            // tabmail.sqlite` overwrites the live GRDB store). The stager reduces
            // it to a single path component under a fresh per-attempt directory,
            // the same guard `AttachmentListView` already applies to top-level
            // attachments, and the per-attempt UUID also keeps repeated downloads
            // of one attachment from overwriting the bytes a live preview reads.
            //
            // `messageId:` is `parentMessage.id` because that is the identity
            // these bytes were fetched under — `fetchAttachment(for: parentMessage,
            // section:)` — so the staging namespace is the same content key the
            // sibling call site uses. The nested part is distinguished by
            // `section`, which the stager deliberately keeps out of the namespace.
            let fileURL = try AttachmentPreviewStager.stage(
                data: data,
                messageId: parentMessage.id,
                originalFilename: attachment.filename
            )
            downloadedFiles[attachment.section] = fileURL
            previewURL = fileURL
        } catch {
            self.error = SyncEngine.isConnectionError(error)
                ? "Download failed. Check your connection and try again."
                : "Download failed: \(error.localizedDescription)"
            print("[EmlNestedAttachment] Download failed: \(error)")
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
