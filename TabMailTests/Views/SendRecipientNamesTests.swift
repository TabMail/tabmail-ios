/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Synchronization
import Testing
@testable import TabMail

/// Sent mail keeps each recipient's display name in To, Cc and Bcc (#1031), as
/// the Thunderbird add-on writes it (`name <email>`). A field gets a name three
/// ways: typed with the address, a picked contact, or the assistant. Each test
/// starts from fields filled those ways and checks what Send hands the
/// provider, what each provider writes, and what a saved draft keeps.
@Suite("Sent mail keeps recipient display names", .serialized)
struct SendRecipientNamesTests {
    /// To typed as `Sam Lee <sam@example.com>`, Cc a picked contact whose name
    /// holds a comma, Bcc added by the assistant under a non-ASCII name.
    private static func fields() throws -> ComposeDraftGuards.Recipients {
        let to = try #require(ComposeDraftGuards.committing("Sam Lee <sam@example.com>,", to: .init(), room: 10))
        let cc = ComposeDraftGuards.picking("ann@example.com", name: "Lee, Ann", to: .init(), room: 10)
        let written = ComposeEditJSON.make(addBcc: [["name": "Zoë Kim", "email": "zoe@example.com"]], body: "Body")
        let edit = try #require(AIService.parseInlineEditResponse(written))
        let bcc = ComposeDraftGuards.applying(try #require(edit.bccDelta), to: .init())
        return ComposeDraftGuards.Recipients(to: to, cc: cc, bcc: bcc)
    }

    private static let namedTo = [#""Sam Lee" <sam@example.com>"#]
    private static let namedCc = [#""Lee, Ann" <ann@example.com>"#]
    private static let namedBcc = [#""Zoë Kim" <zoe@example.com>"#]

    /// What Send hands the provider for `fields()`.
    private static func sentDraft() throws -> DraftMessage {
        guard case .send(let to, let cc, let bcc) = try fields().pendingCommitted.sendRecipients else {
            throw SendRefused()
        }
        return DraftMessage(to: to, cc: cc, bcc: bcc, subject: "Names", body: "Body")
    }

    private struct SendRefused: Error {}

    /// A message's header fields by name, unfolded (RFC 5322 2.2.3).
    private static func headerFields(_ message: String) -> [String: String] {
        let head = message.components(separatedBy: "\r\n\r\n").first ?? message
        let unfolded = head.replacingOccurrences(of: "\r\n ", with: " ").replacingOccurrences(of: "\r\n\t", with: "\t")
        var fields: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// The To, Cc and Bcc fields every name-keeping writer produces: plain words
    /// bare, a comma quoted, non-ASCII as an RFC 2047 encoded-word, and the whole
    /// header block 7-bit ASCII.
    private static func expectNamedHeaders(_ message: String, _ label: String) {
        let head = message.components(separatedBy: "\r\n\r\n").first ?? message
        let ascii = head.unicodeScalars.allSatisfy(\.isASCII)
        #expect(ascii, "\(label): a header is not 7-bit ASCII")
        let fields = headerFields(message)
        #expect(fields["To"] == "Sam Lee <sam@example.com>", "\(label)")
        #expect(fields["Cc"] == #""Lee, Ann" <ann@example.com>"#, "\(label)")
        let bcc = fields["Bcc"] ?? ""
        #expect(bcc.hasPrefix("=?UTF-8?"), "\(label): \(bcc)")
        #expect(RFC5322Parse.decodeRFC2047(bcc) == "Zoë Kim <zoe@example.com>", "\(label): \(bcc)")
    }

    private static func graphMailboxes(_ list: Any?) -> [[String: String]]? {
        (list as? [[String: Any]])?.compactMap { $0["emailAddress"] as? [String: String] }
    }

    // MARK: - Compose

    /// The bug this guards: Send passed the field's bare addresses, so every
    /// provider wrote `sam@example.com` where the field showed Sam Lee.
    @Test("Send gives each field's recipients under their display names")
    func sendCarriesNames() throws {
        let fields = try Self.fields()
        #expect(fields.to.displayNames == ["sam@example.com": "Sam Lee"])
        #expect(fields.cc.displayNames == ["ann@example.com": "Lee, Ann"])
        #expect(fields.bcc.displayNames == ["zoe@example.com": "Zoë Kim"])
        #expect(fields.pendingCommitted.sendRecipients
            == .send(to: Self.namedTo, cc: Self.namedCc, bcc: Self.namedBcc))
    }

    /// The bug this guards: a draft stored the bare addresses, so a draft
    /// reopened and then sent went out with no names.
    @Test("A saved draft keeps the names, and reopening it gives the same fields")
    func draftKeepsNames() throws {
        let fields = try Self.fields()
        let stored = fields.stored
        #expect(stored.to == Self.namedTo)
        #expect(stored.cc == Self.namedCc)
        #expect(stored.bcc == Self.namedBcc)
        let reopened = ComposeDraftGuards.Recipients().filling(
            to: RecipientEntry(stored.to), cc: RecipientEntry(stored.cc), bcc: RecipientEntry(stored.bcc))
        #expect(reopened == fields)
        #expect(reopened.stored.to == stored.to && reopened.stored.cc == stored.cc && reopened.stored.bcc == stored.bcc)
    }

    /// Reopening a draft reads its stored text through `RecipientEntry`'s own
    /// splitter (quotes, escapes, angle brackets) before any address parser, so
    /// the hard names must come back from it as the same recipients under the
    /// same names, and saving again writes the same text. A line break in a name
    /// is written as a space, so names and text are compared white space aside.
    @Test("A saved draft with hard names reopens to the same recipients and names")
    func draftKeepsHardNames() {
        let roles: [(ComposeDraftGuards.RecipientRole, [[String]])] = [(.to, Self.hardTo), (.cc, Self.hardCc), (.bcc, Self.hardBcc)]
        var fields = ComposeDraftGuards.Recipients()
        for (role, pairs) in roles {
            for pair in pairs { fields = fields.picking(pair[1], name: pair[0], to: role) }
        }
        let stored = fields.stored
        let reopened = ComposeDraftGuards.Recipients().filling(
            to: RecipientEntry(stored.to), cc: RecipientEntry(stored.cc), bcc: RecipientEntry(stored.bcc))
        for (role, pairs) in roles {
            let addresses = pairs.map { $0[1] }
            let names = Dictionary(uniqueKeysWithValues: pairs.map { ($0[1], Self.spaced($0[0])) })
            let picked = fields[role].tokens
            let reread = reopened[role].tokens
            let rereadNames = reopened[role].displayNames.mapValues { Self.spaced($0) }
            #expect(picked == addresses, "\(role)")
            #expect(reread == addresses, "\(role)")
            #expect(rereadNames == names, "\(role)")
        }
        let again = reopened.stored
        let savedAgain = [again.to, again.cc, again.bcc].map { $0.map { Self.spaced($0) } }
        let savedFirst = [stored.to, stored.cc, stored.bcc].map { $0.map { Self.spaced($0) } }
        #expect(savedAgain == savedFirst)
    }

    /// Send queues the message as an Outbox row, and the send made later (a
    /// retry too) is read back from that row.
    @Test("A queued send keeps every name until it is sent")
    func outboxKeepsNames() throws {
        let queued = OutboxMessage(accountId: "acc1", draft: try Self.sentDraft())
        #expect(queued.to == Self.namedTo)
        #expect(queued.cc == Self.namedCc)
        #expect(queued.bcc == Self.namedBcc)
        let later = try queued.toDraftMessage()
        #expect(later.to == Self.namedTo)
        #expect(later.cc == Self.namedCc)
        #expect(later.bcc == Self.namedBcc)
    }

    /// A sender with no name is listed under its address, which is not a name,
    /// however the stored address is spelled (a quoted local part reads as the
    /// same address without its quotes, and the listed address may differ from
    /// the stored one in case and quotes both).
    @Test("A reply goes to the sender under the sender's name, or bare when it has none", arguments: [
        ("Bob Stone", "bob@example.com", #""Bob Stone" <bob@example.com>"#),
        ("bob@example.com", "bob@example.com", "bob@example.com"),
        ("BOB@example.com", "bob@example.com", "bob@example.com"),
        (#""bob"@example.com"#, #""bob"@example.com"#, "bob@example.com"),
        ("BOB@example.com", #""bob"@example.com"#, "bob@example.com")
    ])
    func replyNamesTheSender(from: String, fromAddress: String, sent: String) {
        let header = MessageHeader(
            messageId: "100", subject: "Test", from: from, fromAddress: fromAddress,
            to: "me@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        let to = ComposeDraftGuards.fieldState(RecipientEntry.reply(to: header))
        #expect(ComposeDraftGuards.sendRecipients(to: to, cc: .init(), bcc: .init()) == .send(to: [sent], cc: [], bcc: []))
    }

    @Test("The Undo Send toast and the Outbox row still show addresses")
    func shownAddresses() {
        #expect(RecipientEntry.shownAddresses(
            [#""Sam Lee" <sam@example.com>"#, "bob@example.com", "a@example.com, b@example.com", "bob"])
            == ["sam@example.com", "bob@example.com", "a@example.com", "b@example.com", "bob"])
    }

    /// The bug this guards: the toast and the row took what Send sent, which now
    /// carries the names, so they showed `"Sam Lee" <sam@example.com>` and counted
    /// a stored list as one recipient.
    @Test("The Undo Send toast names the first To addresses and counts the rest", arguments: [
        ([#""Sam Lee" <sam@example.com>"#], [String](), "To: sam@example.com"),
        ([#""Sam Lee" <sam@example.com>"#, #""Lee, Ann" <ann@example.com>"#, "a@example.com, b@example.com"],
         [String](), "To: sam@example.com, ann@example.com +2"),
        ([String](), [#""Lee, Ann" <ann@example.com>"#, "c@example.com"], "Cc: ann@example.com"),
        ([String](), [String](), "")
    ])
    func undoSendSummaryShowsAddresses(to: [String], cc: [String], summary: String) {
        #expect(ComposeDraftGuards.undoSendSummary(to: to, cc: cc) == summary)
    }

    @Test("The Outbox row lists every To address")
    func outboxRowShowsAddresses() {
        let line = OutboxRow.recipientLine(
            [#""Sam Lee" <sam@example.com>"#, #""Lee, Ann" <ann@example.com>"#, "a@example.com, b@example.com"])
        #expect(line == "sam@example.com, ann@example.com, a@example.com, b@example.com")
    }

    // MARK: - Providers

    @Test("IMAP sends and files the message with the names in To, Cc and Bcc")
    func imapWritesNames() throws {
        let email = try IMAPProvider.buildEmail(from: try Self.sentDraft(), senderEmail: "me@example.com")
        #expect(email.recipients.map(\.name) == ["Sam Lee"])
        #expect(email.ccRecipients.map(\.name) == ["Lee, Ann"])
        #expect(email.bccRecipients.map(\.name) == ["Zoë Kim"])
        #expect(email.bccRecipients.map(\.address) == ["zoe@example.com"])
        Self.expectNamedHeaders(email.constructContent(includeBccHeader: true), "IMAP")
    }

    @Test("Gmail sends the message with the names in To, Cc and Bcc")
    func gmailWritesNames() throws {
        let gmail = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        Self.expectNamedHeaders(gmail.buildRFC822(draft: try Self.sentDraft()), "Gmail")
    }

    /// The bug this guards: Graph's recipient objects carried only `address`,
    /// and a recipient stored with its name went as one address holding both.
    @Test("Outlook sends and saves each recipient as its address and name", arguments: [true, false])
    func outlookWritesNames(sending: Bool) throws {
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        let message = provider.buildGraphSendPayload(draft: try Self.sentDraft(), sending: sending)
        #expect(Self.graphMailboxes(message["toRecipients"]) == [["address": "sam@example.com", "name": "Sam Lee"]])
        #expect(Self.graphMailboxes(message["ccRecipients"]) == [["address": "ann@example.com", "name": "Lee, Ann"]])
        #expect(Self.graphMailboxes(message["bccRecipients"]) == [["address": "zoe@example.com", "name": "Zoë Kim"]])
    }

    /// A recipient a draft or an earlier send stored: a list goes as each of its
    /// mailboxes and a group as its members, as on IMAP and Gmail; text any part
    /// of which names no mailbox goes whole, as before.
    @Test("Outlook reads a stored recipient as the mailboxes it names")
    func outlookReadsStoredRecipients() {
        let read = ExchangeProvider.graphRecipients([
            "a@example.com", "Ann <b@example.com>, c@example.com", "bob",
            "Team: Dee <d@example.com>, e@example.com;", "f@example.com, junk"
        ]).compactMap { $0["emailAddress"] as? [String: String] }
        #expect(read == [["address": "a@example.com"], ["address": "b@example.com", "name": "Ann"],
                         ["address": "c@example.com"], ["address": "bob"],
                         ["address": "d@example.com", "name": "Dee"], ["address": "e@example.com"],
                         ["address": "f@example.com, junk"]])
    }

    /// The bug this guards: an Outlook draft copy was read as bare addresses, so
    /// a draft reopened or adopted lost every name and its next save sent none.
    @Test("An Outlook draft copy is read with each recipient's name, and compose reads it back")
    func outlookDraftCopyKeepsNames() {
        func recipient(_ name: String?, _ address: String?) -> GraphRecipient {
            GraphRecipient(emailAddress: GraphEmailAddress(name: name, address: address))
        }
        let text = ExchangeProvider.draftRecipientText([
            recipient("Lee, Ann", "ann@example.com"),
            recipient("Quote \"Q\"", "q@example.com"),
            recipient("BOB@example.com", "bob@example.com"),
            recipient(nil, "carol@example.com"),
            recipient("", "dave@example.com"),
            recipient("Nobody", nil),
            recipient("Empty", "")
        ])
        #expect(text == #""Lee, Ann" <ann@example.com>, "Quote \"Q\"" <q@example.com>, "#
            + "bob@example.com, carol@example.com, dave@example.com")
        let read = RecipientEntry(text).recipients
        let readAddresses = read.map(\.address)
        let readNames = read.map(\.name)
        #expect(readAddresses
            == ["ann@example.com", "q@example.com", "bob@example.com", "carol@example.com", "dave@example.com"])
        #expect(readNames == ["Lee, Ann", "Quote \"Q\"", nil, nil, nil])
        #expect(ExchangeProvider.draftRecipientText(nil).isEmpty)
    }

    /// Only a draft copy is read with the names; every other Outlook read keeps
    /// each field's addresses alone, as before.
    @Test("An Outlook message is read with recipient names only as a draft copy", arguments: [false, true])
    func outlookReadKeepsNamesOnlyForDraftCopies(draftCopy: Bool) async throws {
        let received = ISO8601DateFormatter().string(from: Date())
        let json = """
            {"id":"m1","subject":"Names","receivedDateTime":"\(received)","isRead":false,"hasAttachments":false,\
            "toRecipients":[{"emailAddress":{"name":"Lee, Ann","address":"ann@example.com"}}],\
            "ccRecipients":[{"emailAddress":{"name":"Sam Lee","address":"sam@example.com"}},\
            {"emailAddress":{"address":"bob@example.com"}}],\
            "bccRecipients":[{"emailAddress":{"name":"Zoë Kim","address":"zoe@example.com"}}]}
            """
        let message = try JSONDecoder().decode(GraphMessage.self, from: Data(json.utf8))
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        // Header sync and every read but a draft copy's call it with no
        // `keepRecipientNames`, so the other row relies on its default.
        let parsed = await draftCopy
            ? provider.parseGraphMessage(message, selection: GraphAPI.headerOnlySelection, keepRecipientNames: true)
            : provider.parseGraphMessage(message, selection: GraphAPI.headerOnlySelection)
        let info = try #require(parsed)
        let to = RecipientEntry(info.to).recipients
        let cc = RecipientEntry(info.cc).recipients
        let bcc = RecipientEntry(info.bcc).recipients
        let addresses = [to.map(\.address), cc.map(\.address), bcc.map(\.address)]
        let names = [to.map(\.name), cc.map(\.name), bcc.map(\.name)]
        #expect(addresses == [["ann@example.com"], ["sam@example.com", "bob@example.com"], ["zoe@example.com"]])
        if draftCopy {
            #expect(names == [["Lee, Ann"], ["Sam Lee", nil], ["Zoë Kim"]])
        } else {
            let fields = [info.to, info.cc, info.bcc]
            #expect(fields == ["ann@example.com", "sam@example.com, bob@example.com", "zoe@example.com"])
        }
    }

    // MARK: - On the wire

    /// Names hard to write and read back, as `[name, address]`: a quote and a
    /// backslash, a name that looks like an address, a long non-ASCII name that
    /// takes several folded encoded-words, angle brackets, and a line break.
    private static let hardTo = [["Quote \"Q\" Back\\slash", "q@example.com"], ["other@example.com", "real@example.com"]]
    private static let hardCc = [[String(repeating: "長い名前", count: 6), "long@example.com"],
                                 ["A <b@example.com> C", "c@example.com"]]
    private static let hardBcc = [["Line\r\nBreak", "hidden@example.com"], ["Hidden Person", "hidden2@example.com"]]

    /// What Send hands the provider for the hard names; with a file, each
    /// provider writes it on its other route (a multipart message, or Graph's
    /// draft, upload and send).
    private static func hardDraft(file: Bool = false) -> DraftMessage {
        func texts(_ pairs: [[String]]) -> [String] { pairs.map { RecipientEntry.text(name: $0[0], address: $0[1]) } }
        var draft = DraftMessage(to: texts(hardTo), cc: texts(hardCc), bcc: texts(hardBcc), subject: "Names", body: "Body")
        if file { draft.attachments = [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))] }
        draft.messageId = "names-\(UUID().uuidString)@example.com"
        return draft
    }

    /// Text with each run of white space as one space: a reader may keep a
    /// fold's space or a line break written as a space.
    private static func spaced(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func expected(_ pairs: [[String]]) -> [[String]] {
        pairs.map { [spaced($0[0]), $0[1]] }
    }

    /// Every header field named `name`, each as the `[name, address]` of its
    /// mailboxes in order, read by SwiftMail's address reader.
    private static func written(_ name: String, in message: String) -> [[[String]]] {
        let head = GmailParse.unfolded(message.components(separatedBy: "\r\n\r\n").first ?? message)
        let prefix = name.lowercased() + ":"
        return head.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix(prefix) }.map { line in
            AddressParser.parseAddressList(String(line.dropFirst(prefix.count)))
                .flatMap(\.mailboxes).map { [spaced($0.name ?? ""), $0.address] }
        }
    }

    /// One To, one Cc and one Bcc field, each naming exactly its recipients in
    /// order under their names, in a 7-bit header.
    private static func expectHardNames(_ message: String, bcc: Bool = true, _ label: String) {
        let head = message.components(separatedBy: "\r\n\r\n").first ?? message
        let ascii = head.unicodeScalars.allSatisfy(\.isASCII)
        #expect(ascii, "\(label): a header is not 7-bit ASCII")
        let to = written("To", in: message)
        let cc = written("Cc", in: message)
        let writtenBcc = written("Bcc", in: message)
        #expect(to == [expected(hardTo)], "\(label): \(to)")
        #expect(cc == [expected(hardCc)], "\(label): \(cc)")
        #expect(writtenBcc == (bcc ? [expected(hardBcc)] : []), "\(label): \(writtenBcc)")
    }

    /// SMTP double that keeps each message the app submits.
    final class SubmittedMail: SMTPSubmissionSession {
        let emails = Mutex<[Email]>([])
        func openConnection() async throws {}
        func authenticate(username: String, password: String) async throws {}
        func submit(_ email: Email) async throws { emails.withLock { $0.append(email) } }
        func close() async throws {}
    }

    /// Through the app's own send: what it submits is what SwiftMail turns into
    /// RCPT TO (the envelope, every address once) and DATA (the message).
    @Test("SMTP sends to each address once, and the message it delivers names every To and Cc name and no Bcc")
    func smtpKeepsHardNames() async throws {
        let provider = IMAPProvider(
            host: "127.0.0.1", port: 1, username: "me@example.com", password: "password",
            senderEmail: "me@example.com", smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        let session = SubmittedMail()
        provider.setSMTPSessionFactoryForTesting { session }
        _ = try await provider.send(draft: Self.hardDraft())

        let submitted = session.emails.withLock { $0 }
        #expect(submitted.count == 1)
        guard submitted.count == 1 else { return }
        let email = submitted[0]
        let envelope = email.allRecipients.map(\.address)
        let everyAddress = (Self.hardTo + Self.hardCc + Self.hardBcc).map { $0[1] }
        #expect(envelope == everyAddress)
        let delivered = email.constructContent()
        Self.expectHardNames(delivered, bcc: false, "SMTP DATA")
        #expect(!delivered.contains("hidden@example.com") && !delivered.contains("hidden2@example.com"))
    }

    @Test("IMAP files a draft and a Sent copy with every name in To, Cc and Bcc")
    func imapKeepsHardNames() async throws {
        let server = FakeIMAPServer(mailboxes: ["Drafts": [], "Sent": []])
        server.setUidValidity(81_031, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let first = try await provider.saveDraft(Self.hardDraft(), existingIdentity: nil, draftsFolderPath: "Drafts")
        guard case .created(.imap(let folder, let uidValidity, let uid)) = first else {
            Issue.record("the first save gave no IMAP address: \(first)")
            return
        }
        let firstCopy = server.snapshotMessagesWithFlags(in: "Drafts")
        #expect(firstCopy.count == 1)
        guard firstCopy.count == 1 else { return }
        Self.expectHardNames(String(decoding: firstCopy[0].message.raw, as: UTF8.self), "IMAP first draft")
        let firstUid = firstCopy[0].message.uid

        // The next save replaces that copy, with the first To renamed since.
        var renamed = Self.hardDraft()
        renamed.to[0] = RecipientEntry.text(name: "Renamed Person", address: "q@example.com")
        _ = try await provider.saveDraft(
            renamed, existingIdentity: .imap(folder: folder, uidValidity: uidValidity, uid: uid),
            draftsFolderPath: "Drafts")
        let replaced = server.snapshotMessagesWithFlags(in: "Drafts")
        // One copy is left, and it is the replacement (its renamed To is checked
        // below). The old copy is expunged before the new one is appended, and
        // this server numbers an APPEND one above its highest UID still present,
        // so the replacement can get the old copy's UID here.
        let replacedUids = replaced.map(\.message.uid)
        #expect(replacedUids.count == 1, "Drafts UIDs \(replacedUids), first \(firstUid)")
        guard replaced.count == 1 else { return }
        let replacement = String(decoding: replaced[0].message.raw, as: UTF8.self)
        let replacedTo = Self.written("To", in: replacement)
        let replacedCc = Self.written("Cc", in: replacement)
        let replacedBcc = Self.written("Bcc", in: replacement)
        let renamedTo = [[["Renamed Person", "q@example.com"], Self.expected(Self.hardTo)[1]]]
        #expect(replacedTo == renamedTo)
        #expect(replacedCc == [Self.expected(Self.hardCc)])
        #expect(replacedBcc == [Self.expected(Self.hardBcc)])

        let sent = Self.hardDraft()
        let sentMessageId = try #require(sent.messageId)
        _ = try await provider.appendToSentFolder(draft: sent, sentFolderPath: "Sent", messageId: sentMessageId)
        let stored = server.snapshotMessagesWithFlags(in: "Sent")
        #expect(stored.count == 1)
        guard stored.count == 1 else { return }
        Self.expectHardNames(String(decoding: stored[0].message.raw, as: UTF8.self), "IMAP Sent")
    }

    /// What a draft another app saved is taken up from: an IMAP draft copy is
    /// read with each recipient's name in To, Cc and Bcc, so its next save and
    /// Send keep them.
    @Test("An IMAP draft copy is read with every recipient's name")
    func imapDraftCopyKeepsNames() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date())
        let text = "From: me@example.com\r\nTo: \"Lee, Ann\" <ann@example.com>, bob@example.com\r\n"
            + "Subject: Names\r\nDate: \(date)\r\nMessage-ID: <names@example.com>\r\n\r\nBody\r\n"
        var message = FakeIMAPServer.makeMessage(uid: 5, rfc822Text: text)
        let me = #"((NIL NIL "me" "example.com"))"#
        message.customEnvelope = #"(""# + date + #"" "Names" "# + me + " " + me + " " + me
            + #" (("Lee, Ann" NIL "ann" "example.com")(NIL NIL "bob" "example.com"))"#
            + #" (("Sam Lee" NIL "sam" "example.com"))"#
            + #" (("Hidden Person" NIL "hidden" "example.com")) NIL "<names@example.com>")"#
        let epoch = 81_032
        let server = FakeIMAPServer(mailboxes: ["Drafts": [message]])
        server.setUidValidity(epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let fetched = try await provider.fetchDraftCopy(identity: .imap(folder: "Drafts", uidValidity: epoch, uid: 5))
        let copy = try #require(fetched)
        let to = RecipientEntry(copy.header.to).recipients
        let cc = RecipientEntry(copy.header.cc).recipients
        let bcc = RecipientEntry(copy.header.bcc).recipients
        let addresses = [to.map(\.address), cc.map(\.address), bcc.map(\.address)]
        let names = [to.map(\.name), cc.map(\.name), bcc.map(\.name)]
        #expect(addresses == [["ann@example.com", "bob@example.com"], ["sam@example.com"], ["hidden@example.com"]])
        #expect(names == [["Lee, Ann", nil], ["Sam Lee"], ["Hidden Person"]])
    }

    @Test("Gmail sends, creates and updates a draft with every name in To, Cc and Bcc")
    func gmailKeepsHardNames() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/send", method: "POST", response: .json(raw: #"{"id":"sent-1"}"#))
        http.register(path: "/drafts", method: "POST", response: .json(raw: #"{"id":"r-1","message":{"id":"m-1"}}"#))
        http.register(path: "/drafts/r-1", method: "PUT", response: .json(raw: #"{"id":"r-1","message":{"id":"m-2"}}"#))
        let provider = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" }, session: http.session)

        for file in [false, true] {
            try await provider.send(draft: Self.hardDraft(file: file))
            _ = try await provider.saveDraft(Self.hardDraft(file: file), existingIdentity: nil, draftsFolderPath: "DRAFT")
            _ = try await provider.saveDraft(
                Self.hardDraft(file: file), existingIdentity: .gmail(resourceId: "r-1"), draftsFolderPath: "DRAFT")
        }

        let messages = http.recordedCalls().compactMap { call -> String? in
            guard let body = call.body,
                  let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let raw = (json["raw"] as? String) ?? ((json["message"] as? [String: Any])?["raw"] as? String)
            else { return nil }
            var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return String(decoding: Data(base64Encoded: base64) ?? Data(), as: UTF8.self)
        }
        #expect(messages.count == 6)
        // Only the last three are multipart, with the file.
        let withFile = messages.map { $0.contains("a.txt") }
        #expect(withFile == [false, false, false, true, true, true])
        for (index, message) in messages.enumerated() { Self.expectHardNames(message, "Gmail request \(index)") }
    }

    @Test("Outlook sends, creates and updates a draft with every name in To, Cc and Bcc")
    func outlookKeepsHardNames() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g-1"}"#))
        http.register(path: "/messages/g-1", method: "PATCH", response: .json(raw: #"{"id":"g-1"}"#))
        http.register(path: "/messages/g-1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "tok" }, session: http.session)

        try await provider.send(draft: Self.hardDraft())
        _ = try await provider.saveDraft(Self.hardDraft(), existingIdentity: nil, draftsFolderPath: "Drafts")
        _ = try await provider.saveDraft(Self.hardDraft(), existingIdentity: .outlook(graphId: "g-1"), draftsFolderPath: "Drafts")

        let bodies = http.recordedCalls().filter { $0.method != "GET" }.compactMap { call -> [String: Any]? in
            guard let body = call.body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            else { return nil }
            return (json["message"] as? [String: Any]) ?? json
        }
        #expect(bodies.count == 3)
        func pairs(_ list: Any?) -> [[String]] {
            (list as? [[String: Any]] ?? []).map { recipient in
                let emailAddress = recipient["emailAddress"] as? [String: Any] ?? [:]
                return [emailAddress["name"] as? String ?? "", emailAddress["address"] as? String ?? ""]
            }
        }
        for (index, body) in bodies.enumerated() {
            let to = pairs(body["toRecipients"])
            let cc = pairs(body["ccRecipients"])
            let bcc = pairs(body["bccRecipients"])
            // No name carries a line break; the rest of each name is exact.
            let names = (to + cc + bcc).map { $0[0] }
            let unbroken = names.allSatisfy { !$0.contains("\r") && !$0.contains("\n") }
            #expect(unbroken, "Outlook request \(index)")
            let spacedTo = to.map { [Self.spaced($0[0]), $0[1]] }
            let spacedCc = cc.map { [Self.spaced($0[0]), $0[1]] }
            let spacedBcc = bcc.map { [Self.spaced($0[0]), $0[1]] }
            #expect(spacedTo == Self.expected(Self.hardTo), "Outlook request \(index)")
            #expect(spacedCc == Self.expected(Self.hardCc), "Outlook request \(index)")
            #expect(spacedBcc == Self.expected(Self.hardBcc), "Outlook request \(index)")
        }
    }
}

/// Gmail serves a long header folded, sometimes inside a name (RFC 5322 2.2.3).
/// Sync and a push both store Bcc and Reply-To as one line, so a reply to a
/// folded Reply-To goes to each of its mailboxes under its whole name (#1031).
@Suite("Gmail reads a folded Bcc and Reply-To whole", .serialized, .processGlobalState)
struct GmailFoldedRecipientReadTests {
    private static let foldedBcc = "\"Hidden,\r\n Person\" <hidden@example.com>,\r\n other@example.com"
    private static let foldedReplyTo = "\"Desk,\r\n Help\" <help@example.com>, Ops\r\n Team <ops@example.com>"
    private static let bcc = #""Hidden, Person" <hidden@example.com>, other@example.com"#
    private static let replyTo = #""Desk, Help" <help@example.com>, Ops Team <ops@example.com>"#

    @Test("Sync stores a folded Bcc and Reply-To as one line, and Reply goes to each Reply-To name whole")
    func syncReadsFoldedFieldsWhole() async throws {
        let provider = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        let message = GmailMessage(
            id: "m1", threadId: nil, labelIds: ["INBOX"], snippet: nil,
            internalDate: String(Int64(Date().timeIntervalSince1970 * 1_000)),
            payload: GmailPayload(
                mimeType: nil,
                headers: [
                    GmailHeader(name: "Subject", value: "Folded"),
                    GmailHeader(name: "From", value: "Sender <sender@example.com>"),
                    GmailHeader(name: "To", value: "me@example.com"),
                    GmailHeader(name: "Bcc", value: Self.foldedBcc),
                    GmailHeader(name: "Reply-To", value: Self.foldedReplyTo),
                ],
                body: nil, parts: nil))
        let parsed = await provider.parseGmailMessage(message)
        let info = try #require(parsed)
        #expect(info.bcc == Self.bcc)
        #expect(info.replyTo == Self.replyTo)

        var header = MessageHeader(
            messageId: "m1", subject: "Folded", from: info.from, fromAddress: info.fromAddress,
            to: info.to, date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.replyTo = info.replyTo
        let reply = ComposeDraftGuards.fieldState(RecipientEntry.reply(to: header))
        let sent = ComposeDraftGuards.sendRecipients(to: reply, cc: .init(), bcc: .init())
        #expect(sent == .send(to: [#""Desk, Help" <help@example.com>"#, #""Ops Team" <ops@example.com>"#], cc: [], bcc: []))
    }

    @Test("A push stages a folded Bcc and Reply-To as one line, as sync stores them")
    func pushReadsFoldedFieldsWhole() async throws {
        let accountId = "nse-folded-" + UUID().uuidString
        let store = ProviderCredentialStore.shared
        _ = try store.install(accountId: accountId, tokens: .init(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(3_600)))
        defer { try? store.remove(accountId: accountId) }
        let server = StatefulGmailActionServer(messages: [
            StatefulGmailActionServer.Seed(
                rfc822MessageId: "push-folded@example.com", providerMessageId: "push-folded", labels: ["INBOX"],
                headers: ["Bcc": Self.foldedBcc, "Reply-To": Self.foldedReplyTo]),
        ])
        defer { server.close() }

        let meta = await AuthedHTTP.$sessionOverride.withValue(server.http.session) {
            await GmailNSEClient.fetchSingleMessage(
                messageId: "push-folded", accessToken: "", refreshToken: nil, accountId: accountId)
        }
        let staged = try #require(meta)
        #expect(staged.bcc == Self.bcc)
        #expect(staged.replyTo == Self.replyTo)
    }
}
