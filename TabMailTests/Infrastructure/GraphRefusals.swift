/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

extension FakeHTTP.CannedResponse {
    /// Microsoft Graph's 503 asking the client to come back later than
    /// `HTTPConfig.retryWaitBudgetSeconds`. The HTTP layer hands it straight
    /// back instead of retrying it inside the one request (it retries a 503 whose
    /// `Retry-After` it is willing to wait), so the refusal reaches the provider's
    /// caller, the queue or the Outbox. Use it wherever a test injects a transient
    /// Graph refusal to see what the caller does with it.
    static let graphUnavailableBeyondRetry = FakeHTTP.CannedResponse.raw(
        statusCode: 503,
        headers: ["Retry-After": String(Int(HTTPConfig.retryWaitBudgetSeconds) + 1)])
}
