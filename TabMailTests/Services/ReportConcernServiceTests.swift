/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ReportContentType")
struct ReportContentTypeTests {

    @Test("All cases have raw values")
    func rawValues() {
        #expect(ReportContentType.chatMessage.rawValue == "chatMessage")
        #expect(ReportContentType.summary.rawValue == "summary")
        #expect(ReportContentType.suggestedReply.rawValue == "suggestedReply")
        #expect(ReportContentType.communityTemplate.rawValue == "communityTemplate")
        #expect(ReportContentType.subscriptionMigration.rawValue == "subscriptionMigration")
    }

    @Test("Init from raw value")
    func initFromRawValue() {
        #expect(ReportContentType(rawValue: "chatMessage") == .chatMessage)
        #expect(ReportContentType(rawValue: "summary") == .summary)
        #expect(ReportContentType(rawValue: "invalid") == nil)
    }
}

@Suite("ReportCategory")
struct ReportCategoryTests {

    @Test("Display names are correct")
    func displayNames() {
        #expect(ReportCategory.offensive.displayName == "Offensive")
        #expect(ReportCategory.inaccurate.displayName == "Inaccurate")
        #expect(ReportCategory.other.displayName == "Other")
    }

    @Test("Raw values are correct")
    func rawValues() {
        #expect(ReportCategory.offensive.rawValue == "offensive")
        #expect(ReportCategory.inaccurate.rawValue == "inaccurate")
        #expect(ReportCategory.other.rawValue == "other")
    }

    @Test("CaseIterable includes all cases")
    func allCases() {
        #expect(ReportCategory.allCases.count == 3)
        #expect(ReportCategory.allCases.contains(.offensive))
        #expect(ReportCategory.allCases.contains(.inaccurate))
        #expect(ReportCategory.allCases.contains(.other))
    }

    @Test("Init from raw value")
    func initFromRawValue() {
        #expect(ReportCategory(rawValue: "offensive") == .offensive)
        #expect(ReportCategory(rawValue: "invalid") == nil)
    }
}
