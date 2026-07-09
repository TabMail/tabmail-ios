/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Probes connected DeviceSync peers (TB addon, other iOS devices) for existing AI results
/// via the sync server's REST endpoint. Avoids redundant LLM calls when another device
/// already processed the message.
enum NSEAICacheProbe {

    struct CacheHit {
        let summaryBlurb: String?
        let summaryTodos: String?
        let actionTag: String?
    }

    /// Probe connected peers for cached AI results.
    /// Returns a CacheHit if any peer has results, nil otherwise.
    /// Respects the user's Device Sync enabled setting.
    static func probe(
        accountId: String,
        folderId: String,
        rfc822MessageId: String
    ) async -> CacheHit? {
        // Respect user's Device Sync setting
        guard NSEState.isDeviceSyncEnabled() else {
            NSELog.step("NSE probe: Device Sync disabled — skipping")
            return nil
        }

        guard let authToken = await NSETokenManager.validAccessToken() else {
            NSELog.step("NSE probe: no auth token — skipping")
            return nil
        }

        let baseURL = NSEState.getSyncBaseURL()
        guard let url = URL(string: "\(baseURL)/ai-cache/probe") else { return nil }

        let key = "\(accountId):\(folderId):\(rfc822MessageId)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["keys": [key]])
        request.timeoutInterval = 3 // Fast timeout — peers should respond quickly

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            NSELog.step("NSE probe: request failed or non-200")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let hit = results[key] as? [String: Any] else {
            NSELog.step("NSE probe: no hits")
            return nil
        }

        let summaryBlurb = hit["summaryBlurb"] as? String
        let actionTag = hit["actionTag"] as? String

        // Only consider it a real hit if we got meaningful data
        guard summaryBlurb != nil || actionTag != nil else { return nil }

        NSELog.step("NSE probe: HIT from peer — action=\(actionTag ?? "nil")")
        return CacheHit(
            summaryBlurb: summaryBlurb,
            summaryTodos: hit["summaryTodos"] as? String,
            actionTag: actionTag
        )
    }
}
