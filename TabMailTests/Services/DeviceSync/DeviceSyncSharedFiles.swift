/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

struct DeviceSyncTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The shared files: the vectors from this bundle, the catalog as the app bundles it.
enum DeviceSyncSharedFiles {
    static let vectorsSHA256 = "f656a5bfffbec4597a5fb0c97b63d9b4946f13bd67eeebe8f9cf1ddcc304a4a8"
    static let catalogSHA256 = "1ca6383ba9af86b42e13736b453cc3932297da32141aaf21a08c2055d9339f5f"

    private final class BundleToken {}

    static let vectorsData: Data = {
        let url = Bundle(for: BundleToken.self).url(forResource: "device-sync-vectors", withExtension: "json")!
        return try! Data(contentsOf: url)
    }()

    static let catalogData: Data = {
        let url = Bundle.main.url(forResource: "device-sync-default-catalog", withExtension: "json")!
        return try! Data(contentsOf: url)
    }()

    static let catalog: DefaultCatalog = try! DefaultCatalog.decode(catalogData)

    nonisolated(unsafe) static let vectors: [String: Any] = try! JSONSerialization.jsonObject(with: vectorsData) as! [String: Any]

    static var scenarios: [[String: Any]] {
        vectors["scenarios"] as! [[String: Any]]
    }

    static var parseCases: [[String: Any]] {
        vectors["parse"] as! [[String: Any]]
    }
}
