/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The complete product disposition of the page's generic image-error census.
///
/// JavaScript's `error` event does not reveal whether an image failed because of
/// a 404, an expired or authenticated URL, DNS, malformed bytes, connectivity,
/// or App Transport Security. Therefore this signal may support diagnostics but
/// must never produce user-visible chrome or make a cause-specific claim.
///
/// The legacy filename is retained because the Xcode project already owns this
/// source path. Keeping the policy here also makes the removal of the former
/// banner explicit and searchable instead of silently deleting its history.
internal enum ImageLoadFailureReportDisposition: Equatable {
    case malformed
    case diagnosticOnly(failed: Int, deferred: Int)

    static func classify(_ body: Any) -> ImageLoadFailureReportDisposition {
        guard let report = RenderBridgeInput.imageFailureReport(body) else {
            return .malformed
        }
        return .diagnosticOnly(failed: report.failed, deferred: report.deferred)
    }
}
