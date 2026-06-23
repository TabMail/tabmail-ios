/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Speech
import AVFoundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var animate: Bool = false
    /// Non-nil when this message is a confirmation card (archive/delete).
    var actionConfirmation: AgentToolRouter.ActionConfirmation?

    enum Role {
        case user
        case agent
        case warning
    }
}

struct AgentChatSheet: View {
    let message: MessageHeader?
    @State private var inputText = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var conversationId: String?
    @State private var speechRecognizer = SpeechRecognizer()
    @Environment(\.dismiss) private var dismiss
    private let backendClient = AccountManager.shared.backendClient

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Context card (only shown when a message is provided)
                if let message {
                    HStack {
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.subject)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(message.from)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Palette.boxBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // Chat messages
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(chatMessages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if isLoading {
                            HStack {
                                ProgressView()
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)

                Divider()

                // Input bar
                HStack(spacing: 8) {
                    // Mic button for voice dictation
                    Button {
                        if speechRecognizer.isRecording {
                            speechRecognizer.stop()
                        } else {
                            let prefix = inputText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : inputText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                            speechRecognizer.start { transcript in
                                inputText = prefix + transcript
                            }
                        }
                    } label: {
                        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                            .font(.title3)
                            .foregroundStyle(speechRecognizer.isRecording ? .red : Theme.accent)
                    }
                    .disabled(isLoading)

                    TextField("Type or speak...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)

                    Button {
                        speechRecognizer.stop()
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Palette.previewPaneBg)
            .navigationTitle("TabMail Agent")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .dismissKeyboardOnTap()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        chatMessages.append(ChatMessage(role: .user, content: text, timestamp: Date()))
        inputText = ""
        isLoading = true

        Task {
            do {
                let messageContext = message.map { msg in
                    BackendClient.MessageContext(
                        messageId: msg.messageId,
                        subject: msg.subject,
                        from: msg.from,
                        snippet: msg.snippet
                    )
                }
                let request = BackendClient.ChatRequest(
                    message: text,
                    context: messageContext,
                    conversationId: conversationId
                )
                let response = try await backendClient.sendChat(request)
                conversationId = response.conversationId
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: response.reply,
                    timestamp: Date()
                ))
            } catch {
                chatMessages.append(ChatMessage(
                    role: .agent,
                    content: "Sorry, I couldn't connect to the server. (\(error.localizedDescription))",
                    timestamp: Date()
                ))
            }
            isLoading = false
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var onLineRevealed: (() -> Void)?

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            if let confirmation = message.actionConfirmation {
                // Confirmation card (archive/delete) — full width, left-aligned
                ActionConfirmationCard(confirmation: confirmation)
            } else if message.role == .warning {
                // Warning messages: orange-styled banner (e.g. subscription required)
                WarningBubble(content: message.content)
            } else if message.role == .agent {
                // Agent messages: flat/transparent, left-aligned, wide
                // NOTE: Do NOT apply .foregroundStyle here — it overrides link/pill colors.
                // MarkdownChatText handles its own text color internally.
                MarkdownChatText(content: message.content, animate: message.animate, onLineRevealed: onLineRevealed)
                    .tint(Theme.accent)
                    .reportConcern(contentType: .chatMessage, content: message.content)
                Spacer(minLength: 20)
            } else {
                // User messages: right-aligned bubble with accent background
                Text(message.content)
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .padding(10)
                    .background(Theme.accent)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - Warning Bubble

/// Warning banner with orange styling for subscription/quota errors.
/// "TabMail Account" is rendered as a tappable link that deep-links to the account dashboard.
/// Tapping the banner navigates to the TabMail Account screen.
struct WarningBubble: View {
    let content: String

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .navigateToAccount, object: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.archive)
                linkedText
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.archive.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var linkedText: some View {
        let linkTarget = "TabMail Account"
        if let range = content.range(of: linkTarget) {
            let before = String(content[content.startIndex..<range.lowerBound])
            let after = String(content[range.upperBound..<content.endIndex])
            return Text("\(Text(before).foregroundStyle(Palette.textColor))\(Text(linkTarget).foregroundStyle(Palette.link).underline())\(Text(after).foregroundStyle(Palette.textColor))")
                .font(.subheadline)
        } else {
            return Text(content)
                .font(.subheadline)
                .foregroundStyle(Palette.textColor)
        }
    }
}

// MARK: - Action Confirmation Card

/// Inline confirmation card for actions requiring user approval (ADR-IOS-024).
/// Supports email actions (archive/delete), contact actions (edit/delete),
/// and calendar event actions (create/edit/delete).
/// Matches ComposeView's `suggestionBubble` styling with detail rows.
struct ActionConfirmationCard: View {
    let confirmation: AgentToolRouter.ActionConfirmation

    private var responded: Bool { confirmation.responseState.responded }
    private var accepted: Bool { confirmation.responseState.accepted }
    /// The card flips to a red/⚠ failed state when the tool sets
    /// `failureReason` after a permanent provider/queue failure. Only
    /// meaningful when accepted is true — declined cards stay "Cancelled".
    private var failureReason: String? { confirmation.responseState.failureReason }
    private var failed: Bool { accepted && failureReason != nil }

    private var isContactAction: Bool {
        confirmation.action == .contactEdit || confirmation.action == .contactDelete
    }

    private var isCalendarAction: Bool {
        confirmation.action == .calendarEventCreate || confirmation.action == .calendarEventEdit || confirmation.action == .calendarEventDelete
    }

    private var isTemplateAction: Bool {
        confirmation.action == .templateCreate || confirmation.action == .templateEdit || confirmation.action == .templateDelete || confirmation.action == .templateShare || confirmation.action == .templateDownload
    }

    private var accentColor: Color {
        // Failure trumps the action's normal tint — the user needs to see the
        // card didn't go through.
        if failed { return .orange }
        switch confirmation.action {
        case .archive, .contactEdit, .calendarEventCreate, .calendarEventEdit, .templateCreate, .templateEdit, .templateShare, .templateDownload: return Theme.accent
        case .delete, .contactDelete, .calendarEventDelete, .templateDelete: return .red
        }
    }

    private var actionVerb: String {
        switch confirmation.action {
        case .archive: return "Archive"
        case .delete, .contactDelete, .calendarEventDelete: return "Delete"
        case .contactEdit, .calendarEventEdit: return "Edit"
        case .calendarEventCreate, .templateCreate: return "Create"
        case .templateEdit: return "Edit"
        case .templateDelete: return "Delete"
        case .templateShare: return "Share"
        case .templateDownload: return "Download"
        }
    }

    private var pastTenseVerb: String {
        switch confirmation.action {
        case .archive: return "Archived"
        case .delete, .contactDelete, .calendarEventDelete, .templateDelete: return "Deleted"
        case .contactEdit, .calendarEventEdit, .templateEdit: return "Edited"
        case .calendarEventCreate, .templateCreate: return "Created"
        case .templateShare: return "Shared"
        case .templateDownload: return "Downloaded"
        }
    }

    private var actionIcon: String {
        switch confirmation.action {
        case .archive: return "archivebox"
        case .delete: return "trash"
        case .contactEdit: return "pencil"
        case .contactDelete: return "person.badge.minus"
        case .calendarEventCreate: return "calendar.badge.plus"
        case .calendarEventEdit: return "calendar.badge.clock"
        case .calendarEventDelete: return "calendar.badge.minus"
        case .templateCreate: return "doc.badge.plus"
        case .templateEdit: return "doc.badge.gearshape"
        case .templateDelete: return "doc.badge.minus"
        case .templateShare: return "square.and.arrow.up"
        case .templateDownload: return "arrow.down.circle"
        }
    }

    private var itemNoun: String {
        if isTemplateAction { return "template" }
        if isCalendarAction { return "event" }
        if isContactAction { return "contact" }
        return "email"
    }

    private var itemCount: Int {
        if isTemplateAction { return confirmation.templates.count }
        if isCalendarAction { return confirmation.calendarEvents.count }
        if isContactAction { return confirmation.contacts.count }
        return confirmation.emails.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: actionIcon)
                    .font(.caption)
                    .foregroundStyle(responded ? Theme.textSecondary : accentColor)
                Text(headerText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(responded ? Theme.textSecondary : Theme.textPrimary)
            }

            // Detail rows
            if isCalendarAction {
                VStack(spacing: 0) {
                    ForEach(Array(confirmation.calendarEvents.enumerated()), id: \.offset) { index, event in
                        if index > 0 { Divider() }
                        calendarEventRow(event)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isTemplateAction {
                VStack(spacing: 0) {
                    ForEach(Array(confirmation.templates.enumerated()), id: \.element.templateId) { index, template in
                        if index > 0 { Divider() }
                        templateRow(template)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isContactAction {
                VStack(spacing: 0) {
                    ForEach(Array(confirmation.contacts.enumerated()), id: \.element.contactId) { index, contact in
                        if index > 0 { Divider() }
                        contactRow(contact)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(confirmation.emails.enumerated()), id: \.element.numericId) { index, email in
                        if index > 0 { Divider() }
                        emailRow(email)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Action buttons or result
            if responded {
                if failed, let reason = failureReason {
                    // Failure detail — inline ⚠ + reason. The reason comes
                    // straight from the provider/queue failure (e.g. "Event …
                    // is not recurring; can't split.").
                    Label {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                HStack(spacing: 12) {
                    Spacer()
                    Button {
                        confirmation.responseState.responded = true
                        confirmation.responseState.accepted = false
                        confirmation.onRespond(false)
                    } label: {
                        Text("Decline")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmation.responseState.responded = true
                        confirmation.responseState.accepted = true
                        confirmation.onRespond(true)
                    } label: {
                        Text(actionVerb)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(accentColor.opacity(responded ? 0.04 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(responded ? 0.1 : 0.2), lineWidth: 1)
        )
    }

    private var headerText: String {
        if responded {
            if failed {
                return itemCount == 1
                    ? "Failed to \(actionVerb.lowercased()) this \(itemNoun)"
                    : "Failed to \(actionVerb.lowercased()) \(itemCount) \(itemNoun)s"
            }
            if accepted {
                return itemCount == 1
                    ? "\(pastTenseVerb) this \(itemNoun)"
                    : "\(pastTenseVerb) \(itemCount) \(itemNoun)s"
            } else {
                return "Cancelled"
            }
        }
        return itemCount == 1
            ? "\(actionVerb) this \(itemNoun)?"
            : "\(actionVerb) \(itemCount) \(itemNoun)s?"
    }

    private var resultText: String {
        if accepted {
            return itemCount == 1
                ? "\(pastTenseVerb) 1 \(itemNoun)."
                : "\(pastTenseVerb) \(itemCount) \(itemNoun)s."
        }
        return "Action cancelled by user."
    }

    @ViewBuilder
    private func emailRow(_ email: AgentToolRouter.ActionConfirmation.EmailDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.caption2)
                .foregroundStyle(accentColor.opacity(0.6))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(email.subject)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(responded ? Theme.textSecondary : Theme.textPrimary)
                HStack(spacing: 4) {
                    Text(email.from)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let date = email.date {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        Text(date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func contactRow(_ contact: AgentToolRouter.ActionConfirmation.ContactDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.caption2)
                .foregroundStyle(accentColor.opacity(0.6))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(responded ? Theme.textSecondary : Theme.textPrimary)
                if !contact.email.isEmpty {
                    Text(contact.email)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !contact.changes.isEmpty {
                    ForEach(contact.changes, id: \.self) { change in
                        Text(change)
                            .font(.caption2)
                            .foregroundStyle(accentColor.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func calendarEventRow(_ event: AgentToolRouter.ActionConfirmation.CalendarEventDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.caption2)
                .foregroundStyle(accentColor.opacity(0.6))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(responded ? Theme.textSecondary : Theme.textPrimary)
                Text(formatEventTime(event))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                // Always-visible timezone row so the user can verify which zone
                // the agent interpreted naive datetimes in before accepting.
                Label {
                    Text(eventTimezoneLabel(event))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                if !event.attendees.isEmpty {
                    Label {
                        Text("\(event.attendees.count) attendee\(event.attendees.count == 1 ? "" : "s") will be invited")
                            .font(.caption2)
                            .foregroundStyle(accentColor)
                    } icon: {
                        Image(systemName: "person.2")
                            .font(.caption2)
                            .foregroundStyle(accentColor.opacity(0.6))
                    }
                    ForEach(event.attendees.prefix(5), id: \.self) { attendee in
                        Text(attendee)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .padding(.leading, 18)
                    }
                    if event.attendees.count > 5 {
                        Text("+\(event.attendees.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                            .padding(.leading, 18)
                    }
                }
                if !event.changes.isEmpty {
                    ForEach(event.changes, id: \.self) { change in
                        Text(change)
                            .font(.caption2)
                            .foregroundStyle(accentColor.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Label {
                        Text(notes)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func templateRow(_ template: AgentToolRouter.ActionConfirmation.TemplateDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(accentColor.opacity(0.6))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(responded ? Theme.textSecondary : Theme.textPrimary)
                if template.instructionCount > 0 {
                    Text("\(template.instructionCount) instruction\(template.instructionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !template.exampleReplyPreview.isEmpty {
                    Text(template.exampleReplyPreview)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !template.changes.isEmpty {
                    ForEach(template.changes, id: \.self) { change in
                        Text(change)
                            .font(.caption2)
                            .foregroundStyle(accentColor.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    /// Resolved timezone label for the event row — always shows IANA id so the
    /// user can verify the zone before accepting (especially when the agent
    /// silently fell back to device local).
    private func eventTimezoneLabel(_ event: AgentToolRouter.ActionConfirmation.CalendarEventDetail) -> String {
        let tz: TimeZone = if let tzId = event.timeZoneId, let resolved = TimeZone(identifier: tzId) {
            resolved
        } else {
            .current
        }
        let abbr = tz.abbreviation() ?? tz.identifier
        // If abbreviation == identifier (rare), don't duplicate.
        if abbr == tz.identifier { return tz.identifier }
        return "\(abbr) (\(tz.identifier))"
    }

    private func formatEventTime(_ event: AgentToolRouter.ActionConfirmation.CalendarEventDetail) -> String {
        // The dedicated 🌐 row beneath this label carries the timezone — keep
        // the time string itself clean so we don't render the zone twice.
        let tz: TimeZone = if let tzId = event.timeZoneId, let resolved = TimeZone(identifier: tzId) {
            resolved
        } else {
            .current
        }

        if event.isAllDay {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            fmt.timeZone = tz
            return "\(fmt.string(from: event.startDate)) (all day)"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.timeZone = tz
        let endFmt = DateFormatter()
        endFmt.timeStyle = .short
        endFmt.timeZone = tz
        return "\(fmt.string(from: event.startDate)) – \(endFmt.string(from: event.endDate))"
    }
}
