/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// =============================================================================
// KEEP — IMAP NSE SCAFFOLDING. DO NOT DELETE AS "DEAD CODE".
// =============================================================================
// IMAP doesn't fit the stateless-REST mold the way Gmail/Graph do, so the
// split here is finer-grained:
//
//   • `IMAPChannel` — the wire protocol boundary. Anything that can send an
//     IMAP frame and yield parsed responses conforms. Main-app `IMAPProvider`
//     will wrap its pooled SwiftMail connection as an `IMAPChannel`; the NSE's
//     `NSEIMAPConnection` (not yet built) will supply a throwaway
//     connection conforming to the same protocol.
//
//   • `IMAPCommands` — pure command sequences + response parsing. Depends only
//     on `IMAPChannel`, `Shared/Parse/RFC5322Parse`, and `Shared/Render/Body-
//     Renderer`. Compiles into BOTH main-app and NSE targets (same Shared/
//     glob as the rest of this directory).
//
// Target-membership status: the SwiftMail fork is currently linked only to the
// main `TabMail` target (`project.yml:targets.TabMail.dependencies`). The NSE's
// wire-level channel implementation will need an IMAP client inside the
// extension's 24MB memory budget — a future decision is needed between
// (a) linking SwiftMail to NSE, or (b) writing a minimal wire client in
// Shared/. Neither blocks the Shared/API/IMAPCommands surface defined here:
// the protocol is pure Swift, no SwiftMail types leak in.
//
// "Zero callers → delete" audits must NOT remove this file.
// Same reasoning as `Shared/API/GraphAPI.swift`. Infra-first, NSE-second.
//
// Implementation status (2026-04-13): protocol + signatures defined, function
// bodies are placeholders throwing `.notImplemented`. Main-app IMAPProvider
// and NSE IMAPNSEClient will fill these in when IMAP NSE ships.
// =============================================================================

/// A bidirectional IMAP wire channel. Anything that can transmit a command and
/// receive parsed responses conforms. One conformer per process/context:
///   • Main app: a wrapper over a pooled SwiftMail `IMAPServer` connection.
///   • NSE:     a throwaway connection built specifically for a single push
///             (connect → login → select → fetch → logout, no pool).
///
/// The protocol intentionally does not expose login/connect lifecycle — that
/// is the conformer's responsibility. Commands below assume an authenticated,
/// ready-to-SELECT channel.
public protocol IMAPChannel: Sendable {
    /// True if the underlying connection is currently usable.
    var isConnected: Bool { get }

    /// Send a raw IMAP command and return parsed responses. Implementations
    /// handle tagging, continuation requests, and untagged response routing.
    /// The response set includes every line (tagged + untagged) that arrived
    /// for this command; caller is responsible for interpreting them.
    func send(_ command: IMAPCommandFrame) async throws -> [IMAPResponseFrame]
}

/// Opaque wire-level command representation. The main-app `IMAPProvider`
/// translates this to SwiftMail's command types; the NSE's minimal client
/// serializes it directly to the IMAP wire format. Kept intentionally minimal
/// so both implementations are cheap.
public struct IMAPCommandFrame: Sendable {
    public let verb: String         // e.g. "SELECT", "UID FETCH", "UID SEARCH"
    public let arguments: String    // already-escaped argument string
    public init(verb: String, arguments: String) {
        self.verb = verb
        self.arguments = arguments
    }
}

/// Opaque wire-level response representation. Contains the raw line plus
/// (optionally) a parsed FETCH payload when the caller asked for message data.
public struct IMAPResponseFrame: Sendable {
    public enum Kind: Sendable {
        case untagged       // "* 12 EXISTS" style
        case tagged         // "<tag> OK ..."
        case continuation   // "+ ready for literal"
    }
    public let kind: Kind
    public let line: String
    /// For FETCH responses, the parsed RFC5322 headers / body bytes. Nil for
    /// commands that don't return message content.
    public let fetchedData: FetchedMessageData?
    public init(kind: Kind, line: String, fetchedData: FetchedMessageData? = nil) {
        self.kind = kind
        self.line = line
        self.fetchedData = fetchedData
    }
}

/// Partial fetch result — populated by whichever data item the FETCH asked for
/// (ENVELOPE, RFC822.HEADER, BODY[section], etc.). Consumer code lifts this
/// into `MessageMetadata` / `RenderedBody` via `IMAPCommands.fetchFull`.
public struct FetchedMessageData: Sendable {
    public let uid: UInt32?
    public let flagsLine: String?
    public let headers: String?          // raw RFC822 headers
    public let bodyStructure: String?    // raw BODYSTRUCTURE
    public let bodyBytes: Data?          // raw body (text/html part)
    public let attachmentBytes: Data?    // raw attachment bytes (when fetched)
    public init(uid: UInt32? = nil, flagsLine: String? = nil, headers: String? = nil,
                bodyStructure: String? = nil, bodyBytes: Data? = nil,
                attachmentBytes: Data? = nil) {
        self.uid = uid; self.flagsLine = flagsLine; self.headers = headers
        self.bodyStructure = bodyStructure; self.bodyBytes = bodyBytes
        self.attachmentBytes = attachmentBytes
    }
}

public struct IMAPMailboxStatus: Sendable {
    public let name: String
    public let exists: Int
    public let uidValidity: UInt32
    public let uidNext: UInt32
    public init(name: String, exists: Int, uidValidity: UInt32, uidNext: UInt32) {
        self.name = name; self.exists = exists
        self.uidValidity = uidValidity; self.uidNext = uidNext
    }
}

public enum IMAPCommandError: Error, Sendable {
    /// The IMAP NSE work will fill in the bodies below. Throwing this today
    /// keeps the surface compilable and call-site ready.
    case notImplemented(String)
    /// Bubbled from the channel when the server rejects a command.
    case serverError(String)
    /// BODYSTRUCTURE / header parse failure.
    case parseError(String)
}

/// Pure command sequences + response parsing. Operates on a caller-supplied
/// `IMAPChannel`. No connection state, no pool — that's the caller's problem.
///
/// Future consumers (when IMAP NSE ships):
///   • Main-app `IMAPProvider`: wraps a pooled SwiftMail connection as an
///     `IMAPChannel` and calls `IMAPCommands.fetchFull(...)` where it today
///     hand-rolls a FETCH + parse. Any body-extraction fix in this file then
///     lands in both targets.
///   • NSE `IMAPNSEClient`: one-shot connect + login + hand to IMAPCommands.
public enum IMAPCommands {

    /// SELECT a mailbox and return its status (EXISTS / UIDVALIDITY / UIDNEXT).
    public static func selectMailbox(
        channel: IMAPChannel, name: String
    ) async throws -> IMAPMailboxStatus {
        throw IMAPCommandError.notImplemented("IMAPCommands.selectMailbox not yet implemented")
    }

    /// UID SEARCH SINCE <date> — returns UIDs of messages delivered since the
    /// given date. Used by delta-style IMAP sync (new-messages-only pushes).
    public static func fetchUIDsSince(
        channel: IMAPChannel, date: Date, limit: Int
    ) async throws -> [UInt32] {
        throw IMAPCommandError.notImplemented("IMAPCommands.fetchUIDsSince not yet implemented")
    }

    /// UID FETCH envelope + header metadata for a set of UIDs.
    /// Output is canonical `MessageMetadata` — same DTO Gmail/Graph paths emit.
    static func fetchMetadata(
        channel: IMAPChannel, uids: [UInt32]
    ) async throws -> [MessageMetadata] {
        throw IMAPCommandError.notImplemented("IMAPCommands.fetchMetadata not yet implemented")
    }

    /// UID FETCH full message for a single UID — returns metadata + rendered
    /// body (CIDs, ICS, text extraction all run through `BodyRenderer`).
    /// This is the one-stop method an NSE IMAP push will call.
    static func fetchFull(
        channel: IMAPChannel, uid: UInt32
    ) async throws -> (MessageMetadata, RenderedBody) {
        throw IMAPCommandError.notImplemented("IMAPCommands.fetchFull not yet implemented")
    }

    /// UID FETCH BODY[<section>] for an individual attachment part.
    /// Main-app attachment-on-open path will migrate to this when IMAP NSE ships.
    public static func fetchAttachment(
        channel: IMAPChannel, uid: UInt32, section: String, encoding: String?
    ) async throws -> Data {
        throw IMAPCommandError.notImplemented("IMAPCommands.fetchAttachment not yet implemented")
    }
}
