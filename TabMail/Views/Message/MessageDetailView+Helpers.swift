/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import SwiftMail

// MARK: - Shared helpers used by MessageDetailView and MessageCardView

enum MessageViewHelpers {
    /// Short date: time if today, "Yesterday", or "MMM d"
    static func formatShortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            if !calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
                formatter.dateFormat = "MMM d, yyyy"
            } else {
                formatter.dateFormat = "MMM d"
            }
            return formatter.string(from: date)
        }
    }

    /// Full date + time for expanded header (e.g., "Feb 15, 2026 at 7:09 PM")
    static func formatExpandedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Display names from an address field, read with SwiftMail's parser so
    /// quoted names keep their commas and lose their escapes.
    /// `"Doe, John" <john@example.com>, jane@example.com` → `Doe, John, jane@example.com`
    static func extractNames(_ raw: String) -> String {
        AddressParser.parseAddressList(raw).flatMap { entry -> [String] in
            switch entry {
                case .mailbox(let mailbox): return [displayName(mailbox)]
                case .group(_, let members): return members.map(displayName)
                case .invalid(let text): return [text]
            }
        }.joined(separator: ", ")
    }

    private static func displayName(_ mailbox: SwiftMail.EmailAddress) -> String {
        guard let name = mailbox.name, !name.isEmpty else { return mailbox.address }
        return name
    }

    /// Shimmer effect for WIP tag (tag assigned but reply not yet generated)
    static func showShimmer(_ message: MessageHeader) -> Bool {
        message.actionTag != nil && message.cachedReply == nil && AISubscriptionGate.shared.isActive
    }
}

// MARK: - Attachment Banner

struct AttachmentBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("This message has attachments")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

