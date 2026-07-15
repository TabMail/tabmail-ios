/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Persistent AI cache keyed by TB-compatible unique message key.
/// Survives MessageHeader deletion (stale detection, UIDVALIDITY changes).
/// Key format matches TB's getUniqueMessageKey(): "{accountId}:{folderPath}:{rfc822MessageId}"
struct MessageAICache: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "messageAICache"

    /// Unique key: "{accountId}:{folderPath}:{rfc822MessageId}"
    var key: String

    /// RFC 2822 Message-ID (for direct Device Sync probe lookup without parsing the composite key)
    var rfc822MessageId: String?

    // Summary fields (matches TB's summary cache)
    var summaryBlurb: String?
    var summaryTodos: String?
    var reminderDate: String?
    var reminderTime: String?
    var reminderContent: String?

    // Action field (matches TB's action cache — plain ActionTag enum)
    var actionTag: ActionTag?

    // Reply cache (matches TB's reply: IDB prefix in replyGenerator.js)
    var cachedReply: String?
    var replyGeneratedAt: Date?

    var updatedAt: Date

    // GRDB Identifiable: use `key` as the primary key
    var id: String { key }

    // Tell GRDB the primary key column name
    nonisolated(unsafe) static let databaseSelection: [any SQLSelectable] = [AllColumns()]

    init(key: String, rfc822MessageId: String? = nil) {
        self.key = key
        self.rfc822MessageId = rfc822MessageId
        self.updatedAt = Date()
    }

    /// Build the cache key matching TB's getUniqueMessageKey() format.
    /// Returns nil if rfc822MessageId is nil or empty (skip cache for those messages).
    /// Delegates to the shared `MessageIdentity` helper so NSE + main app
    /// emit byte-identical keys — do NOT inline the interpolation.
    static func cacheKey(accountId: String, folderPath: String, rfc822MessageId: String?) -> String? {
        MessageIdentity.aiCacheKey(accountId: accountId, folderPath: folderPath, rfc822MessageId: rfc822MessageId)
    }

    /// Restore cached AI state into a newly created MessageHeader.
    /// Preserves first-compute-wins: doesn't overwrite actionTag if already set from server.
    static func restoreIfCached(
        into header: inout MessageHeader,
        accountId: String,
        folderPath: String,
        db: Database
    ) throws {
        guard let key = cacheKey(
            accountId: accountId,
            folderPath: folderPath,
            rfc822MessageId: header.rfc822MessageId
        ) else { return }

        guard var cached = try MessageAICache
            .filter(Column("key") == key)
            .fetchOne(db)
        else { return }

        // Restore summary fields only if header doesn't have them
        if header.summaryBlurb == nil, let blurb = cached.summaryBlurb, !blurb.isEmpty {
            header.summaryBlurb = blurb
            header.summaryTodos = cached.summaryTodos
            header.reminderDate = cached.reminderDate
            header.reminderTime = cached.reminderTime
            header.reminderContent = cached.reminderContent
        }

        // Restore action ONLY if header doesn't already have one from server
        // (IMAP keywords/Gmail labels take precedence — first-compute-wins)
        if header.actionTag == nil, let cachedTag = cached.actionTag {
            // ReplyDetect: if message already replied, override "reply" → "none" on header
            // (matches TB's messageProcessor.js ReplyDetect logic)
            // AI cache keeps the original LLM value (like TB's action:orig: key)
            let effectiveTag = (cachedTag == .reply && header.isReplied) ? ActionTag.none : cachedTag
            // Stamp actionTagSetAt to NOW rather than carrying any prior stamp:
            // MessageAICache has no timestamp of its own, and a restore means the
            // tag is live again on this (possibly brand-new) header — the simplest
            // correct behavior is to start its TTL clock fresh from restoration.
            header.setActionTag(effectiveTag)
            if effectiveTag != cachedTag {
                print("[ReplyDetect] Cache restore: reply→none for \(header.messageId) (already replied)")
            }
        }

        // Restore cached reply if header doesn't have one
        if header.cachedReply == nil, let reply = cached.cachedReply, !reply.isEmpty {
            header.cachedReply = reply
        }

        // Touch updatedAt so TTL stays fresh for inbox messages being re-created
        cached.updatedAt = Date()
        try cached.save(db)

        print("[AICache] Restored for \(header.messageId)")
    }

    /// Write AI state to the persistent cache (upsert).
    /// Only overwrites non-nil parameters — preserves existing cached fields.
    /// No-op if rfc822MessageId is nil (skip cache for messages without Message-ID).
    static func writeThrough(
        accountId: String,
        folderPath: String,
        rfc822MessageId: String?,
        summaryBlurb: String? = nil,
        summaryTodos: String? = nil,
        reminderDate: String? = nil,
        reminderTime: String? = nil,
        reminderContent: String? = nil,
        actionTag: ActionTag? = nil,
        cachedReply: String? = nil,
        replyGeneratedAt: Date? = nil,
        db: Database
    ) throws {
        guard let key = cacheKey(
            accountId: accountId,
            folderPath: folderPath,
            rfc822MessageId: rfc822MessageId
        ) else { return }

        var cache = try MessageAICache
            .filter(Column("key") == key)
            .fetchOne(db) ?? MessageAICache(key: key, rfc822MessageId: rfc822MessageId)

        // Only overwrite non-nil values (preserves existing fields on partial updates)
        if let summaryBlurb { cache.summaryBlurb = summaryBlurb }
        if let summaryTodos { cache.summaryTodos = summaryTodos }
        if let reminderDate { cache.reminderDate = reminderDate }
        if let reminderTime { cache.reminderTime = reminderTime }
        if let reminderContent { cache.reminderContent = reminderContent }
        if let actionTag { cache.actionTag = actionTag }
        if let cachedReply { cache.cachedReply = cachedReply }
        if let replyGeneratedAt { cache.replyGeneratedAt = replyGeneratedAt }
        cache.updatedAt = Date()
        try cache.save(db)
    }
}
