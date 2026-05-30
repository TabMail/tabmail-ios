/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Types of AI-generated or community-driven content that can be reported.
enum ReportContentType: String, Sendable {
    case chatMessage
    case summary
    case suggestedReply
    case communityTemplate
    case subscriptionMigration
    /// BYOK smoke-test diagnostic — long-press on "Test API Connectivity"
    /// in API Keys → opens the standard report sheet with the per-(tier,
    /// model, profile) stage list as the report body. Backend allow-list
    /// must include `byokDiagnostic` for the submission to succeed.
    case byokDiagnostic
}

/// Report categories shown to the user.
enum ReportCategory: String, CaseIterable, Sendable {
    case offensive
    case inaccurate
    case other

    var displayName: String {
        switch self {
        case .offensive: "Offensive"
        case .inaccurate: "Inaccurate"
        case .other: "Other"
        }
    }
}

/// Service for reporting objectionable AI-generated content.
/// Required by App Store Guidelines 1.2, 4.7.1.
enum ReportConcernService {
    @discardableResult
    static func report(
        contentType: ReportContentType,
        content: String,
        category: ReportCategory? = nil,
        reason: String? = nil
    ) async -> Bool {
        let success = await BackendClient().reportConcern(
            contentType: contentType.rawValue,
            content: content,
            category: category?.rawValue,
            reason: reason
        )
        print("[ReportConcern] \(contentType.rawValue): \(success ? "submitted" : "failed")")
        return success
    }
}
