/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Main-app activation and refresh ownership are separate. Refresh may advance
/// a shared grant, but it never writes the active selection or recreates an item.
final class ProviderCredentialStore: @unchecked Sendable {
    static let shared = ProviderCredentialStore()
    static let pointerPrefix = "provider_oauth_active:"
    static let lineagePrefix = "provider_oauth_lineage:"

    struct Tokens: Codable, Sendable, Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    struct Activation: Codable, Sendable, Equatable {
        let generation: String
        let lineage: String
        let tokens: Tokens
    }

    private struct Grant: Codable, Sendable {
        let generation: String
        let tokens: Tokens
    }

    private let backend: any TabMailSessionKeychainBackend
    private let gate: CredentialRefreshGate

    init(backend: any TabMailSessionKeychainBackend = SecurityTabMailSessionBackend(),
         storageLock: CredentialStorageLock = .init()) {
        self.backend = backend
        gate = CredentialRefreshGate(backend: backend, storageLock: storageLock)
    }

    static func isProviderAccount(_ key: String) -> Bool {
        key.hasPrefix(pointerPrefix) || key.hasPrefix(lineagePrefix)
    }

    private func lineageKey(_ accountId: String, _ lineage: String) -> String {
        Self.lineagePrefix + accountId + ":" + lineage
    }

    func activation(accountId: String) -> Activation? {
        guard case .found(let item) = backend.readShared(account: Self.pointerPrefix + accountId) else { return nil }
        return try? JSONDecoder().decode(Activation.self, from: item.data)
    }

    func current(accountId: String, generation: String? = nil) -> Tokens? {
        guard let active = activation(accountId: accountId),
              generation == nil || active.generation == generation,
              let data = try? gate.read(lineageKey(accountId, active.lineage)),
              let grant = try? JSONDecoder().decode(Grant.self, from: data),
              activation(accountId: accountId)?.generation == active.generation else { return nil }
        if grant.generation == active.generation { return grant.tokens }
        // An older refresh can rotate the retained grant after interactive login.
        // Keep its refresh token while selecting the newer interactive access.
        return Tokens(accessToken: active.tokens.accessToken, refreshToken: grant.tokens.refreshToken,
                      expiresAt: active.tokens.expiresAt)
    }

    /// Called only by the app's lifecycle owner, in one synchronous actor turn.
    /// A fresh grant never waits for an old refresh's storage lock or HTTP call.
    @discardableResult
    func install(accountId: String, tokens: Tokens, expectedGeneration: String? = nil) throws -> Activation {
        let pointerKey = Self.pointerPrefix + accountId
        let previous: Activation?
        switch backend.readShared(account: pointerKey) {
        case .found(let item): previous = try JSONDecoder().decode(Activation.self, from: item.data)
        case .notFound: previous = nil
        case .failed: throw CredentialRefreshError.unavailable
        }
        if let expectedGeneration, previous?.generation != expectedGeneration {
            throw CredentialRefreshError.inactive
        }
        let previousTokens = previous.flatMap { _ in current(accountId: accountId) }
        if previous != nil, tokens.refreshToken == nil, previousTokens == nil {
            // An omitted grant means retain the old one, not silently discard it
            // because a protected Keychain read failed.
            throw CredentialRefreshError.unavailable
        }
        let sameGrant = previous != nil && previousTokens?.refreshToken != nil &&
            (tokens.refreshToken == nil || tokens.refreshToken == previousTokens?.refreshToken)
        let generation = UUID().uuidString
        let lineage = sameGrant ? previous!.lineage : UUID().uuidString
        let installedTokens = Tokens(accessToken: tokens.accessToken,
                                     refreshToken: tokens.refreshToken ?? (sameGrant ? previousTokens?.refreshToken : nil),
                                     expiresAt: tokens.expiresAt)
        let active = Activation(generation: generation, lineage: lineage,
            tokens: Tokens(accessToken: tokens.accessToken, refreshToken: nil, expiresAt: tokens.expiresAt))
        do {
            if !sameGrant {
                try requireSuccess(backend.addShared(account: lineageKey(accountId, lineage),
                    data: JSONEncoder().encode(Grant(generation: generation, tokens: installedTokens))))
            }
            let data = try JSONEncoder().encode(active)
            if previous == nil { try requireSuccess(backend.addShared(account: pointerKey, data: data)) }
            else {
                let outcome = backend.updateShared(account: pointerKey, data: data)
                if outcome != .success, !sameGrant {
                    _ = backend.deleteShared(account: lineageKey(accountId, lineage))
                }
                try requireSuccess(outcome)
            }
            guard activation(accountId: accountId) == active else { throw CredentialRefreshError.unavailable }
        } catch {
            if previous == nil {
                // The caller has already persisted the account. Attempt both
                // deletions even if one fails; its normal migration/removal can
                // retry any remaining items after interruption or locked storage.
                _ = backend.deleteShared(account: pointerKey)
                _ = backend.deleteShared(account: lineageKey(accountId, lineage))
            }
            throw error
        }
        try? sweep(accountId: accountId)
        return active
    }

    /// The main app migrates only a live account, before exposing its accessors.
    /// The extension never imports split keys from potentially stale mirrors.
    func migrateLegacy(accountId: String) throws {
        switch backend.readShared(account: Self.pointerPrefix + accountId) {
        case .found:
            for key in ["accessToken:", "refreshToken:"] {
                try requireDeletion(backend.deleteShared(account: key + accountId))
            }
            try sweep(accountId: accountId)
            return
        case .failed: throw CredentialRefreshError.unavailable
        case .notFound: break
        }
        func legacy(_ key: String) throws -> String? {
            switch backend.readShared(account: key + accountId) {
            case .found(let item): return String(data: item.data, encoding: .utf8)
            case .notFound: return nil
            case .failed: throw CredentialRefreshError.unavailable
            }
        }
        let access = try legacy("accessToken:")
        let refresh = try legacy("refreshToken:")
        guard access != nil || refresh != nil else {
            try sweep(accountId: accountId)
            return
        }
        try install(accountId: accountId,
                    tokens: Tokens(accessToken: access ?? "", refreshToken: refresh, expiresAt: nil))
        for key in ["accessToken:", "refreshToken:"] {
            try requireDeletion(backend.deleteShared(account: key + accountId))
        }
    }

    func refresh(accountId: String, generation: String, rejectedToken: String? = nil,
                 exchange: @Sendable (String) async throws -> Tokens) async throws -> Tokens {
        guard let active = activation(accountId: accountId), active.generation == generation else {
            throw CredentialRefreshError.inactive
        }
        let key = lineageKey(accountId, active.lineage)
        let captured = try gate.read(key)
        let grant = try JSONDecoder().decode(Grant.self, from: captured)
        if let rejectedToken, let current = current(accountId: accountId, generation: generation),
           !current.accessToken.isEmpty, current.accessToken != rejectedToken {
            CredentialRefreshGate.diagnostic?("stage=lookup outcome=peer_credential_reused")
            return current
        }
        guard let refresh = grant.tokens.refreshToken, !refresh.isEmpty else {
            throw CredentialRefreshError.requiresAuthorization
        }
        let completion = try await gate.refresh(account: key, captured: captured) { input in
            let inputGrant = try JSONDecoder().decode(Grant.self, from: input)
            guard let consumed = inputGrant.tokens.refreshToken else {
                throw CredentialRefreshError.rejected
            }
            let tokens = try await exchange(consumed)
            guard !tokens.accessToken.isEmpty, tokens.refreshToken?.isEmpty != true else {
                throw CredentialRefreshError.unavailable
            }
            return try JSONEncoder().encode(Grant(generation: generation,
                tokens: Tokens(accessToken: tokens.accessToken,
                               refreshToken: tokens.refreshToken ?? consumed, expiresAt: tokens.expiresAt)))
        }
        guard completion.persisted else {
            CredentialRefreshGate.diagnostic?("stage=authorization outcome=refused_not_persisted")
            throw CredentialRefreshError.inactive
        }
        guard activation(accountId: accountId)?.generation == generation else {
            CredentialRefreshGate.diagnostic?("stage=authorization outcome=activation_changed")
            throw CredentialRefreshError.inactive
        }
        guard let result = current(accountId: accountId, generation: generation) else {
            CredentialRefreshGate.diagnostic?("stage=authorization outcome=credential_unavailable")
            throw CredentialRefreshError.inactive
        }
        return result
    }

    /// Deactivation is independent of an old lineage lock. A failed deletion is
    /// surfaced to the existing account-cleanup retry instead of claiming success.
    func remove(accountId: String) throws {
        try requireDeletion(backend.deleteShared(account: Self.pointerPrefix + accountId))
        guard activation(accountId: accountId) == nil else { throw CredentialRefreshError.unavailable }
        for key in ["accessToken:", "refreshToken:"] {
            try requireDeletion(backend.deleteShared(account: key + accountId))
        }
        try sweep(accountId: accountId)
    }

    private func sweep(accountId: String) throws {
        let active: String?
        switch backend.readShared(account: Self.pointerPrefix + accountId) {
        case .found(let item): active = try JSONDecoder().decode(Activation.self, from: item.data).lineage
        case .notFound: active = nil
        case .failed: throw CredentialRefreshError.unavailable
        }
        let prefix = Self.lineagePrefix + accountId + ":"
        let items: [TabMailSessionKeychainItem]
        switch backend.enumerateServiceItems() {
        case .success(let found): items = found
        case .notFound: return
        case .failed: throw CredentialRefreshError.unavailable
        }
        for item in items where item.account.hasPrefix(prefix) &&
            item.account != active.map({ lineageKey(accountId, $0) }) {
            try gate.delete(item.account)
        }
    }

    private func requireSuccess(_ result: TabMailSessionWriteResult) throws {
        guard result == .success else { throw CredentialRefreshError.unavailable }
    }

    private func requireDeletion(_ result: TabMailSessionWriteResult) throws {
        guard result == .success || result == .notFound else { throw CredentialRefreshError.unavailable }
    }
}
