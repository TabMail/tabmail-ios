/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension PromptStore {
    enum MarketplaceInstall: Equatable {
        case installed(String)
        case alreadyInstalled(String)
        /// Refused with nothing written: the change counter moved while the download ran.
        case notSaved
    }

    /// Installs a marketplace template. The download awaits before the template is saved, so the install carries
    /// the change counter it started with (DS-DEMO): a demo switch in between refuses it and saves nothing.
    func installMarketplaceTemplate(
        id: String,
        download: (String) async throws -> TemplateMarketplaceClient.DownloadedTemplate
    ) async throws -> MarketplaceInstall {
        let started = changeSeen
        let downloaded = try await download(id)
        guard changeSeen == started else { return .notSaved }

        // Dedup: skip if template with this ID already exists (not soft-deleted)
        guard !visibleTemplates.contains(where: { $0.id == downloaded.id }) else { return .alreadyInstalled(downloaded.id) }

        let localTemplate = ReplyTemplate(
            id: downloaded.id,
            name: downloaded.name,
            enabled: downloaded.enabled,
            instructions: downloaded.instructions,
            exampleReply: downloaded.exampleReply
        )
        guard addTemplate(localTemplate) else { return .notSaved }
        return .installed(downloaded.id)
    }
}
