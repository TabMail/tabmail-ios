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
                                // The LABEL, not `attachment.filename`. The raw
                                // value is a sender-authored MIME parameter, and
                                // measured, `report<RLO>fdp.exe` renders here as
                                // `reportexe.pdf` — a label claiming a type the
                                // bytes do not have, on the screen where the user
                                // decides whether to tap. A refused name shows
                                // `AttachmentFilename.unsupportedLabel` instead,
                                // and the tap below refuses for the same reason,
                                // so the row and the action cannot disagree.
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

    /// ⚠️ **Deliberately NOT gated on `AttachmentFilename.isSafeFileComponent`, and
    /// that asymmetry with `downloadAndPreview` below is the intended behaviour.**
    ///
    /// The filename never becomes a path component here: the fetched bytes go
    /// straight to `ICSCalendarImporter.presentCalendarImport(icsData:)`, which
    /// names its own temporary file. Nothing downstream parses the sender's string,
    /// so there is nothing for a refusal to protect — and refusing would turn a
    /// legitimate calendar invitation into an unopenable row over a bidi mark in a
    /// name this path discards.
    ///
    /// The consequence to expect, so it is not later read as a bug: the ROW can
    /// read `AttachmentFilename.unsupportedLabel` while the tap still works. The
    /// label is a statement about the NAME, not a prediction about the action; the
    /// two only have to agree where the name is load-bearing, which is the staging
    /// path (`AttachmentFilenameContainmentTests.theLabelAndTheStagedFileAgree`).
    private func downloadAndImportICS(_ attachment: AttachmentInfo) {
        downloadingSection = attachment.section
        error = nil
        Task {
            do {
                let data = try await manager.fetchAttachment(for: message, section: attachment.section, encoding: attachment.encoding)
                ICSCalendarImporter.presentCalendarImport(icsData: data)
            } catch {
                self.error = SyncEngine.isConnectionError(error) ? "Download failed. Check your connection and try again." : "Download failed: \(error.localizedDescription)"
                if DebugModeManager.isLoggingEnabled() {
                    print("[Attachment] ICS download failed: \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                }
            }
            downloadingSection = nil
        }
    }

    private func downloadAndPreview(_ attachment: AttachmentInfo) {
        // Refused BEFORE the fetch: the staged file's last path component is this
        // name, `AttachmentPreviewStager` will not create an attempt for it, and
        // downloading bytes nothing can open costs the user data for nothing. The
        // row already reads `AttachmentFilename.unsupportedLabel`; this is the
        // fuller sentence on the action, and it names no reason and quotes no name
        // (see `AttachmentFilenameError.errorDescription`).
        guard AttachmentFilename.isSafeFileComponent(attachment.filename) else {
            error = AttachmentFilename.unsupportedMessage
            return
        }
        downloadingSection = attachment.section
        error = nil
        // Every field here is a sender-authored MIME value, and `print` is a
        // line-oriented sink, so each one is escaped: see
        // `DebugModeManager.escapedForLogLine`.
        if DebugModeManager.isLoggingEnabled() {
            let escape = DebugModeManager.escapedForLogLine
            print("[Attachment] Starting download: section=\(escape(attachment.section)) contentType=\(escape(attachment.contentType)) filename=\(escape(attachment.filename)) encoding=\(escape(attachment.encoding ?? "nil"))")
        }
        Task {
            // Reserve the one global QuickLook slot before the network fetch or
            // staging. A second scene therefore cannot materialize or mutate any
            // path while the active presentation is reading it.
            guard AttachmentQuickLook.reservePresentation() else {
                downloadingSection = nil
                return
            }

            // Freeze UI BEFORE any work that could precede the QL presentation, so
            // the sync cascade is quiet by the time QuickLook first lays out.
            // `defer` guarantees release on every exit path that does NOT end in a
            // presented preview — success path flips `presented = true`, and
            // `AttachmentQuickLook` owns the release (via its dismiss delegate)
            // once QuickLook is dismissed. `present()` re-raising the gate is a
            // no-op (idempotent), so a single dismiss balances both begins.
            // The reservation is released on exactly the same condition, so no
            // failure, throw, or cancellation can strand the slot and wedge every
            // later preview.
            PreviewFreezeGate.shared.begin()
            var presented = false
            defer {
                if !presented {
                    AttachmentQuickLook.cancelReservedPresentation()
                    PreviewFreezeGate.shared.end()
                }
            }

            // The identity these bytes belong to, minted ONCE and used for BOTH the
            // cache read below and the cache write further down — so the thing we
            // check is definitionally the thing we recorded. `nil` means this
            // message's identity cannot be proven, in which case the cache is
            // neither read nor written and the attachment is simply fetched.
            let identityStamp = AttachmentCacheIdentity.stamp(for: message)

            do {
                // Both sources converge on bytes, so ONE staging + presentation path
                // serves them. Store-first: if BodyAssetStore has this attachment
                // cached FOR THIS MESSAGE, skip the network. User tap on a cached
                // attachment counts as a message access, so bump LRU.
                let data: Data
                if let identityStamp,
                   let assetId = BodyAssetStore.attachmentAssetId(
                    contentKey: ContentKey(rawValue: message.id), section: attachment.section,
                    identityStamp: identityStamp),
                   let storedURL = BodyAssetStore.urlOnDisk(assetId: assetId) {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Attachment] Cache HIT for \(DebugModeManager.escapedForLogLine(attachment.filename)) — skipping network")
                    }
                    BodyAssetStore.bumpMessageAccess(contentKey: ContentKey(rawValue: message.id))
                    data = try Data(contentsOf: storedURL)
                } else {
                    data = try await manager.fetchAttachment(for: message, section: attachment.section, encoding: attachment.encoding)
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Attachment] Downloaded \(data.count) bytes for \(DebugModeManager.escapedForLogLine(attachment.filename))")
                    }
                    // Cache to BodyAssetStore — best-effort, and only for a message whose
                    // identity we can prove. An unstamped row would be unreadable by
                    // construction (`attachmentAssetId` requires a positive match), so
                    // writing one would consume the user's attachment budget to store
                    // bytes nothing could ever serve. The preview is served from the
                    // staged copy below either way, so a refused cache write costs
                    // nothing beyond the next tap re-fetching.
                    _ = identityStamp.flatMap { stamp in
                        BodyAssetStore.writeAttachment(
                            contentKey: ContentKey(rawValue: message.id),
                            section: attachment.section,
                            contentType: attachment.contentType,
                            data: data,
                            identityStamp: stamp
                        )
                    }
                    BodyAssetStore.bumpMessageAccess(contentKey: ContentKey(rawValue: message.id))
                }

                // Stage into a fresh per-attempt directory, then complete the slot
                // reserved above. Synchronous on the MainActor from materializing the
                // file through handing it to QuickLook — there is no suspension point
                // in between, so neither another scene nor a cancellation can
                // interleave. `nil` means the slot was lost before presentation; the
                // stager has already removed the attempt directory it created.
                guard let fileURL = try AttachmentPreviewStager.stageAndPresent(
                    data: data,
                    messageId: message.id,
                    originalFilename: attachment.filename,
                    presenter: { AttachmentQuickLook.presentReserved(url: $0) }
                ) else {
                    downloadingSection = nil
                    return
                }
                if DebugModeManager.isLoggingEnabled() {
                    // The last component is the sender's filename VERBATIM — it
                    // reached here only by satisfying
                    // `AttachmentFilename.isSafeFileComponent`, which refuses
                    // separators and the C0/C1 controls, so no line break can
                    // reach this line-oriented sink through the path. The escape
                    // stays because the rest of the path is not that guarded.
                    print("[Attachment] Staged at \(DebugModeManager.escapedForLogLine(fileURL.path)), QuickLook presented")
                }
                downloadedFiles[attachment.section] = fileURL
                presented = true
            } catch {
                self.error = SyncEngine.isConnectionError(error) ? "Download failed. Check your connection and try again." : "Download failed: \(error.localizedDescription)"
                if DebugModeManager.isLoggingEnabled() {
                    print("[Attachment] Download failed: \(DebugModeManager.escapedForLogLine(String(describing: error)))")
                }
            }
            downloadingSection = nil
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

/// Produces immutable, QuickLook-friendly staging paths.
///
/// Every attempt lives under:
/// `<tmp>/TabMailAttachmentPreviews/<message hash>/<attempt UUID>/<display name>`.
/// The final component therefore remains meaningful to the user and QuickLook,
/// while neither another message with the same filename nor a second scene can
/// overwrite a file an active preview is already reading.
///
/// Rooting under `tmp/` is load-bearing rather than incidental, and staging is
/// what lets the cached path be previewed at all:
/// 1. The `BodyAssetStore` path is `<headerHash>/<assetHash>` (no extension, no
///    friendly name) — QuickLook would show the asset hash as the title and lose
///    its UTType-from-extension hint.
/// 2. iOS Simulator (iOS 13+) has a documented bug where `QLPreviewController`'s
///    `quicklookd` XPC service can't issue sandbox extensions for paths outside
///    `Documents/`/`tmp/`/`Caches/`, rendering App-Group-located previews as a
///    blank gray sheet.
///
/// **Attempt lifetime — there are TWO call-site shapes, and they do not have the
/// same lifetime.** This paragraph is the contract a third call site must pick
/// from deliberately; it said "a directory is created only after the QuickLook
/// slot is reserved, and exactly one of three things happens to it" until
/// 2026-08-12, which `1820a4fb3` had already falsified on both limbs.
///
/// 1. **Reserved + imperative** — `stageAndPresent`, used by
///    `AttachmentListView.downloadAndPreview`. That caller takes the single
///    global QuickLook slot (`AttachmentQuickLook.reservePresentation`) before the
///    fetch, so no directory exists until the slot is held, and exactly one of
///    three things happens to the attempt: staging fails and `stageAttempt`
///    removes it; presentation is refused and `finishPresentation` removes it; or
///    presentation succeeds and it is retained deliberately — QuickLook reads it
///    for the life of the preview, and `downloadedFiles[section]` keeps
///    referencing it afterwards for re-present and `ShareLink`.
/// 2. **Unreserved + declarative** — `stage`, used by
///    `EmlAttachmentPreview.downloadAndPreview(_:fetch:)` since `1820a4fb3`. That
///    view presents by assigning `previewURL` to SwiftUI's `.quickLookPreview`,
///    so it reserves NOTHING, passes no presenter, and never reaches
///    `finishPresentation`: the refusal arm is unreachable from here and the
///    directory is created without any slot being held. Only two outcomes exist —
///    staging throws and `stageAttempt` removes the attempt, or staging succeeds
///    and the attempt is retained.
///
/// ⚠️ **The residue, stated so it is not lost — and deliberately NOT mechanised.**
/// On shape 2 the retention is unconditional, because nothing on that path can
/// observe that the bytes were never read. An `.eml` attachment staged but never
/// previewed — the sheet dismissed while the download was in flight — leaks one
/// attempt directory into `tmp/`. It loses the user nothing, and `tmp/` reclaims
/// it.
///
/// ⚠️ **The bound on that leak is PER VIEW INSTANCE, not per attachment.**
/// `09ee68157` said it was "bounded at one per staged nested attachment", which
/// reads as a global bound and is false. `EmlAttachmentPreview.downloadedFiles`
/// is `@State private var` — it dies with the view — so the re-present branch it
/// gates bounds restaging only inside ONE presentation. Dismiss the `.eml` sheet
/// and open it again and the new view starts with an empty dictionary, so the
/// same nested attachment stages a second directory; N opens leak up to N. The
/// staging task is unstructured (`Task { … }` in the private
/// `downloadAndPreview`), so it can also complete staging AFTER the sheet is
/// gone, with nothing left to read the result. The same `@State` scoping applies
/// to `AttachmentListView.downloadedFiles`, so shape 1's "at most once" is a
/// per-view statement too; there it is not a leak, because a presented preview
/// is reachable and the refusal arm removes the attempt.
/// No test exercises repeated dismissal and recreation, so nothing would go red
/// if the per-open cost grew.
///
/// Retention is otherwise bounded on both shapes: once `downloadedFiles[section]`
/// is set, every later tap ON THAT VIEW takes the re-present branch, so a given
/// attachment stages at most once per view instance, and the surviving
/// directories are reclaimed with the rest of `tmp/`.
enum AttachmentPreviewStager {
    private static let stagingDirectoryName = "TabMailAttachmentPreviews"

    /// One staging attempt: the directory `createAttempt` created, plus the file
    /// inside it the bytes are written to.
    ///
    /// The directory is carried EXPLICITLY rather than re-derived from
    /// `fileURL.deletingLastPathComponent()`, because re-deriving it means
    /// computing a delete target from a path built by joining the sender's
    /// filename. Any name that survives the reduction still holding a separator —
    /// or that resolves back to the attempt directory itself — makes that
    /// derivation walk somewhere the stager never created, and the failure paths
    /// then delete it. The creator already knows the answer; nothing may ask the
    /// attacker-influenced path for it again.
    private struct StagedAttempt {
        /// The per-attempt `<UUID>` directory. The ONLY thing any failure path
        /// here is permitted to remove.
        let directory: URL
        /// The file inside `directory` the attachment bytes are written to, and
        /// the URL every caller of `stage` / `stageAndPresent` receives.
        let fileURL: URL
    }

    static func stage(
        data: Data,
        messageId: String,
        originalFilename: String,
        rootDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        writeData: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> URL {
        try stageAttempt(
            data: data,
            messageId: messageId,
            originalFilename: originalFilename,
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            writeData: writeData
        ).fileURL
    }

    private static func stageAttempt(
        data: Data,
        messageId: String,
        originalFilename: String,
        rootDirectory: URL,
        fileManager: FileManager,
        writeData: (Data, URL) throws -> Void
    ) throws -> StagedAttempt {
        let attempt = try createAttempt(
            messageId: messageId,
            originalFilename: originalFilename,
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
        do {
            try writeData(data, attempt.fileURL)
        } catch {
            // `createAttempt` has already created the attempt directory, so a
            // failed write would otherwise strand an empty directory in tmp/
            // forever. Remove exactly THAT directory — the one we created, not a
            // parent re-derived from the destination path — then report the real
            // failure unchanged.
            discardAttemptDirectory(at: attempt.directory, fileManager: fileManager)
            throw error
        }
        return attempt
    }

    @MainActor
    static func stageAndPresent(
        data: Data,
        messageId: String,
        originalFilename: String,
        rootDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        writeData: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        presenter: (URL) -> Bool
    ) throws -> URL? {
        try finishPresentation(
            staging: {
                try stageAttempt(
                    data: data,
                    messageId: messageId,
                    originalFilename: originalFilename,
                    rootDirectory: rootDirectory,
                    fileManager: fileManager,
                    writeData: writeData
                )
            },
            fileManager: fileManager,
            presenter: presenter
        )
    }

    /// Removes ONE attempt — the `<attempt UUID>` directory it is handed, i.e.
    /// exactly what `createAttempt` created. Never a sibling attempt, never the
    /// per-message namespace, never the shared root, so it cannot touch a file
    /// another preview is reading.
    ///
    /// It removes the URL it is GIVEN and does not walk up from it: the previous
    /// form took the staged FILE and deleted its parent, which made the delete
    /// target a function of the sender-authored filename that built that path.
    /// Callers pass `StagedAttempt.directory`, which the stager created and
    /// therefore knows independently of anything the sender wrote.
    ///
    /// Best-effort: failing to delete leaks one directory into `tmp/`, which is
    /// strictly better than failing an operation that otherwise succeeded.
    ///
    /// ⚠️ `private`, and named for the DIRECTORY, because this function's
    /// contract was INVERTED in place: it used to take the staged FILE and
    /// delete that file's parent. Same name, same `internal` visibility,
    /// opposite meaning — so an in-module caller written against the old
    /// contract would compile, delete a single file, and silently leak the
    /// attempt directory. The name now states which of the two it is, and the
    /// visibility keeps the pairing with `createAttempt` (the only thing that
    /// knows this URL) from being reachable at all outside this type.
    private static func discardAttemptDirectory(
        at attemptDirectory: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: attemptDirectory)
    }

    @MainActor
    private static func finishPresentation(
        staging: () throws -> StagedAttempt,
        fileManager: FileManager,
        presenter: (URL) -> Bool
    ) rethrows -> URL? {
        let attempt = try staging()
        guard presenter(attempt.fileURL) else {
            // The slot was lost between reservation and presentation, or there
            // was no view controller to present from. Nothing will ever read
            // these bytes, so the attempt must not outlive the failed attempt.
            discardAttemptDirectory(at: attempt.directory, fileManager: fileManager)
            return nil
        }
        return attempt.fileURL
    }

    /// Builds the attempt, and REFUSES the ones that must not exist.
    ///
    /// The name is used verbatim as the final path component, so a name
    /// `AttachmentFilename` refuses never reaches the filesystem: the throw
    /// happens BEFORE `createDirectory`, so a refused attachment leaves no attempt
    /// directory behind and no cleanup path has anything to remove. This is the
    /// enforcement point; `AttachmentListView.downloadAndPreview` and
    /// `EmlAttachmentPreview.downloadAndPreview` also ask the same question before
    /// they fetch, so the user gets the message without paying for the download.
    private static func createAttempt(
        messageId: String,
        originalFilename: String,
        rootDirectory: URL,
        fileManager: FileManager
    ) throws -> StagedAttempt {
        guard AttachmentFilename.isSafeFileComponent(originalFilename) else {
            throw AttachmentFilenameError.unsupported(name: originalFilename)
        }
        // `messageId` IS this message's content key — the same value the cache
        // read and write re-hydrate — so hashing it through the store's own
        // helper reuses one hashing rule instead of introducing a second. The
        // section deliberately does not enter the namespace: the per-attempt
        // UUID already makes every attempt of every section a distinct path
        // (including two same-named attachments on one message), and cleanup
        // removes the exact directory it created rather than enumerating a
        // namespace, so nothing needs to locate "all attempts for this section".
        let namespace = BodyAssetStore.headerHash(ContentKey(rawValue: messageId))
        let directory = rootDirectory
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return StagedAttempt(
            directory: directory,
            fileURL: directory.appendingPathComponent(originalFilename)
        )
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
    private static var presentationReserved = false

    /// Claims the single presentation slot before network or filesystem work.
    /// Main-actor isolation makes the check-and-set atomic across scenes.
    static func reservePresentation() -> Bool {
        guard activeController == nil, !presentationReserved else {
            return false
        }
        presentationReserved = true
        return true
    }

    /// Releases a reservation whose download/staging path failed. It never
    /// releases the reservation represented by an active controller.
    static func cancelReservedPresentation() {
        guard activeController == nil else { return }
        presentationReserved = false
    }

    /// Present `url` in QuickLook. No-op if a preview is already on screen.
    @discardableResult
    static func present(url: URL) -> Bool {
        guard reservePresentation() else {
            if DebugModeManager.isLoggingEnabled() {
                print("[Attachment] QuickLook already presented — ignoring tap")
            }
            return false
        }
        return presentReserved(url: url)
    }

    /// Completes a slot reserved before download/staging. Every leg releases the
    /// reservation: a refusal clears it outright, and a success transfers it to
    /// `activeController`, which `handleDismiss` clears.
    @discardableResult
    static func presentReserved(url: URL) -> Bool {
        guard presentationReserved, activeController == nil else {
            presentationReserved = false
            return false
        }
        guard let presenter = topViewController() else {
            presentationReserved = false
            if DebugModeManager.isLoggingEnabled() {
                print("[Attachment] QuickLook: no view controller to present from")
            }
            return false
        }
        let source = PreviewSource(url: url)
        let controller = QLPreviewController()
        controller.dataSource = source
        controller.delegate = DismissDelegate.shared
        activeController = controller
        activeSource = source
        presentationReserved = false
        PreviewFreezeGate.shared.begin()
        if DebugModeManager.isLoggingEnabled() {
            // `lastPathComponent` is the sender's filename after the stager's
            // reduction, which removes `U+002F` and nothing else — a CR/LF in the
            // MIME `filename` parameter reaches here intact.
            print("[Attachment] QuickLook presenting \(DebugModeManager.escapedForLogLine(url.lastPathComponent)) from \(type(of: presenter))")
        }
        presenter.present(controller, animated: true)
        return true
    }

    /// Release the freeze gate + retained refs once the preview dismisses.
    /// Idempotent — guarded so a stray call can't unbalance the gate.
    fileprivate static func handleDismiss() {
        guard activeController != nil else { return }
        presentationReserved = false
        activeController = nil
        activeSource = nil
        PreviewFreezeGate.shared.end()
        if DebugModeManager.isLoggingEnabled() {
            print("[Attachment] QuickLook dismissed — freeze released")
        }
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
