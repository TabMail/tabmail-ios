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

    /// A tap on Install: the change counter is taken here, synchronously, before the task is made, because the tap,
    /// not the task's first turn, is where the install starts (DS-DEMO). A demo switch between the tap and the
    /// task's first turn refuses the install.
    func beginMarketplaceInstall(
        id: String,
        download: @escaping (String) async throws -> TemplateMarketplaceClient.DownloadedTemplate
    ) -> Task<MarketplaceInstall, Error> {
        let started = changeSeen
        return Task { try await installMarketplaceTemplate(id: id, since: started, download: download) }
    }

    /// Installs a marketplace template. The download awaits before the template is saved, so the install carries
    /// the change counter it started with (DS-DEMO): a demo switch in between refuses it and saves nothing.
    /// `started` is the counter the tap took (`beginMarketplaceInstall`).
    func installMarketplaceTemplate(
        id: String,
        since started: UUID,
        download: (String) async throws -> TemplateMarketplaceClient.DownloadedTemplate
    ) async throws -> MarketplaceInstall {
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
