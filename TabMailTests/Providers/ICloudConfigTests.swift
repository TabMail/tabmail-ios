/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ICloudConfig")
struct ICloudConfigTests {

    @Test("IMAP settings")
    func imapSettings() {
        #expect(ICloudConfig.imapHost == "imap.mail.me.com")
        #expect(ICloudConfig.imapPort == 993)
    }

    @Test("SMTP settings")
    func smtpSettings() {
        #expect(ICloudConfig.smtpHost == "smtp.mail.me.com")
        #expect(ICloudConfig.smtpPort == 587)
    }

    @Test("CalDAV URL")
    func caldavURL() {
        #expect(ICloudConfig.caldavURL == "https://caldav.icloud.com")
    }

    @Test("isAppleDomain for icloud.com")
    func icloudDomain() {
        #expect(ICloudConfig.isAppleDomain("user@icloud.com") == true)
    }

    @Test("isAppleDomain for me.com")
    func meDomain() {
        #expect(ICloudConfig.isAppleDomain("user@me.com") == true)
    }

    @Test("isAppleDomain for mac.com")
    func macDomain() {
        #expect(ICloudConfig.isAppleDomain("user@mac.com") == true)
    }

    @Test("isAppleDomain for privaterelay.appleid.com")
    func privateRelayDomain() {
        #expect(ICloudConfig.isAppleDomain("user@abc.privaterelay.appleid.com") == true)
    }

    @Test("isAppleDomain returns false for gmail")
    func notAppleDomain() {
        #expect(ICloudConfig.isAppleDomain("user@gmail.com") == false)
    }

    @Test("isAppleDomain is case-insensitive")
    func caseInsensitive() {
        #expect(ICloudConfig.isAppleDomain("user@ICLOUD.COM") == true)
        #expect(ICloudConfig.isAppleDomain("user@Me.Com") == true)
    }

    @Test("isAppleDomain handles missing @")
    func missingAt() {
        #expect(ICloudConfig.isAppleDomain("noemail") == false)
    }

    @Test("domains list has 3 entries")
    func domainsList() {
        #expect(ICloudConfig.domains.count == 3)
    }
}
