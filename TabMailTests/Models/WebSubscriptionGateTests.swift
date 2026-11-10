/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A subscription bought on the website is managed only there: while it has
/// not ended, the plan picker offers no purchase and shows one plain sentence
/// instead (ADR-IOS-105).
///
/// Every case is a `/whoami` body decoded through the real `AccountInfo`
/// parser. The server sends `subscription_provider` and `subscription_status`
/// while the subscription grants access; the no-access cases (unpaid,
/// incomplete, paused) are written in the shape the server sends once it also
/// sends those two fields without access, which needs no app change. Times are
/// relative to now.
@Suite("Plan picker: no purchase while a web subscription is live")
struct WebSubscriptionGateTests {

    struct Body: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let json: [String: String]
        let live: Bool
    }

    private static let inAMonth = Int(Date().addingTimeInterval(30 * 86_400).timeIntervalSince1970)

    /// The fields an active subscription's body carries, as JSON literals.
    private static func withAccess(provider: String, status: String?, tier: String = "Basic",
                                   pendingCancellation: String = "null") -> [String: String] {
        var json = [
            "logged_in": "true",
            "has_subscription": "true",
            "plan_tier": "\"\(tier)\"",
            "subscription_provider": "\"\(provider)\"",
            "trial": "null",
            "pending_cancellation": pendingCancellation,
            "pending_downgrade": "null",
        ]
        json["subscription_status"] = status.map { "\"\($0)\"" } ?? "null"
        return json
    }

    /// A body without access that still names the web subscription.
    private static func withoutAccess(status: String) -> [String: String] {
        [
            "logged_in": "true",
            "has_subscription": "false",
            "subscription_provider": "\"stripe\"",
            "subscription_status": "\"\(status)\"",
        ]
    }

    static let bodies: [Body] = [
        Body(testDescription: "web, active", json: withAccess(provider: "stripe", status: "active"), live: true),
        Body(testDescription: "web, trialing", json: withAccess(provider: "stripe", status: "trialing"), live: true),
        Body(testDescription: "web, past due (still has access)", json: withAccess(provider: "stripe", status: "past_due"), live: true),
        Body(testDescription: "web, cancelled but not yet ended",
             json: withAccess(provider: "stripe", status: "active",
                              pendingCancellation: #"{"cancel_at":\#(inAMonth)}"#),
             live: true),
        Body(testDescription: "web, unpaid (no access)", json: withoutAccess(status: "unpaid"), live: true),
        Body(testDescription: "web, incomplete (no access)", json: withoutAccess(status: "incomplete"), live: true),
        Body(testDescription: "web, paused (no access)", json: withoutAccess(status: "paused"), live: true),
        Body(testDescription: "web, status null", json: withAccess(provider: "stripe", status: nil), live: true),
        Body(testDescription: "web, status key absent",
             json: withAccess(provider: "stripe", status: "active").filter { $0.key != "subscription_status" },
             live: true),
        Body(testDescription: "web, ended", json: withoutAccess(status: "canceled"), live: false),
        Body(testDescription: "web, never completed", json: withoutAccess(status: "incomplete_expired"), live: false),
        Body(testDescription: "Apple, active", json: withAccess(provider: "apple", status: "active"), live: false),
        Body(testDescription: "signup trial",
             json: withAccess(provider: "signup", status: "trialing", tier: "Trial")
                .merging(["trial": #"{"is_trial":true,"trial_end":\#(inAMonth)}"#]) { $1 },
             live: false),
        Body(testDescription: "no subscription",
             json: ["logged_in": "true", "has_subscription": "false"], live: false),
        Body(testDescription: "signup trial ended",
             json: ["logged_in": "true", "has_subscription": "false", "trial": "null"], live: false),
    ]

    private static func decode(_ json: [String: String]) throws -> AccountInfo {
        let text = "{" + json.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
        return try JSONDecoder().decode(AccountInfo.self, from: Data(text.utf8))
    }

    @Test("A web subscription is live until it has ended, whatever its access", arguments: bodies)
    func liveness(_ body: Body) throws {
        let info = try Self.decode(body.json)
        #expect(info.hasLiveWebSubscription == body.live)
    }

    @Test("The plan picker replaces its purchase options with one plain sentence exactly when it is live",
          arguments: bodies)
    func pickerNote(_ body: Body) throws {
        let note = PlanPickerView.webManagedNote(for: try Self.decode(body.json))
        if body.live {
            #expect(note == "Your subscription is managed on tabmail.ai, so it can't be changed in this app. For help, contact support.")
        } else {
            #expect(note == nil, "the plans must stay on sale")
        }
    }

    @Test("Before the account has loaded, the plans stay on sale")
    func notLoadedYet() {
        #expect(PlanPickerView.webManagedNote(for: nil) == nil)
    }
}
