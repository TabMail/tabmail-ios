/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Network
import SafariServices
import Synchronization
import UIKit

/// Opens an ICS calendar file using the native iOS "Add to Calendar" dialog.
///
/// iOS only shows the native calendar import UI when Safari navigates to a `text/calendar`
/// MIME type. Third-party apps can't trigger this directly. The workaround:
/// 1. Start a tiny localhost HTTP server that serves the ICS file
/// 2. Present SFSafariViewController as an invisible sub-pixel sheet
/// 3. Server responds with ICS content as `Content-Type: text/calendar`
/// 4. iOS intercepts the calendar MIME type and shows the native "Add to Calendar" dialog
///
/// Dismissal is handled externally: re-tapping the ICS attachment tears down and re-presents,
/// and navigating away from the message calls `dismiss()`.
enum ICSCalendarImporter {

    // MARK: - Local HTTP Server

    private final class Server: @unchecked Sendable {
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "ics-server")

        /// Diagnostic counters. Both are mutated only from `queue` (the listener's and every
        /// connection's callback queue), so no additional synchronisation is needed.
        ///
        /// These exist because this server serves ONE request and then tears itself down in
        /// `handleConnection`'s send completion. If iOS ever issues a `HEAD` preflight, a range
        /// request, or a re-fetch, the second request arrives at a cancelled listener and the
        /// import dies silently. `requestCount > 1` or `sawRequestAfterStop` proves that
        /// happens; both staying at their initial values rules it out.
        private var requestCount = 0
        private var stopped = false
        private var sawRequestAfterStop = false

        /// Single-shot guard for `completion`.
        ///
        /// Deliberately NOT one of the `queue`-only counters above: the two failure
        /// paths inside `start` run on the CALLER's thread, before `listener.start`
        /// hands anything to `queue`, while every other resolution comes from the
        /// state handler on `queue`.
        ///
        /// Both directions are real. `stateUpdateHandler` can fire more than once
        /// (`.ready` → `.waiting` → `.ready`, and `.ready` → `.cancelled` on teardown),
        /// so resolving unguarded would present Safari twice for one tap; and until
        /// 2026-08-13 the failure states resolved ZERO times, which is what made a
        /// port conflict a silent no-op.
        private let completionResolved = Mutex(false)

        /// Deliver the caller's one and only answer — the bound port, or `nil` for
        /// "this server will never serve anything". EVERY terminal state of the
        /// listener must reach this exactly once.
        private func resolve(_ port: UInt16?, _ completion: @Sendable (UInt16?) -> Void) {
            let alreadyResolved = completionResolved.withLock { resolved -> Bool in
                defer { resolved = true }
                return resolved
            }
            guard !alreadyResolved else { return }
            completion(port)
        }

        func start(icsData: Data, completion: @escaping @Sendable (UInt16?) -> Void) {
            do {
                let params = NWParameters.tcp
                let port: NWEndpoint.Port = 18942

                // Bind to LOOPBACK ONLY — do not relax this to an all-interfaces bind.
                //
                // `NWListener(using: .tcp, on: port)` binds every interface by default. The only
                // consumer is the in-process SFSafariViewController below, which fetches
                // `http://127.0.0.1:<port>/invite.ics`, so a loopback-scoped bind is sufficient by
                // construction and keeps a local-only server off the network it has no reason to be on.
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
                do {
                    listener = try NWListener(using: params)
                } catch {
                    print("[ICSImport] Port \(port) in use, trying random port")
                    // Still loopback — the fallback must not widen the bind.
                    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                    listener = try NWListener(using: params)
                }
            } catch {
                print("[ICSImport] Failed to create listener: \(error)")
                resolve(nil, completion)
                return
            }
            guard let listener else {
                resolve(nil, completion)
                return
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection, icsData: icsData)
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port?.rawValue {
                        print("[ICSImport] Server listening on port \(port)")
                        self?.resolve(port, completion)
                    } else {
                        // `.ready` without a port is terminal for the CALLER either way:
                        // there is no URL to hand Safari. Resolving as a failure keeps the
                        // "exactly once, on every terminal state" contract; the old code
                        // fell through here and the caller was never told anything.
                        print("[ICSImport] Listener ready but reported no port")
                        self?.resolve(nil, completion)
                    }
                case .failed(let error):
                    print("[ICSImport] Listener failed: \(error)")
                    if DebugModeManager.isLoggingEnabled() {
                        print("[ICSImport][diag] .failed reached — resolving with no port;"
                              + " Safari will NOT be presented and the user gets silence")
                    }
                    self?.stop()
                    self?.resolve(nil, completion)
                case .cancelled:
                    // Also terminal, and reachable before `.ready` ever fires: `stop()`
                    // runs from the 2-minute safety timer and from `teardown()`. Without
                    // this the caller's closure is simply dropped on the floor. When the
                    // port was already delivered the single-shot guard makes it a no-op.
                    self?.resolve(nil, completion)
                default:
                    break
                }
            }

            listener.start(queue: queue)

            // Safety: stop server after 2 minutes if nothing happened
            queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.stop()
            }
        }

        private func handleConnection(_ connection: NWConnection, icsData: Data) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
                if let error {
                    print("[ICSImport] Receive error: \(error)")
                    connection.cancel()
                    return
                }
                if let self {
                    self.requestCount += 1
                    if self.stopped { self.sawRequestAfterStop = true }
                }
                if let data, let request = String(data: data, encoding: .utf8) {
                    let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                    print("[ICSImport] Request: \(firstLine)")
                    if DebugModeManager.isLoggingEnabled() {
                        let n = self?.requestCount ?? 0
                        let late = (self?.sawRequestAfterStop ?? false) ? " ⚠️ ARRIVED AFTER stop()" : ""
                        print("[ICSImport][diag] request #\(n)\(late) — full request head follows")
                        // The whole head, not just the first line: the HTTP verb tells a GET from a
                        // HEAD preflight, and `Accept:` says whether iOS is asking for calendar data
                        // or for something else entirely.
                        for line in request.components(separatedBy: "\r\n") where !line.isEmpty {
                            print("[ICSImport][diag]   > \(line)")
                        }
                    }
                }

                var header = "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: text/calendar; charset=utf-8\r\n"
                header += "Content-Disposition: attachment; filename=\"invite.ics\"\r\n"
                header += "Content-Length: \(icsData.count)\r\n"
                header += "Connection: close\r\n"
                header += "\r\n"

                if DebugModeManager.isLoggingEnabled() {
                    // Logged verbatim because the leading hypothesis for the update-only failure is
                    // a missing iTIP `method=` parameter here (RFC 6047 §2.1); this line is what
                    // confirms or kills it without reading the source.
                    print("[ICSImport][diag] response head: "
                          + header.replacingOccurrences(of: "\r\n", with: " | "))
                }

                var responseData = Data(header.utf8)
                responseData.append(icsData)

                let server = self
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    if DebugModeManager.isLoggingEnabled() {
                        print("[ICSImport][diag] response sent; cancelling connection and stopping server"
                              + " — any further request from iOS will find no listener")
                    }
                    connection.cancel()
                    server?.stop()
                })
            }
        }

        func stop() {
            if DebugModeManager.isLoggingEnabled() {
                print("[ICSImport][diag] stop() — listener=\(listener == nil ? "already nil" : "cancelling")"
                      + " requestsServed=\(requestCount)"
                      + " sawRequestAfterStop=\(sawRequestAfterStop)"
                      + " alreadyStopped=\(stopped)")
            }
            stopped = true
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Safari Delegate

    private final class SafariDelegate: NSObject, SFSafariViewControllerDelegate, @unchecked Sendable {
        static let shared = SafariDelegate()

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            print("[ICSImport] Safari dismissed by user")
            Task { @MainActor in ICSCalendarImporter.teardown() }
        }
    }

    // MARK: - State

    private nonisolated(unsafe) static var activeServer: Server?
    /// Strong reference — `weak` causes premature deallocation after teardown,
    /// making subsequent taps fail because topViewController() returns a zombie.
    private nonisolated(unsafe) static var activeSafari: SFSafariViewController?
    private nonisolated(unsafe) static var sceneObserver: NSObjectProtocol?

    /// Whether an ICS import Safari sheet is currently presented.
    static var isActive: Bool { activeSafari != nil }

    // MARK: - Diagnostics

    /// Diagnostic fingerprint of an iCalendar payload — **iTIP scheduling fields only**.
    ///
    /// Exists to answer one question from a device log without guessing: *is this payload a
    /// first-time invite or an update, and does it still carry what iOS needs to tell them
    /// apart?* `METHOD`, `UID`, `SEQUENCE` and `RECURRENCE-ID` are exactly the fields that
    /// route a payload down the iTIP scheduling path instead of a plain calendar import.
    ///
    /// Deliberately does NOT log `SUMMARY` / `DESCRIPTION` / `LOCATION` / attendee
    /// addresses. Those are user content and none of them discriminate an update from an
    /// invite, so logging them would be cost without diagnostic value. `UID` is shown as a
    /// display-side prefix plus its length — enough to compare across two taps, which is all
    /// the update question needs.
    ///
    /// ⚠️ **Unfolds first (RFC 5545 §3.1), and the ORDER is the whole point.** A value
    /// longer than the physical-line limit continues on the next line, and the marker
    /// for a continuation is that the line BEGINS WITH SPACE OR HTAB. Splitting into
    /// physical lines and trimming each one — which is what this did until 2026-08-13 —
    /// destroys that marker before anything can read it, so every long value was
    /// reported at its FOLD WIDTH rather than its length, silently and with no sign
    /// that anything had been cut.
    ///
    /// That is not a hypothetical: a device log read one event's `UID` as `(len 71)`
    /// raw and `(len 70)` sanitized, which reads exactly like the sanitizer corrupting
    /// iTIP identity. It is not. `ICSSanitizerConfig.physicalLineOctetLimit` is 75 and
    /// `foldWidthOctets` is 74, so 75 - `"UID:".count` = 71 is the SENDER's fold width
    /// and 74 - `"UID:".count` = 70 is ours. Both numbers were fold widths; the UID's
    /// true length was never measured and never changed — the byte counts were
    /// identical on both lines. The instrument manufactured a false corruption signal
    /// in the one place it exists to rule one out.
    ///
    /// Internal rather than private so the unfold invariant is testable; the only
    /// production caller is still the debug-gated pair in `presentCalendarImport`.
    static func itipFingerprint(_ data: Data, label: String) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "[ICSImport][diag] \(label): NOT valid UTF-8, \(data.count) B"
        }
        // Join continuation lines onto their predecessor BEFORE any trimming. Same four
        // replacements as `ICSBuilder.parseIncoming` / `ICSParser.unfold`, written out
        // here rather than reached for across the CalDAV boundary.
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        let lines = unfolded.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func value(of key: String) -> String {
            for line in lines {
                let upper = line.uppercased()
                guard upper.hasPrefix("\(key):") || upper.hasPrefix("\(key);") else { continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                return String(line[line.index(after: colon)...])
            }
            return "<absent>"
        }
        func occurrences(of key: String) -> Int {
            lines.reduce(0) { total, line in
                let upper = line.uppercased()
                return total + ((upper.hasPrefix("\(key):") || upper.hasPrefix("\(key);")) ? 1 : 0)
            }
        }
        let uid = value(of: "UID")
        let uidShown = uid == "<absent>" ? uid : "\(uid.prefix(12))…(len \(uid.count))"
        return "[ICSImport][diag] \(label): \(data.count) B"
            + " METHOD=\(value(of: "METHOD"))"
            + " SEQUENCE=\(value(of: "SEQUENCE"))"
            + " RECURRENCE-ID=\(value(of: "RECURRENCE-ID"))"
            + " STATUS=\(value(of: "STATUS"))"
            + " DTSTAMP=\(value(of: "DTSTAMP"))"
            + " UID=\(uidShown)"
            + " VEVENT=\(lines.filter { $0.uppercased() == "BEGIN:VEVENT" }.count)"
            + " ATTENDEE=\(occurrences(of: "ATTENDEE"))"
            + " ORGANIZER=\(value(of: "ORGANIZER") == "<absent>" ? "absent" : "present")"
    }

    // MARK: - Public API

    @MainActor
    static func presentCalendarImport(icsData: Data) {
        // Clean the invite before it reaches the OS: strip pathological bloat
        // (e.g. a 79 KB X-ALT-DESC) and repair RFC violations that otherwise wedge
        // iOS↔Google calendar sync. Covers both the real and demo paths below.
        let rawICSData = icsData
        let icsData = ICSSanitizer.sanitize(icsData)

        // Logged as a PAIR so the sanitizer is measured, not argued about: if an update
        // stops being recognisable as one, these two lines say whether it arrived that way
        // or whether we made it that way.
        if DebugModeManager.isLoggingEnabled() {
            print(itipFingerprint(rawICSData, label: "raw, as received"))
            print(itipFingerprint(icsData, label: "sanitized, as served to iOS"))
        }
        print("[ICSImport] presentCalendarImport called, activeSafari=\(activeSafari != nil)")
        // In demo mode, ICS imports MUST NOT touch the
        // real EKEventStore (would persist past demo exit). Route to the
        // demo calendar provider instead.
        if DemoModeStore.shared.isActive {
            Task { await Self.importIntoDemoCalendar(icsData: icsData) }
            return
        }
        // Always teardown first, then present after a delay to let UIKit process the dismiss.
        let hadActiveSession = activeSafari != nil
        teardown()
        let delay: TimeInterval = hadActiveSession ? 0.3 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            beginPresentation(icsData: icsData)
        }
    }

    /// Demo-mode ICS import path. Parses the ICS and writes the resulting
    /// event into `DemoCalendarProvider` (backed by `demoCalendarEvent` table).
    /// EKEventStore is not touched.
    private static func importIntoDemoCalendar(icsData: Data) async {
        guard let icsText = String(data: icsData, encoding: .utf8) else { return }
        let events = ICSParser.parse(icsText: icsText, resourceHref: "demo-import-\(UUID().uuidString.prefix(8))", etag: nil)
        guard let first = events.first else {
            print("[ICSImport] Demo: no events parsed from ICS")
            return
        }
        guard let provider = await AccountManager.shared.calendarProviders[DemoSeed.demoAccountId] else {
            print("[ICSImport] Demo: no demo calendar provider registered")
            return
        }
        var input = GCalEventInput()
        input.summary = first.summary
        input.location = first.location
        input.description = first.description
        input.startDateTime = first.start?.dateTime
        input.startDate = first.start?.date
        input.endDateTime = first.end?.dateTime
        input.endDate = first.end?.date
        do {
            _ = try await provider.createEvent(calendarId: "primary", event: input, sendUpdates: "none")
            print("[ICSImport] Demo: imported '\(first.summary ?? "(no title)")' into demo calendar")
        } catch {
            print("[ICSImport] Demo import failed: \(error)")
        }
    }

    @MainActor
    private static func beginPresentation(icsData: Data) {
        print("[ICSImport] beginPresentation")
        let server = Server()
        activeServer = server

        server.start(icsData: icsData) { port in
            DispatchQueue.main.async {
                // `nil` means the listener reached a terminal state without ever
                // binding — a port conflict surfacing asynchronously as `.failed`, or a
                // cancel before `.ready`. Nothing will ever be served, so release the
                // dead server instead of parking it in `activeServer` until the next
                // tap happens to tear it down. Identity-checked because a newer
                // presentation may already own the slot.
                guard let port else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[ICSImport][diag] server resolved with no port —"
                              + " Safari will NOT be presented")
                    }
                    if activeServer === server { activeServer = nil }
                    return
                }
                guard let url = URL(string: "http://127.0.0.1:\(port)/invite.ics") else {
                    print("[ICSImport] Invalid URL for port \(port)")
                    return
                }
                print("[ICSImport] Opening Safari with \(url)")

                let safari = SFSafariViewController(url: url)
                safari.delegate = SafariDelegate.shared
                safari.modalPresentationStyle = .pageSheet

                if let sheet = safari.sheetPresentationController {
                    let id = UISheetPresentationController.Detent.Identifier("ics")
                    sheet.detents = [.custom(identifier: id) { _ in 0.01 }]
                    sheet.prefersGrabberVisible = false
                    sheet.largestUndimmedDetentIdentifier = id
                }

                activeSafari = safari

                guard let presenter = Self.topViewController() else {
                    print("[ICSImport] No view controller to present from")
                    server.stop()
                    activeServer = nil
                    activeSafari = nil
                    return
                }
                print("[ICSImport] Presenting from \(type(of: presenter))")
                presenter.present(safari, animated: false) {
                    // Remove the shadow from UIDropShadowView (thin line at sheet edge)
                    var v: UIView? = safari.view.superview
                    while let view = v, !(view is UIWindow) {
                        if String(describing: type(of: view)) == "UIDropShadowView" {
                            view.layer.shadowOpacity = 0
                            break
                        }
                        v = view.superview
                    }
                    print("[ICSImport] Safari presented successfully")
                }

                startSceneObserver()
            }
        }
    }

    @MainActor
    static func presentCalendarImport(icsText: String) {
        guard let data = icsText.data(using: .utf8) else { return }
        presentCalendarImport(icsData: data)
    }

    /// Dismiss any active ICS import session.
    @MainActor
    static func dismiss() {
        teardown()
    }

    // MARK: - Scene Observer

    /// Dismiss the import sheet when the scene enters background.
    private static func startSceneObserver() {
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[ICSImport] Scene entered background, cleaning up")
            Task { @MainActor in teardown() }
        }
    }

    // MARK: - Cleanup

    @MainActor
    private static func teardown() {
        print("[ICSImport] teardown called, activeSafari=\(activeSafari != nil)")

        if let obs = sceneObserver {
            NotificationCenter.default.removeObserver(obs)
            sceneObserver = nil
        }

        activeServer?.stop()
        activeServer = nil

        activeSafari?.dismiss(animated: false)
        activeSafari = nil
    }

    // MARK: - Helpers

    @MainActor
    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var vc = window.rootViewController else { return nil }
        while let next = vc.presentedViewController {
            vc = next
        }
        return vc
    }
}
