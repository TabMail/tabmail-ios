/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UserNotifications
@testable import TabMail

/// Coverage for `applyPassiveSettings` — the helper that all NSE
/// passive-delivery exits flow through. Replaces the prior
/// "always overwrite to 'Inbox updated'" behaviour with pass-through
/// of the worker's pre-populated `aps.alert`.
@Suite("Passive notification content helper")
struct PassiveContentTests {

    private func workerAlert(title: String = "New email - Alice", body: String = "Re: Budget") -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.interruptionLevel = .active
        c.sound = .default
        return c
    }

    @Test("No override — preserves worker's pre-populated title and body")
    func passThroughPreservesWorkerPayload() {
        let c = workerAlert()
        applyPassiveSettings(c)
        #expect(c.title == "New email - Alice")
        #expect(c.body == "Re: Budget")
    }

    @Test("No override — empty worker alert stays empty (does not invent text)")
    func passThroughOnEmptyAlertStaysEmpty() {
        let c = UNMutableNotificationContent()
        applyPassiveSettings(c)
        #expect(c.title == "")
        #expect(c.body == "")
    }

    @Test("overrideTitle — replaces title, preserves worker body")
    func overrideTitleOnly() {
        let c = workerAlert()
        applyPassiveSettings(c, overrideTitle: "Connection to alice@example.com lost")
        #expect(c.title == "Connection to alice@example.com lost")
        #expect(c.body == "Re: Budget")
    }

    @Test("overrideBody — replaces body, preserves worker title")
    func overrideBodyOnly() {
        let c = workerAlert()
        applyPassiveSettings(c, overrideBody: "Open TabMail to reconnect")
        #expect(c.title == "New email - Alice")
        #expect(c.body == "Open TabMail to reconnect")
    }

    @Test("Both overrides — replaces title and body together")
    func overrideTitleAndBody() {
        let c = workerAlert()
        applyPassiveSettings(
            c,
            overrideTitle: "TabMail",
            overrideBody: "Restored push notification connection for alice@example.com"
        )
        #expect(c.title == "TabMail")
        #expect(c.body == "Restored push notification connection for alice@example.com")
    }

    @Test("Always normalises to passive interruption level")
    func interruptionLevelIsPassive() {
        let c = workerAlert()
        #expect(c.interruptionLevel == .active)
        applyPassiveSettings(c)
        #expect(c.interruptionLevel == .passive)
    }

    @Test("Always clears sound to nil")
    func soundIsCleared() {
        let c = workerAlert()
        #expect(c.sound != nil)
        applyPassiveSettings(c)
        #expect(c.sound == nil)
    }

    @Test("Passive fallback removes email actions and their durable identity")
    func actionMetadataIsCleared() {
        let c = workerAlert()
        c.categoryIdentifier = "EMAIL_TAG_DELETE"
        c.userInfo = [
            "messageId": "provider-resource-id",
            EmailNotificationBuilder.actionMessageIdUserInfoKey: "action@example.com",
        ]

        applyPassiveSettings(c)

        #expect(c.categoryIdentifier.isEmpty)
        #expect(c.userInfo["messageId"] as? String == "provider-resource-id")
        #expect(c.userInfo[EmailNotificationBuilder.actionMessageIdUserInfoKey] == nil)
    }

    @Test("Override + passive normalisation happen together")
    func overrideAndNormalisationCombined() {
        let c = workerAlert()
        applyPassiveSettings(c, overrideTitle: "Inbox updated")
        #expect(c.title == "Inbox updated")
        #expect(c.body == "Re: Budget")
        #expect(c.interruptionLevel == .passive)
        #expect(c.sound == nil)
    }
}
