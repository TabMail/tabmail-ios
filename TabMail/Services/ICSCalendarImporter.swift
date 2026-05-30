/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Network
import SafariServices
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

        func start(icsData: Data, completion: @escaping @Sendable (UInt16) -> Void) {
            do {
                let params = NWParameters.tcp
                let port: NWEndpoint.Port = 18942
                do {
                    listener = try NWListener(using: params, on: port)
                } catch {
                    print("[ICSImport] Port \(port) in use, trying random port")
                    listener = try NWListener(using: params, on: .any)
                }
            } catch {
                print("[ICSImport] Failed to create listener: \(error)")
                return
            }
            guard let listener else { return }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection, icsData: icsData)
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener?.port?.rawValue {
                        print("[ICSImport] Server listening on port \(port)")
                        completion(port)
                    }
                case .failed(let error):
                    print("[ICSImport] Listener failed: \(error)")
                    self?.stop()
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
                if let data, let request = String(data: data, encoding: .utf8) {
                    let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                    print("[ICSImport] Request: \(firstLine)")
                }

                var header = "HTTP/1.1 200 OK\r\n"
                header += "Content-Type: text/calendar; charset=utf-8\r\n"
                header += "Content-Disposition: attachment; filename=\"invite.ics\"\r\n"
                header += "Content-Length: \(icsData.count)\r\n"
                header += "Connection: close\r\n"
                header += "\r\n"

                var responseData = Data(header.utf8)
                responseData.append(icsData)

                let server = self
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                    server?.stop()
                })
            }
        }

        func stop() {
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

    // MARK: - Public API

    @MainActor
    static func presentCalendarImport(icsData: Data) {
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
