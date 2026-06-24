/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

// MARK: - Card Visibility Tracking (for "most visible" selection in List)

struct CardVisibility: Equatable {
    let id: String
    let minY: CGFloat
    let maxY: CGFloat
}

struct CardVisibilityKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [CardVisibility] = []
    static func reduce(value: inout [CardVisibility], nextValue: () -> [CardVisibility]) {
        value.append(contentsOf: nextValue())
    }
}

/// A reusable message card/bubble for the threaded conversation view.
/// Renders both the focused message (always expanded) and thread messages (collapsed by default).
struct MessageCardView: View {
    let messageId: String
    let viewModel: MessageDetailViewModel
    let isFocused: Bool
    let isSelected: Bool
    let onTagAction: (MessageHeader) -> Void
    /// Called when this card becomes the dominant visible expanded card.
    let onSelected: (MessageHeader) -> Void
    /// Flash to indicate a move/state change just happened.
    let shouldFlash: Bool
    let onFlashComplete: () -> Void
    var onManageLabels: ((MessageHeader) -> Void)?

    /// Live message from ViewModel — always current after mutations.
    private var message: MessageHeader {
        if isFocused {
            return viewModel.message ?? initialMessage
        }
        return viewModel.threadMessages.first(where: { $0.id == messageId }) ?? initialMessage
    }
    /// Snapshot passed at init — fallback if ViewModel hasn't loaded yet.
    private let initialMessage: MessageHeader

    @State private var expanded: Bool
    @State private var headerExpanded = false
    @State private var loadingBody = false
    @State private var flashOpacity: CGFloat = 0
    @State private var tagTapTick = 0
    @State private var tagMenuOpenTick = 0
    @AppStorage(AIService.optOutAllAIKey, store: AIService.optOutStore) private var optOutAllAI = false

    private var anyAISourceEnabled: Bool {
        (!optOutAllAI || DeviceSyncService.shared.isAutoEnabled) && AISubscriptionGate.shared.isActive
    }

    /// User labels for this card's message.
    ///
    /// Loaded ASYNCHRONOUSLY off the main thread. This was previously a computed
    /// property running a synchronous `dbPool.read` (a label JOIN) INSIDE `body`,
    /// so it re-executed on the main thread on every card re-render — and the
    /// focused card re-renders several times during a message open (body lands,
    /// AI summary/tag updates arrive). That synchronous in-`body` DB read was a
    /// contributor to the message-open render freeze. Now the read happens in a
    /// Task and the result is held in `@State`. Refreshed on (1) message identity
    /// change via `.task(id:)`, and (2) `.inboxDataDidChange`, which the label
    /// management menu posts after applying/removing a label.
    @State private var userLabels: [UserLabel] = []

    /// Async-load this card's user labels off the main thread into `userLabels`.
    private func loadUserLabels() async {
        let id = message.id
        // `[UserLabel]` is Sendable → GRDB picks the non-blocking async `read`
        // overload (the closure must return a Sendable value, or it silently
        // falls back to the synchronous, main-thread-blocking overload).
        let labels = (try? await AppDatabase.dbPool.read { db in
            try UserLabelStore.labelsForMessage(id, in: db)
        }) ?? []
        // A cancelled reload must not clobber the chips: if `.task(id:)` was torn
        // down because the card rebound to a different message mid-read, GRDB
        // throws CancellationError → `try?` yields `[]` here. Writing that would
        // wipe the chips; the replacement task writes the correct labels instead.
        guard !Task.isCancelled else { return }
        userLabels = labels
    }

    init(
        message: MessageHeader,
        viewModel: MessageDetailViewModel,
        isFocused: Bool,
        isSelected: Bool = false,
        shouldFlash: Bool = false,
        onTagAction: @escaping (MessageHeader) -> Void,
        onSelected: @escaping (MessageHeader) -> Void = { _ in },
        onFlashComplete: @escaping () -> Void = {},
        onManageLabels: ((MessageHeader) -> Void)? = nil
    ) {
        self.messageId = message.id
        self.initialMessage = message
        self.viewModel = viewModel
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.shouldFlash = shouldFlash
        self.onTagAction = onTagAction
        self.onSelected = onSelected
        self.onFlashComplete = onFlashComplete
        self.onManageLabels = onManageLabels
        self._expanded = State(initialValue: isFocused)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            // Soft flash overlay to indicate a move/state change
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .opacity(isSelected ? 1.0 : 0.4)
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named("messageList"))
                Color.clear.preference(
                    key: CardVisibilityKey.self,
                    value: expanded ? [CardVisibility(id: message.id, minY: frame.minY, maxY: frame.maxY)] : []
                )
            }
        )
        .onChange(of: shouldFlash) { _, flash in
            if flash {
                // Gentle flash: fade in white overlay then fade out
                withAnimation(.easeIn(duration: 0.3)) { flashOpacity = 0.3 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.easeOut(duration: 0.8)) { flashOpacity = 0 }
                    try? await Task.sleep(for: .milliseconds(800))
                    onFlashComplete()
                }
            }
        }
        // Load user-label chips off the main thread. `.task(id:)` reloads when
        // this card is bound to a different message; `.inboxDataDidChange`
        // (posted by UserLabelMenuView on apply/remove) refreshes chips after an
        // edit without a synchronous read in `body`.
        .task(id: message.id) { await loadUserLabels() }
        .onReceive(NotificationCenter.default.publisher(for: .inboxDataDidChange).receive(on: DispatchQueue.main)) { _ in
            Task { await loadUserLabels() }
        }
    }

    // MARK: - Collapsed State

    private var collapsedContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // Gutter indicators (hang outside text margin)
            gutterIndicators
                .padding(.top, 4)

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                // Sender + date + chevron
                HStack(alignment: .top) {
                    Text(message.from)
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .regular : .semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(MessageViewHelpers.formatShortDate(message.date))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.flagged)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }

                // To + tag
                tagRow

                // Snippet preview
                Text(message.snippet.isEmpty ? message.subject : message.snippet)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.top, 1)

                // User label chips at bottom of compressed bubble (clipped)
                let compressedLabels = userLabels
                if !compressedLabels.isEmpty {
                    let segments = UserLabelDisplaySegment.expand(compressedLabels)
                    Menu {
                        Button { onManageLabels?(message) } label: {
                            Label("Manage Labels...", systemImage: "tag")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            ForEach(segments) { segment in
                                UserLabelChip(name: segment.displayName)
                            }
                        }
                        .clipped()
                    } primaryAction: {
                        // Tap does nothing — long-press shows menu
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded() }
        .padding(.leading, 3)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Expanded State

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folder location label + collapse chevron (thread cards only, not focused)
            if !isFocused {
                HStack {
                    Spacer()
                    Text("In \(message.folderPath)")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded() }

                Divider()
                    .padding(.leading, 17)
                    .padding(.trailing)
                    .padding(.bottom, 4)
            }

            // Header section — indicators in gutter, text at standard margin
            HStack(alignment: .top, spacing: 0) {
                gutterIndicators
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    if headerExpanded {
                        expandedHeaderDetails
                    } else {
                        collapsedHeaderDetails
                    }
                }
                .padding(.trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                headerExpanded.toggle()
            }
            .padding(.leading, 3)

            // Subject (aligned with header text: 3pt leading + 12pt gutter + 2pt = 17pt)
            // Long-press opens label management (Menu pattern, same as actionTagBadge)
            Menu {
                Button { onManageLabels?(message) } label: {
                    Label("Manage Labels...", systemImage: "tag")
                }
            } label: {
                Text(message.subject)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
            } primaryAction: {
                // Tap does nothing — long-press shows menu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 17)
            .padding(.trailing)
            .padding(.top, 6)
            .popoverTip(UserLabelCardManageTip(), arrowEdge: .bottom)

            // User label chips (below subject, above separator — expanded: wrapping)
            let expandedLabels = userLabels
            if !expandedLabels.isEmpty {
                let segments = UserLabelDisplaySegment.expand(expandedLabels)
                Menu {
                    Button { onManageLabels?(message) } label: {
                        Label("Manage Labels...", systemImage: "tag")
                    }
                } label: {
                    FlowLayout(hSpacing: 4, vSpacing: 2) {
                        ForEach(segments) { segment in
                            UserLabelChip(name: segment.displayName)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } primaryAction: {
                    // Tap does nothing — long-press shows menu
                }
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.top, 4)
            }

            // Separator (aligned with text content)
            Divider()
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.vertical, 10)

            // AI Summary
            SummaryBubbleView(message: message)
                .padding(.bottom, 8)

            // Body
            bodyContent

            // Attachments
            attachmentContent
        }
        .padding(.top, 8)
    }

    // MARK: - Collapsed Header Details (compact: sender + date + To + tag)

    private var collapsedHeaderDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sender + date
            HStack(alignment: .top) {
                Text(message.from)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(MessageViewHelpers.formatShortDate(message.date))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.flagged)
                }
            }

            // To + tag
            tagRow
        }
    }

    // MARK: - Expanded Header Details (full: sender, address, date, To/Cc/Bcc, tag)

    private var expandedHeaderDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sender + tag + flag (top row)
            HStack(alignment: .top) {
                Text(message.from)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // Tag in top-right (inbox only)
                if message.isInInbox {
                    if let tag = message.actionTag {
                        actionTagBadge(tag)
                    } else if anyAISourceEnabled {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                }
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.flagged)
                }
            }

            Text(message.fromAddress)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(MessageViewHelpers.formatExpandedDate(message.date))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Text("To: \(message.to)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !message.cc.isEmpty {
                Text("Cc: \(message.cc)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !message.bcc.isEmpty {
                Text("Bcc: \(message.bcc)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let replyTo = message.replyTo,
               !replyTo.isEmpty,
               replyTo.lowercased() != message.fromAddress.lowercased() {
                Text("Reply-To: \(replyTo)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared Components

    /// Vertical indicators column — unread dot, reply/forward, attachment.
    /// Positioned in the left gutter, outside the text content margin.
    private var gutterIndicators: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(message.isRead ? Color.clear : Theme.unreadDot)
                .frame(width: 8, height: 8)
            MessageIndicators.replyForwardIcon(isReplied: message.isReplied, isForwarded: message.isForwarded, size: 9)
            Image(systemName: "paperclip")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textSecondary)
                .opacity(message.hasAttachments ? 1 : 0)
        }
        .frame(width: 12)
    }

    /// Builds the compressed recipient label, e.g. "To: Alice, Bob" or "To/cc: Alice, Bob, Carol".
    /// Includes cc and bcc recipients (without labeling bcc separately).
    private var compressedRecipientLabel: String {
        let hasCcOrBcc = !message.cc.isEmpty || !message.bcc.isEmpty
        let prefix = hasCcOrBcc ? "To/cc:" : "To:"
        var names = MessageViewHelpers.extractNames(message.to)
        if !message.cc.isEmpty {
            let ccNames = MessageViewHelpers.extractNames(message.cc)
            names += names.isEmpty ? ccNames : ", \(ccNames)"
        }
        if !message.bcc.isEmpty {
            let bccNames = MessageViewHelpers.extractNames(message.bcc)
            names += names.isEmpty ? bccNames : ", \(bccNames)"
        }
        return "\(prefix) \(names)"
    }

    private var tagRow: some View {
        HStack(alignment: .center) {
            Text(compressedRecipientLabel)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            // Only show action tags for inbox messages
            if message.isInInbox {
                if let tag = message.actionTag {
                    Spacer(minLength: 4)
                    actionTagBadge(tag)
                } else if anyAISourceEnabled {
                    Spacer(minLength: 4)
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private func actionTagBadge(_ tag: ActionTag) -> some View {
        Menu {
            Button { viewModel.applyManualTag(message, tag: .reply) } label: {
                Label("Tag as Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button { viewModel.applyManualTag(message, tag: ActionTag.none) } label: {
                Label("Tag as None", systemImage: "tag.slash")
            }
            Button { viewModel.applyManualTag(message, tag: .archive) } label: {
                Label("Tag as Archive", systemImage: "archivebox")
            }
            Button { viewModel.applyManualTag(message, tag: .delete) } label: {
                Label("Tag as Delete", systemImage: "trash")
            }
        } label: {
            Text(tag.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .actionTagButtonStyle(color: Theme.tagColor(tag))
                .aiWorkingShimmer(active: MessageViewHelpers.showShimmer(message))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .sensoryFeedback(.impact(weight: .light), trigger: tagTapTick)
                .sensoryFeedback(.impact(weight: .medium), trigger: tagMenuOpenTick)
        } primaryAction: {
            tagTapTick &+= 1
            onTagAction(message)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in tagMenuOpenTick &+= 1 }
        )
        .popoverTip(TagTeachingTip(), arrowEdge: .top)
    }

    // MARK: - Body Content

    @ViewBuilder
    private var bodyContent: some View {
        if isFocused {
            // Focused card reads from viewModel.messageBody (loaded by loadBody)
            if let body = viewModel.messageBody {
                if let html = body.htmlContent, !html.isEmpty {
                    AutoSizingHTMLView(html: html, headerId: message.id)
                } else {
                    Text("This message has no content.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Symmetric 40pt above and below so the no-content line
                        // (e.g. a DMARC report that is just an attachment) reads
                        // as vertically centered rather than top-heavy.
                        .padding(.vertical, 40)
                }
            } else if viewModel.isLoading {
                ProgressView("Loading message...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                    .padding(.bottom, 80)
            } else if viewModel.error != nil {
                Text(DebugModeManager.isLoggingEnabled() ? viewModel.error! : "Unable to load message. Pull to retry.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                // Body not yet loaded (loadBody task pending or cancelled).
                // Show spinner as a safety net so the user never sees a blank body.
                ProgressView("Loading message...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                    .padding(.bottom, 80)
            }
        } else {
            // Thread card reads from viewModel.bodyFor() (loaded on demand)
            if let body = viewModel.bodyFor(message.id) {
                if let html = body.htmlContent, !html.isEmpty {
                    AutoSizingHTMLView(html: html, headerId: message.id)
                } else {
                    Text("This message has no content.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else if loadingBody {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.leading, 17)
                .padding(.trailing)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Attachment Content

    @ViewBuilder
    private var attachmentContent: some View {
        if isFocused {
            if let body = viewModel.messageBody, !body.attachments.isEmpty {
                AttachmentListView(message: message, attachments: body.attachments, bodyHtml: body.htmlContent)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            } else if message.hasAttachments && viewModel.messageBody == nil {
                AttachmentBanner()
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            }
        } else {
            if let body = viewModel.bodyFor(message.id), !body.attachments.isEmpty {
                AttachmentListView(message: message, attachments: body.attachments, bodyHtml: body.htmlContent)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Tag Teaching Context Menu

    // MARK: - Toggle

    private func toggleExpanded() {
        // No withAnimation — SwiftUI List computes new row heights and repositions
        // rows immediately, then plays the content transition at the new position.
        // This causes a "fly to final position then animate" artifact. Snapping
        // avoids it entirely and matches standard iOS mail expand/collapse behavior.
        expanded.toggle()
        if expanded {
            onSelected(message)
            viewModel.markReadIfNeeded(message)

            // Load body on demand for non-focused cards
            if !isFocused && viewModel.bodyFor(message.id) == nil && !loadingBody {
                loadingBody = true
                Task {
                    await viewModel.loadThreadMessageBody(message)
                    loadingBody = false
                }
            }
        } else if !isFocused, let focusedMsg = viewModel.message {
            onSelected(focusedMsg)
        }
    }
}

