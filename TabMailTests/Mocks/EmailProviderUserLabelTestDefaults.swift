/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// The user-label requirements (#500) for the TEST-ONLY `EmailProvider` mocks,
/// which do not model labels. Visible only in this test module, so every app
/// provider still has to state its own rules (`AccountProvider.emailProviderType`
/// never routes to a mock). A mock reached here creates no label and keeps no
/// pushed label.
extension EmailProvider {
    static func userLabel(named name: String, connected: (any EmailProvider)?) async throws -> ProviderUserLabel {
        throw ProviderError.notConnected
    }

    static func userLabelCatalog(from folders: [FolderInfo]) -> [ProviderUserLabel]? {
        nil
    }

    static func storedUserLabelIds(fromPushed rawLabels: [String], accountId: String, db: Database) throws -> [String] {
        []
    }
}
