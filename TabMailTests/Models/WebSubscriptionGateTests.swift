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
        Body(testDescription: "web, status the app does not know",
             json: withoutAccess(status: "some_future_status"), live: true),
        // The server sends an ended subscription as a plain no-subscription
        // body (the row below); these two pin the ended set if a status is
        // ever sent with it.
        Body(testDescription: "web, ended, status sent anyway", json: withoutAccess(status: "canceled"), live: false),
        Body(testDescription: "web, never completed, status sent anyway",
             json: withoutAccess(status: "incomplete_expired"), live: false),
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

    /// A hosted `PlanPickerView` cannot be driven from a unit test: it fetches
    /// its own account from the backend. So this reads the view's source and
    /// pins the two gates the tests above do not reach: every purchase option
    /// sits in the `else` of the sentence, Restore Purchases sits inside its
    /// own gate, and Cancel / Manage Subscription sits outside both.
    @Test("The plan picker hides every purchase option and Restore behind the gate")
    func viewHidesEveryPurchaseOptionBehindTheGate() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Account/PlanPickerView.swift"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let count = { (needle: String) in text.components(separatedBy: needle).count - 1 }

        let purchaseGate = "if let webManagedNote = Self.webManagedNote(for: accountInfo) { Text(verbatim: webManagedNote)"
        let purchaseBranch = #"} else { // Billing interval toggle Picker("Billing", selection: $billingInterval)"#
        let restoreGate = #"if Self.webManagedNote(for: accountInfo) == nil { // Restore purchases Button(isRestoring ? "Restoring..." : "Restore Purchases")"#
        let manage = #"if storeKit.isAppleSubscriber || accountInfo?.subscriptionProvider == "apple" {"#
        let purchaseOptions = [
            "await purchaseProduct(",
            #"Text("* After using your priority quota"#,
            #"Text("Payment will be charged to your Apple ID account"#,
        ]
        let restore = "storeKit.restorePurchases()"
        for needle in [purchaseGate, purchaseBranch, restoreGate, manage, restore] + purchaseOptions {
            #expect(count(needle) == 1, "\(needle)")
        }
        #expect(count("webManagedNote(for: ") == 2, "the two gates are the only call sites in the view")

        let gate = try #require(text.range(of: purchaseGate))
        let gateBlock = try #require(Self.block(in: text, from: gate.lowerBound))
        let branch = try #require(text.range(of: purchaseBranch))
        #expect(text.index(before: gateBlock.upperBound) == branch.lowerBound, "the else belongs to the sentence's gate")
        let elseBlock = try #require(Self.block(in: text, from: text.index(after: branch.lowerBound)))
        for needle in purchaseOptions {
            let found = try #require(text.range(of: needle))
            #expect(elseBlock.contains(found.lowerBound), "\(needle) must be hidden from a web subscriber")
        }

        let restoreStart = try #require(text.range(of: restoreGate))
        let restoreBlock = try #require(Self.block(in: text, from: restoreStart.lowerBound))
        let restoreCall = try #require(text.range(of: restore))
        #expect(restoreBlock.contains(restoreCall.lowerBound), "Restore must be hidden from a web subscriber")

        let manageStart = try #require(text.range(of: manage))
        #expect(manageStart.lowerBound >= elseBlock.upperBound && manageStart.lowerBound < restoreStart.lowerBound,
                "Cancel / Manage Subscription stays outside both gates")
    }

    /// The braces-included range of the block whose `{` is the first one at or
    /// after `start`, or nil when the braces do not balance.
    private static func block(in text: String, from start: String.Index) -> Range<String.Index>? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return open..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
