/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import StoreKit

struct PlanPickerView: View {
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.scenePhase) private var scenePhase
    @State private var billingInterval = "monthly"
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var purchaseError: String?
    @State private var accountInfo: AccountInfo?

    private let backend = BackendClient()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Free-trial state from the backend. The per-product "2 weeks
                // free" badge below is a StoreKit introductory offer and is a
                // separate thing entirely — this banner describes the trial the
                // account already has (or had), so the page never implies the
                // user still needs to start one.
                if let trialBanner = trialBannerCopy {
                    StatusBanner(icon: trialBanner.icon, text: trialBanner.text, color: trialBanner.color)
                }

                // Pending state banners from backend
                if let cancellation = accountInfo?.pendingCancellation, cancellation.cancelAt != nil {
                    StatusBanner(
                        icon: "exclamationmark.triangle",
                        text: "Cancels on \(cancellation.cancelAtFormatted ?? cancellation.cancelAt.map { formatTimestamp($0) } ?? "")",
                        color: .orange
                    )
                }

                if let downgrade = accountInfo?.pendingDowngrade, let toPlan = downgrade.toPlan {
                    StatusBanner(
                        icon: "arrow.down.circle",
                        text: "Downgrading to \(StoreKitManager.displayPlanName(forTier: toPlan)) on \(downgrade.effectiveAtFormatted ?? downgrade.effectiveAt.map { formatTimestamp($0) } ?? "")",
                        color: .yellow
                    )
                }

                // Billing interval toggle
                Picker("Billing", selection: $billingInterval) {
                    Text("Monthly").tag("monthly")
                    Text("Yearly").tag("yearly")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                let filteredProducts = billingInterval == "monthly"
                    ? storeKit.monthlyProducts()
                    : storeKit.yearlyProducts()

                ForEach(filteredProducts, id: \.id) { product in
                    PlanCard(
                        product: product,
                        monthlyEquivalent: monthlyPrice(for: product),
                        savingsPercent: savingsPercent(for: product),
                        isCurrentPlan: isCurrentPlan(product),
                        hasAnyAppleSub: storeKit.isAppleSubscriber || (accountInfo?.hasSubscription == true && accountInfo?.subscriptionProvider == "apple"),
                        // Backend tier preferred; StoreKit-local plan covers the
                        // window where /whoami hasn't loaded (offline, fresh launch)
                        // so upgrade/downgrade labels stay rank-correct.
                        backendTier: accountInfo?.planTier ?? storeKit.activePlan,
                        isPurchasing: isPurchasing,
                        isEligibleForTrial: storeKit.isEligibleForTrial,
                        suppressesIntroOffer: hasRunningSignupTrial
                    ) {
                        await purchaseProduct(product)
                    }
                }

                if storeKit.products.isEmpty {
                    if let loadError = storeKit.productsLoadError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(Palette.textMuted)
                            Text(loadError)
                                .font(.subheadline)
                                .foregroundStyle(Palette.textMuted)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                Task { await storeKit.loadProducts() }
                            }
                        }
                        .padding(.top, 40)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading plans...")
                                .font(.subheadline)
                                .foregroundStyle(Palette.textMuted)
                        }
                        .padding(.top, 40)
                        .task {
                            await storeKit.loadProducts()
                        }
                    }
                }

                if let purchaseError {
                    Text(purchaseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                // Footnotes
                if !filteredProducts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("* After using your priority quota, AI agent requests continue at a slower pace to ensure fair access for all users.")
                        Text("** Priority AI agent requests may be throttled during peak usage to ensure quality of service.")
                        Text("*** Prices exclude taxes. Taxes will be added at checkout where applicable.")
                        // Zero plan cost disclosure (D7 — parity with the site's "What is the Zero plan?" FAQ)
                        Text("Zero plan: the subscription covers TabMail's email infrastructure only — AI runs on your own provider account using your own API keys. Depending on your provider and model choice, TabMail's AI features can consume a significant API bill on your account. Running on TabMail's own AI infrastructure (the Basic and Pro plans) is generally 10–100× cheaper for the same usage.")
                            .padding(.top, 8)
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 4)
                }

                // Apple-required subscription disclosure (Schedule 2, Section 3.8(b))
                if !filteredProducts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Payment will be charged to your Apple ID account at confirmation of purchase. Subscriptions automatically renew unless canceled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours prior to the end of the current period. You can manage and cancel your subscriptions by going to your Account Settings on the App Store after purchase. Any unused portion of a free trial period, if offered, will be forfeited when you purchase a subscription.")
                            .font(.caption2)
                            .foregroundStyle(Palette.textMuted)

                        HStack(spacing: 4) {
                            Link("Terms of Use", destination: URL(string: "https://tabmail.ai/terms")!)
                            Text("·")
                                .foregroundStyle(Palette.textMuted)
                            Link("Privacy Policy", destination: URL(string: "https://tabmail.ai/privacy")!)
                        }
                        .font(.caption2)
                    }
                    .padding(.horizontal, 4)
                }

                Divider()

                // Cancel subscription — opens Apple's native management sheet
                if storeKit.isAppleSubscriber || accountInfo?.subscriptionProvider == "apple" {
                    Button(role: .destructive) {
                        Task {
                            guard let windowScene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first else { return }
                            do {
                                try await AppStore.showManageSubscriptions(in: windowScene)
                            } catch {
                                print("[PlanPicker] Failed to open subscription management: \(error)")
                            }
                            // Refresh entitlements after sheet closes
                            await storeKit.updateCurrentEntitlements()
                            do {
                                accountInfo = try await backend.fetchAccountInfo()
                            } catch {
                                print("[PlanPicker] Refresh after manage failed: \(error)")
                            }
                        }
                    } label: {
                        Label("Cancel / Manage Subscription", systemImage: "xmark.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                // Restore purchases
                Button(isRestoring ? "Restoring..." : "Restore Purchases") {
                    isRestoring = true
                    Task {
                        await storeKit.restorePurchases()
                        isRestoring = false
                        if storeKit.isAppleSubscriber {
                            // Open the current user's AI gate only when the active
                            // Apple entitlement is NOT owned by a different TabMail
                            // account. Fails OPEN when ownership is unknown (no
                            // appAccountToken) and for the impossible no-session edge
                            // on this signed-in screen, so a legitimate restore is
                            // never blocked; fails CLOSED only when the active
                            // entitlement provably belongs to someone else. Only the
                            // restore path is guarded — the purchase path stamps a
                            // fresh appAccountToken and can never mismatch.
                            let currentUserId = TabMailAuthService.getSession()?.userId
                            let mayOpen = currentUserId
                                .map { storeKit.shouldOpenGateForRestoredEntitlement(currentUserId: $0) } ?? true
                            if mayOpen {
                                AISubscriptionGate.shared.openGate()
                                if let jws = await storeKit.latestEntitlementJWS() {
                                    Self.verifyPurchaseWithBackend(jws: jws)
                                }
                                let restored = try? await backend.fetchAccountInfo()
                                accountInfo = restored
                                // This body races the detached `verifyPurchaseWithBackend`
                                // write, so it may still be the pre-restore state. Route
                                // it through the open-only seam: it can refresh the
                                // sidebar copy and reopen the gate when the backend
                                // already confirmed the subscription, but it must NEVER
                                // close the gate `openGate()` just opened from local
                                // StoreKit truth. A later authoritative whoami reconciles
                                // if this one raced.
                                if let restored { AISubscriptionGate.shared.refreshAfterLocalPurchase(restored) }
                            } else {
                                // Active Apple entitlement belongs to a different
                                // TabMail account — never open the current user's gate
                                // on someone else's subscription.
                                storeKit.restoreResult = "That subscription belongs to a different TabMail account."
                            }
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Palette.accentColor)
                .disabled(isRestoring)

                if let restoreResult = storeKit.restoreResult {
                    Text(restoreResult)
                        .font(.caption)
                        .foregroundStyle(Palette.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
        }
        .background(Palette.previewPaneBg)
        .navigationTitle("Choose a Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                accountInfo = try await backend.fetchAccountInfo()
            } catch {
                print("[PlanPicker] fetchAccountInfo failed: \(error)")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    do {
                        accountInfo = try await backend.fetchAccountInfo()
                    } catch {
                        print("[PlanPicker] Refresh on foreground failed: \(error)")
                    }
                }
            }
        }
        .overlay {
            if isPurchasing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView("Processing…")
                            .padding(24)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
    }

    // MARK: - Helpers

    /// Whether the account is on a **running server-granted trial**. While that
    /// is true the App Store introductory offer must not also be advertised on
    /// this page: the two are different things, the page would be claiming the
    /// user can start a free trial they are already on, and Apple would in fact
    /// grant its intro offer on top. Suppression is scoped to exactly this
    /// cohort — every other user's badge and CTA are untouched.
    private var hasRunningSignupTrial: Bool {
        PlanCardIntroOffer.suppressesIntroOffer(for: accountInfo)
    }

    /// Banner describing the account's free trial, or `nil` when there is none
    /// to describe.
    ///
    /// The active copy says the trial ends, and deliberately does NOT say
    /// billing starts immediately: while App Store Connect still carries the
    /// introductory offers, a purchase made here can begin with Apple's own free
    /// period, so "billing starts immediately" would be a false claim. The
    /// forfeiture of the remaining server-trial days is true either way.
    private var trialBannerCopy: (icon: String, text: String, color: Color)? {
        switch accountInfo?.trialState() {
        case .active(let daysRemaining):
            let unit = daysRemaining == 1 ? "day" : "days"
            return ("clock",
                    "Free trial · \(daysRemaining) \(unit) left. Subscribing now ends the trial.",
                    .blue)
        case .ended:
            return ("clock.badge.exclamationmark",
                    "Your free trial has ended — subscribe to continue using AI features.",
                    .orange)
        default:
            return nil
        }
    }

    /// Determine if this product is the user's current active plan.
    /// Uses backend tier for quick "is this the right tier?" check, then StoreKit for monthly/yearly distinction.
    private func isCurrentPlan(_ product: Product) -> Bool {
        let productTier = StoreKitManager.planName(for: product.id)
        // Backend tier check (faster than StoreKit local — no transaction verification lag)
        if let backendTier = accountInfo?.planTier,
           accountInfo?.hasSubscription == true,
           accountInfo?.subscriptionProvider == "apple" {
            guard backendTier == productTier else { return false }
            // Tier matches — use StoreKit product IDs to distinguish monthly vs yearly
            if !storeKit.purchasedProductIDs.isEmpty {
                return storeKit.purchasedProductIDs.contains(product.id)
            }
            // StoreKit has no product IDs yet — show tier match (better than nothing)
            return true
        }
        // Fallback to StoreKit local state
        guard let activePlan = storeKit.activePlan else { return false }
        guard activePlan == productTier else { return false }
        return storeKit.purchasedProductIDs.contains(product.id)
    }

    private func monthlyPrice(for product: Product) -> String? {
        guard product.id.contains("yearly") else { return nil }
        let perMonth = product.price / 12
        return perMonth.formatted(.currency(code: product.priceFormatStyle.currencyCode))
    }

    private func savingsPercent(for product: Product) -> Int? {
        guard product.id.contains("yearly") else { return nil }
        let tier = StoreKitManager.planName(for: product.id).lowercased()
        guard let monthlyProduct = storeKit.products.first(where: {
            $0.id.contains(tier) && $0.id.contains("monthly")
        }) else { return nil }
        let yearlyTotal = NSDecimalNumber(decimal: product.price).doubleValue
        let monthlyTotal = NSDecimalNumber(decimal: monthlyProduct.price).doubleValue * 12
        guard monthlyTotal > 0 else { return nil }
        let savings = ((monthlyTotal - yearlyTotal) / monthlyTotal) * 100
        return Int(savings.rounded())
    }

    private func formatTimestamp(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func purchaseProduct(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil

        guard let session = TabMailAuthService.getSession() else {
            purchaseError = "Please sign in first"
            isPurchasing = false
            return
        }

        do {
            let jwsRepresentation = try await storeKit.purchase(product, userId: session.userId)
            isPurchasing = false
            guard let jws = jwsRepresentation else {
                purchaseError = nil
                return
            }
            // Open gate immediately from local StoreKit verification
            AISubscriptionGate.shared.openGate()
            // Send JWS to backend to process immediately (don't wait for Apple webhook)
            Self.verifyPurchaseWithBackend(jws: jws)
            // Refresh account info to update subscription display
            let purchased = try? await backend.fetchAccountInfo()
            accountInfo = purchased
            // This body races the detached `verifyPurchaseWithBackend` write, so
            // it may still be the pre-purchase state. Route it through the
            // open-only seam: it can refresh the sidebar copy and reopen the gate
            // when the backend already confirmed the subscription, but it must
            // NEVER close the gate `openGate()` just opened from local StoreKit
            // truth. A later authoritative whoami reconciles if this one raced.
            if let purchased { AISubscriptionGate.shared.refreshAfterLocalPurchase(purchased) }
        } catch {
            print("[PlanPicker] Purchase failed: \(error)")
            purchaseError = "Purchase failed. Please try again."
            isPurchasing = false
        }
    }

    /// Send signed transaction JWS to backend to process immediately.
    /// Detached to survive view re-renders. The backend verifies Apple's JWS signature
    /// and writes KV + Supabase — same as the webhook, but instant.
    /// Routes to dev webhook for sandbox transactions, prod for production.
    private static func verifyPurchaseWithBackend(jws: String) {
        Task.detached {
            // Route sandbox transactions to dev webhook, production to prod webhook.
            // This matches Apple's webhook routing (sandbox → apple-webhook-dev, prod → apple-webhook).
            // Peek at the JWS payload (base64url middle segment) to read the environment field.
            let baseURL = Self.webhookURL(forJWS: jws)
            let url = baseURL.appending(path: "/verify-purchase")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["signedTransactionInfo": jws])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 200 {
                    print("[PlanPicker] Backend verified purchase successfully")
                } else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("[PlanPicker] Backend verify-purchase returned \(statusCode): \(body)")
                }
            } catch {
                print("[PlanPicker] Backend verify-purchase failed: \(error)")
            }
        }
    }
    /// Determine the webhook URL by peeking at the JWS environment field.
    /// JWS format: header.payload.signature — decode payload (base64url) and read "environment".
    /// Sandbox → dev webhook, Production → prod webhook.
    private nonisolated static func webhookURL(forJWS jws: String) -> URL {
        let devURL = URL(string: "https://apple-webhook-dev.tabmail.ai")!
        let prodURL = URL(string: "https://apple-webhook.tabmail.ai")!

        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return BackendConfig.appleWebhookBaseURL }

        // Decode base64url payload
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let environment = json["environment"] as? String else {
            return BackendConfig.appleWebhookBaseURL
        }

        return environment == "Sandbox" ? devURL : prodURL
    }
}

// MARK: - Plan Card

private struct PlanCard: View {
    let product: Product
    let monthlyEquivalent: String?
    let savingsPercent: Int?
    let isCurrentPlan: Bool   // This exact product is the user's active plan
    let hasAnyAppleSub: Bool  // User has any active subscription (Apple or backend)
    let backendTier: String?  // Current plan tier ("Pro"/"Basic"/"BYOK") — backend, or StoreKit while backend unloaded
    let isPurchasing: Bool
    let isEligibleForTrial: Bool
    /// Set only while the account is on a running server-granted trial. It hides
    /// the App Store introductory-offer badge, its "free for 2 weeks" line, and
    /// the "Start Free Trial" call to action, so the page never invites a user
    /// to start a trial they are already on. `false` for everyone else, which
    /// leaves `isEligibleForTrial` / `hasIntroOffer` behaving exactly as before.
    let suppressesIntroOffer: Bool
    let onPurchase: () async -> Void

    private var isPro: Bool { product.id.contains("pro") }
    private var isZero: Bool { product.id.contains("byok") }
    private var isYearly: Bool { product.id.contains("yearly") }

    /// Backend-facing tier of this card's product ("BYOK"/"Basic"/"Pro").
    private var tierKey: String { StoreKitManager.planName(for: product.id) }

    /// User-facing tier label ("Zero"/"Basic"/"Pro") — display-only mapping (D6).
    private var planTier: String { StoreKitManager.displayPlanName(forTier: tierKey) }

    /// Whether this product carries an introductory offer (Zero has none —
    /// `isEligibleForTrial` is group-level, so it alone would wrongly badge Zero).
    private var hasIntroOffer: Bool { product.subscription?.introductoryOffer != nil }

    private var showsTrialBadge: Bool {
        PlanCardIntroOffer.showsTrialBadge(
            isEligibleForTrial: isEligibleForTrial,
            hasAnyAppleSub: hasAnyAppleSub,
            hasIntroOffer: hasIntroOffer,
            suppressesIntroOffer: suppressesIntroOffer
        )
    }

    private var buttonLabel: String {
        PlanCardIntroOffer.buttonLabel(
            showsTrialBadge: showsTrialBadge,
            hasAnyAppleSub: hasAnyAppleSub,
            currentRank: StoreKitManager.tierRank(forTier: backendTier),
            cardRank: StoreKitManager.tierRank(for: product.id)
        )
    }

    private var features: [String] {
        if isZero {
            return [
                "Email content not stored",
                "Bring your own AI keys (OpenAI, Anthropic, Google)",
                "AI runs on your own provider account",
                "Limited access to TabMail AI",
                "Full access to TabMail client features",
            ]
        }
        if isPro {
            return [
                "Email content not stored",
                "Unlimited AI agent requests*",
                "2× priority AI agent requests**",
                "Perfect for 10+ emails sent per day",
                "Perfect for 100+ emails received per day",
            ]
        }
        return [
            "Email content not stored",
            "Unlimited AI agent requests*",
            "Limited priority AI agent requests**",
            "Good for 5-10 emails sent per day",
            "Good for 50-100 emails received per day",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + badge
            HStack {
                Text(planTier)
                    .font(.title2.bold())
                    .foregroundStyle(Palette.textColor)
                if isPro {
                    Text("Most Popular")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accentColor)
                        .clipShape(Capsule())
                }
                Spacer()
            }

            // Trial badge
            if showsTrialBadge {
                Text("2 weeks free")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green)
                    .clipShape(Capsule())
            }

            // Price
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(product.displayPrice)
                        .font(.title3.bold())
                        .foregroundStyle(Palette.accentColor)
                    Text("/ \(isYearly ? "year" : "month")")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textMuted)
                }
                if isYearly {
                    HStack(spacing: 6) {
                        if let monthlyEquivalent {
                            Text("\(monthlyEquivalent)/mo")
                                .font(.caption)
                                .foregroundStyle(Palette.textMuted)
                        }
                        if let savingsPercent {
                            Text("Save \(savingsPercent)%")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            Text(product.description)
                .font(.caption)
                .foregroundStyle(Palette.textMuted)

            ForEach(features, id: \.self) { feature in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.accentColor)
                        .font(.caption)
                    Text(feature)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textColor)
                }
            }

            if showsTrialBadge {
                Text("Free for 2 weeks, then \(product.displayPrice)/\(isYearly ? "year" : "month"). Cancel before the trial ends to avoid being charged.")
                    .font(.caption)
                    .foregroundStyle(Palette.textMuted)
            }

            if isCurrentPlan {
                Text("Current Plan")
                    .font(.subheadline.bold())
                    .foregroundStyle(Palette.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    Task { await onPurchase() }
                } label: {
                    Text(buttonLabel)
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurchasing)
            }
        }
        .padding(16)
        .background(Palette.boxBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            isPro ? RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.accentColor, lineWidth: 2) : nil
        )
    }
}
