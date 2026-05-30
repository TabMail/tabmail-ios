/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the pure-function metadata helpers in ProviderSettingsView.
/// Locks the deep-link URLs and
/// the display-name capitalization so the "Get a key →" button always opens
/// the right console and the picker label always reads "Google" (not
/// "Gemini" — see deviation #2).
@Suite("BYOK provider info helpers")
struct BYOKProviderInfoTests {

    // MARK: - displayName

    @Test func displayNameOpenAI() {
        #expect(BYOKProviderInfo.displayName("openai") == "OpenAI")
    }

    @Test func displayNameAnthropic() {
        #expect(BYOKProviderInfo.displayName("anthropic") == "Anthropic")
    }

    @Test func displayNameGoogle() {
        // Deviation #2 — wire id is "google", display is "Google" (NOT
        // "Gemini" — Gemini is the model family, not the provider).
        #expect(BYOKProviderInfo.displayName("google") == "Google")
    }

    @Test func displayNameTabMailSentinel() {
        #expect(BYOKProviderInfo.displayName("tabmail") == "Tabmail")
    }

    @Test func displayNameUnknownFallsBackToCapitalized() {
        #expect(BYOKProviderInfo.displayName("xyz") == "Xyz")
    }

    // MARK: - keyURL

    @Test func openAIKeyURL() {
        #expect(BYOKProviderInfo.keyURL("openai")?.absoluteString == "https://platform.openai.com/api-keys")
    }

    @Test func anthropicKeyURL() {
        #expect(BYOKProviderInfo.keyURL("anthropic")?.absoluteString == "https://console.anthropic.com/settings/keys")
    }

    @Test func googleKeyURL() {
        #expect(BYOKProviderInfo.keyURL("google")?.absoluteString == "https://aistudio.google.com/app/apikey")
    }

    @Test func tabmailHasNoKeyURL() {
        #expect(BYOKProviderInfo.keyURL("tabmail") == nil)
    }

    // MARK: - ZDR disclaimer

    @Test func openAIDisclaimerCallsOutEnterprise() {
        #expect(BYOKProviderInfo.zdrDisclaimer("openai").contains("enterprise"))
    }

    @Test func anthropicDisclaimerSaysNoTraining() {
        #expect(BYOKProviderInfo.zdrDisclaimer("anthropic").contains("not used for training"))
    }

    @Test func googleDisclaimerWarnsAboutFreeTier() {
        // Google's free-tier API can be used for training.
        let copy = BYOKProviderInfo.zdrDisclaimer("google")
        #expect(copy.contains("paid"))
    }

    @Test func unknownProviderDisclaimerIsEmpty() {
        #expect(BYOKProviderInfo.zdrDisclaimer("xyz") == "")
    }

    // MARK: - billingSeparationNote — provider-specific copy that warns users
    // their consumer subscription doesn't cover API access.

    @Test func openAIBillingNoteMentionsChatGPTPlus() {
        // ChatGPT Plus / Pro are the consumer plans most likely to confuse.
        #expect(BYOKProviderInfo.billingSeparationNote("openai").contains("ChatGPT"))
    }

    @Test func anthropicBillingNoteMentionsClaudeMax() {
        // Claude Max is the high-end consumer plan; users assume it covers API.
        #expect(BYOKProviderInfo.billingSeparationNote("anthropic").contains("Claude"))
    }

    @Test func googleBillingNoteMentionsGemini() {
        #expect(BYOKProviderInfo.billingSeparationNote("google").contains("Gemini"))
    }

    @Test func unknownProviderBillingNoteIsEmpty() {
        #expect(BYOKProviderInfo.billingSeparationNote("xyz") == "")
    }
}
