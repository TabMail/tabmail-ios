/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Darwin
import Dispatch
import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Ordered teardown for a fixture's on-disk test databases: **close every
/// owned `DatabasePool`/`DatabaseQueue` first, unlink their shared directory
/// second — never the reverse, and never the unlink alone.**
///
/// **The defect this closes.** The dominant test-fixture idiom in this target is
///
/// ```swift
/// let (pool, dir, previous) = try makeTestDB()
/// defer {
///     AppDatabase.shared.withLock { $0 = previous }
///     try? FileManager.default.removeItem(at: dir)   // pool still open
/// }
/// ```
///
/// An awaited `dbPool.write { }` returns once the transaction commits, but the
/// `DatabasePool` still owns a background reader-connection pool that is *not*
/// torn down just because the write finished. Removing the directory under it
/// unlinks `tabmail.sqlite`/`-wal`/`-shm` while those connections still hold
/// them open, and libsqlite3 reports
///
/// ```
/// BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by
/// API violation: vnode unlinked while in use: …/test.sqlite
/// ```
///
/// That is a genuine **process-wide** API violation, not merely a log line:
/// libsqlite3 shares its mutex/allocator subsystem across every connection in
/// the process, so it can corrupt state for ANY other concurrently-running
/// suite's SQLite use — including unrelated in-memory `DatabaseQueue`s. A full
/// suite run at `3a79f49` logged 2756 of these, which is why "the suite went
/// green" is not by itself a trustworthy signal.
///
/// `OutboxEpochCaptureTests` (see its type-level comment) diagnosed and fixed
/// this for one fixture with a suite-private deferred close/unlink pair. This
/// type generalises exactly that discipline so it is structural rather than
/// re-derived per fixture.
///
/// **Why the close is deferred by one retirement rather than run inline.**
/// Production spawns fire-and-forget tasks that outlive the test that triggered
/// them (see `TestAppDatabaseSink` for the catalogue). Closing a pool inside the
/// very `defer` that retires it can therefore pull the database out from under
/// work that has not finished unwinding. Holding each retired fixture until the
/// *next* retirement gives that residual activity a full fixture lifetime to
/// quiesce. The last fixture handed over has no *next* retirement to close it,
/// so the registered process-exit flush drains whatever is still parked —
/// otherwise the deferral would silently mean "never" for one pool per process.
///
/// **Why a failed close never unlinks.** A connection that refuses to close
/// still holds its file descriptors, so unlinking its directory anyway would
/// reproduce the exact violation this type exists to prevent. Successful
/// siblings are dropped; only the connections that failed remain grouped with
/// the directory and are retried on a later retirement.
///
/// Real GRDB `close()` may block until borrowed access has quiesced. The
/// lifecycle mutex intentionally remains held through that close and the
/// conditional unlink, serializing every registry transition for the directory.
/// The injected failure seam below does not model GRDB timing; it pins the
/// narrower safety invariant that any close error forbids unlink. `retire`
/// remains callable from any isolation domain.
enum TestDatabaseTeardown {

    /// Cross-process ownership proof for a fixture directory. The canonical
    /// marker is published only after its inode is exclusively locked, so a
    /// concurrently starting test host can never observe an unlocked marker
    /// for a live owner. A hard process exit releases the kernel lock; the next
    /// test host may then remove the stale directory without touching a live
    /// SQLite vnode.
    private final class DirectoryLease: @unchecked Sendable {
        private static let markerName = ".tabmail-test-fixture-owner-v1.lock"

        let directory: URL
        private let descriptor: Int32

        private init(directory: URL, descriptor: Int32) {
            self.directory = directory
            self.descriptor = descriptor
        }

        deinit {
            _ = Darwin.close(descriptor)
        }

        private static func eligibleDirectory(_ directory: URL) -> URL? {
            let standardized = directory.standardizedFileURL
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
            guard standardized.deletingLastPathComponent() == temporaryRoot else { return nil }
            guard let values = try? standardized.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true else {
                return nil
            }
            return standardized
        }

        /// `O_EXLOCK` asks Darwin to obtain the advisory lock atomically with
        /// `open`; paired with `O_CREAT | O_EXCL`, another host can observe
        /// either no marker or an already-locked canonical inode, never an
        /// unlocked marker for a live fixture.
        static func acquire(for directory: URL) -> DirectoryLease? {
            guard let directory = eligibleDirectory(directory) else { return nil }
            let marker = directory.appendingPathComponent(markerName, isDirectory: false)
            let descriptor = Darwin.open(
                marker.path,
                O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { return nil }
            return DirectoryLease(directory: directory, descriptor: descriptor)
        }

        private static func lockedDescriptorMatchesMarker(
            _ descriptor: Int32,
            marker: URL
        ) -> Bool {
            var descriptorStat = stat()
            var markerStat = stat()
            guard Darwin.fstat(descriptor, &descriptorStat) == 0,
                  Darwin.lstat(marker.path, &markerStat) == 0,
                  (markerStat.st_mode & S_IFMT) == S_IFREG else {
                return false
            }
            return descriptorStat.st_dev == markerStat.st_dev
                && descriptorStat.st_ino == markerStat.st_ino
        }

        /// Deletes children before the marker, so any child-removal failure
        /// leaves the ownership proof available for a later host to retry.
        /// If a child reappears after the marker unlink and defeats the final
        /// `rmdir`, republish the canonical marker atomically so the directory
        /// remains visible to a later host instead of becoming a permanent
        /// unmarked leak.
        @discardableResult
        private static func removeOwnedDirectory(_ rawDirectory: URL) -> Bool {
            guard let directory = eligibleDirectory(rawDirectory) else { return false }
            let fileManager = FileManager.default
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { return false }
            for child in children where child.lastPathComponent != markerName {
                do {
                    try fileManager.removeItem(at: child)
                } catch {
                    return false
                }
            }
            let marker = directory.appendingPathComponent(markerName, isDirectory: false)
            guard Darwin.unlink(marker.path) == 0 else { return false }
            if TestDatabaseTeardown.shouldForceRmdirObstructionForTesting(
                directory: directory
            ) {
                _ = fileManager.createFile(
                    atPath: directory
                        .appendingPathComponent(".tabmail-test-rmdir-obstruction")
                        .path,
                    contents: Data()
                )
            }
            guard Darwin.rmdir(directory.path) == 0 else {
                let replacementDescriptor = Darwin.open(
                    marker.path,
                    O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
                if replacementDescriptor >= 0 {
                    _ = Darwin.close(replacementDescriptor)
                }
                return false
            }
            return true
        }

        @discardableResult
        func removeOwnedDirectory() -> Bool {
            Self.removeOwnedDirectory(directory)
        }

        /// Removes only direct children of NSTemporaryDirectory that carry the
        /// exact marker and whose advisory lock can be acquired non-blocking.
        /// A successful lock is the proof that no registered owner process is
        /// alive. Symlinked directories and marker symlinks are rejected.
        static func reapStaleDirectories(excluding liveDirectories: Set<URL>) {
            let fileManager = FileManager.default
            let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
            let candidates = (try? fileManager.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []

            for rawDirectory in candidates {
                guard let directory = eligibleDirectory(rawDirectory) else { continue }
                guard !liveDirectories.contains(directory) else { continue }
                let marker = directory.appendingPathComponent(markerName, isDirectory: false)
                let descriptor = Darwin.open(
                    marker.path,
                    O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else { continue }
                defer { _ = Darwin.close(descriptor) }
                guard lockedDescriptorMatchesMarker(descriptor, marker: marker) else { continue }
                _ = removeOwnedDirectory(directory)
            }
        }

        static func createUnlockedMarkerForTesting(directory: URL) throws {
            guard let directory = eligibleDirectory(directory) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let marker = directory.appendingPathComponent(markerName, isDirectory: false)
            guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private enum Connection: @unchecked Sendable {
        case pool(DatabasePool)
        case queue(DatabaseQueue)

        var identity: ObjectIdentifier {
            switch self {
            case .pool(let pool): ObjectIdentifier(pool)
            case .queue(let queue): ObjectIdentifier(queue)
            }
        }

        func close() throws {
            switch self {
            case .pool(let pool): try pool.close()
            case .queue(let queue): try queue.close()
            }
        }
    }

    private struct Retired: Sendable {
        let connections: [Connection]
        let directory: URL
        let exitOnly: Bool
        let lease: DirectoryLease

        func contains(_ identity: ObjectIdentifier) -> Bool {
            connections.contains { $0.identity == identity }
        }
    }

    private struct RegistryState: Sendable {
        var entries: [Retired] = []
    }

    /// One lifecycle registry owns every directory. Its mutex is deliberately
    /// held from group selection through close and unlink: no retirement or
    /// process-exit registration can split a standardized directory between
    /// registries or appear in the former extraction/unlink window.
    ///
    /// Callers still have one mandatory boundary condition: register the
    /// complete set of already-known connections for a directory atomically in
    /// one `pools`/`queues` call. The registry serializes and merges ownership;
    /// it cannot discover an unregistered connection constructed elsewhere.
    private static let registry = Mutex(RegistryState())

    /// Deterministic close-error seam for teardown invariant tests. It bypasses
    /// real GRDB close for the selected identity and proves that the error path
    /// retains the connection and forbids unlink; it is not a quiescence model.
    /// This file is compiled only into the test target.
    private static let forcedCloseFailures = Mutex<Set<ObjectIdentifier>>([])

    /// Deterministic final-rmdir failure seam. It creates one late child only
    /// after the canonical marker has been unlinked, modelling a file that
    /// reappears between the child sweep and `rmdir`.
    private static let forcedRmdirObstructions = Mutex<Set<URL>>([])

    private static func shouldForceRmdirObstructionForTesting(directory: URL) -> Bool {
        let standardizedDirectory = directory.standardizedFileURL
        return forcedRmdirObstructions.withLock { $0.contains(standardizedDirectory) }
    }

    static func forceRmdirObstructionForTesting(directory: URL, enabled: Bool) {
        let standardizedDirectory = directory.standardizedFileURL
        forcedRmdirObstructions.withLock {
            if enabled {
                _ = $0.insert(standardizedDirectory)
            } else {
                _ = $0.remove(standardizedDirectory)
            }
        }
    }

    /// Stale-owner reclamation runs once before this process registers its
    /// first fixture. It is intentionally test-target-only and recognizes only
    /// directories carrying the exact lease marker above.
    private static let staleReapPrepared = Mutex<Bool>(false)

    /// Exit-owned action fixtures deliberately keep live SQLite connections
    /// until the process boundary. The simulator test host otherwise inherits
    /// a soft descriptor ceiling that a complete suite can exhaust even though
    /// every fixture has a bounded close-before-unlink path. Raise only the
    /// test process's soft ceiling, once; never alter the hard ceiling.
    private static let fileDescriptorBudgetPrepared = Mutex<Bool>(false)
    private static let minimumFileDescriptorBudget: rlim_t = 4_096
    private static let requestedFileDescriptorBudget: rlim_t = 10_240

    private static func prepareFileDescriptorBudget() {
        fileDescriptorBudgetPrepared.withLock { prepared in
            guard !prepared else { return }

            var limits = rlimit()
            precondition(
                Darwin.getrlimit(RLIMIT_NOFILE, &limits) == 0,
                "Unable to read the XCTest host file-descriptor limit"
            )
            let target = min(requestedFileDescriptorBudget, limits.rlim_max)
            precondition(
                target >= minimumFileDescriptorBudget,
                "XCTest host hard file-descriptor limit is below the required fixture budget"
            )
            if limits.rlim_cur < target {
                limits.rlim_cur = target
                precondition(
                    Darwin.setrlimit(RLIMIT_NOFILE, &limits) == 0,
                    "Unable to raise the XCTest host file-descriptor limit"
                )
            }
            prepared = true
        }
    }

    static func fileDescriptorSoftLimitForTesting() -> rlim_t {
        var limits = rlimit()
        precondition(
            Darwin.getrlimit(RLIMIT_NOFILE, &limits) == 0,
            "Unable to read the XCTest host file-descriptor limit"
        )
        return limits.rlim_cur
    }

    static func prepareProcess() {
        prepareFileDescriptorBudget()
        let shouldReap = staleReapPrepared.withLock { prepared -> Bool in
            if prepared { return false }
            prepared = true
            return true
        }
        guard shouldReap else { return }
        DirectoryLease.reapStaleDirectories(excluding: [])
    }

    static func reapStaleDirectoriesForTesting() {
        let liveDirectories = registry.withLock { state in
            Set(state.entries.map { $0.lease.directory.standardizedFileURL })
        }
        DirectoryLease.reapStaleDirectories(excluding: liveDirectories)
    }

    static func reapStaleDirectoriesAsCompetingHostForTesting() {
        DirectoryLease.reapStaleDirectories(excluding: [])
    }

    static func createUnlockedStaleMarkerForTesting(directory: URL) throws {
        try DirectoryLease.createUnlockedMarkerForTesting(directory: directory)
    }

    /// Exact-pool inspection for teardown-policy invariant tests.
    static func isPendingForTesting(pool: DatabasePool) -> Bool {
        let identity = ObjectIdentifier(pool)
        return registry.withLock { state in
            state.entries.contains { !$0.exitOnly && $0.contains(identity) }
        }
    }

    static func isRegisteredForProcessExitForTesting(pool: DatabasePool) -> Bool {
        let identity = ObjectIdentifier(pool)
        return registry.withLock { state in
            state.entries.contains { $0.exitOnly && $0.contains(identity) }
        }
    }

    static func processExitRegistrationCountForTesting(pool: DatabasePool) -> Int {
        let identity = ObjectIdentifier(pool)
        return registry.withLock { state in
            state.entries.filter { $0.exitOnly && $0.contains(identity) }.count
        }
    }

    static func connectionCountForTesting(directory: URL) -> Int {
        let standardizedDirectory = directory.standardizedFileURL
        return registry.withLock { state in
            state.entries
                .filter { $0.directory.standardizedFileURL == standardizedDirectory }
                .flatMap(\.connections)
                .count
        }
    }

    static func forceCloseFailureForTesting(pool: DatabasePool, enabled: Bool) {
        let identity = ObjectIdentifier(pool)
        forcedCloseFailures.withLock {
            if enabled {
                _ = $0.insert(identity)
            } else {
                _ = $0.remove(identity)
            }
        }
    }

    /// Whether the process-exit flush has been registered yet.
    private static let exitFlushRegistered = Mutex<Bool>(false)

    /// Registers the close-before-unlink flush as an `atexit` handler, once.
    ///
    /// Without it the deferral is unbounded on its last step: `retire` always
    /// parks the fixture it was just handed, so the most recently retired pool
    /// and its temp directory are never closed or unlinked at all. Draining
    /// them at process exit bounds the leak at "one fixture, until the test
    /// process ends" rather than "one fixture, forever".
    private static func registerExitFlushIfNeeded() {
        prepareProcess()
        let needsRegistration = exitFlushRegistered.withLock { registered -> Bool in
            if registered { return false }
            registered = true
            return true
        }
        guard needsRegistration else { return }
        atexit { TestDatabaseTeardown.flushAllRegistered() }
    }

    private static func uniqueConnections(_ connections: [Connection]) -> [Connection] {
        var seen: Set<ObjectIdentifier> = []
        return connections.filter { seen.insert($0.identity).inserted }
    }

    private static func makeEntry(
        connections: [Connection],
        directory: URL,
        exitOnly: Bool,
        state: RegistryState
    ) -> Retired {
        let standardizedDirectory = directory.standardizedFileURL
        let existingLease = state.entries.first {
            $0.directory.standardizedFileURL == standardizedDirectory
        }?.lease
        guard let lease = existingLease ?? DirectoryLease.acquire(for: directory) else {
            preconditionFailure(
                "Test fixture directory must be an owned direct child of NSTemporaryDirectory: \(directory.path)"
            )
        }
        return Retired(
            connections: connections,
            directory: directory,
            exitOnly: exitOnly,
            lease: lease
        )
    }

    /// Merges by standardized directory and by connection identity. `exitOnly`
    /// is sticky: once any sibling requires the process boundary, ordinary
    /// retirement can never downgrade or independently unlink that directory.
    /// Identity filtering covers both already-parked state and duplicates in a
    /// single incoming group, so `[pool, pool]` closes exactly once.
    private static func appendUnique(_ entries: [Retired], to parked: inout [Retired]) {
        for rawEntry in entries {
            let incomingConnections = uniqueConnections(rawEntry.connections)
            guard !incomingConnections.isEmpty else { continue }

            let incomingIdentities = Set(incomingConnections.map(\.identity))
            let standardizedDirectory = rawEntry.directory.standardizedFileURL
            precondition(
                !parked.contains { parkedEntry in
                    parkedEntry.directory.standardizedFileURL != standardizedDirectory
                        && parkedEntry.connections.contains {
                            incomingIdentities.contains($0.identity)
                        }
                },
                "A test database connection cannot be registered under multiple directories"
            )
            let matchingIndices = parked.indices.filter { index in
                let parkedEntry = parked[index]
                return parkedEntry.directory.standardizedFileURL == standardizedDirectory
                    || parkedEntry.connections.contains {
                        incomingIdentities.contains($0.identity)
                    }
            }

            guard !matchingIndices.isEmpty else {
                parked.append(Retired(
                    connections: incomingConnections,
                    directory: rawEntry.directory,
                    exitOnly: rawEntry.exitOnly,
                    lease: rawEntry.lease
                ))
                continue
            }

            let matchedEntries = matchingIndices.map { parked[$0] }
            let mergedConnections = uniqueConnections(
                matchedEntries.flatMap(\.connections) + incomingConnections
            )
            let mergedExitOnly = rawEntry.exitOnly
                || matchedEntries.contains { $0.exitOnly }
            let mergedDirectory = matchedEntries.first(where: {
                $0.directory.standardizedFileURL == standardizedDirectory
            })?.directory ?? matchedEntries[0].directory

            for index in matchingIndices.reversed() {
                parked.remove(at: index)
            }
            parked.append(Retired(
                connections: mergedConnections,
                directory: mergedDirectory,
                exitOnly: mergedExitOnly,
                lease: matchedEntries.first?.lease ?? rawEntry.lease
            ))
        }
    }

    /// Closes first and unlinks second. Real GRDB close may block for borrowed
    /// access. A real or injected close failure returns the connection to its
    /// registry, still strongly retained, and leaves its directory untouched.
    private static func closeThenUnlink(_ entries: [Retired]) -> [Retired] {
        var grouped: [Retired] = []
        appendUnique(entries, to: &grouped)

        var stillOpen: [Retired] = []
        for entry in grouped {
            var failedConnections: [Connection] = []
            for connection in entry.connections {
                let forcedFailure = forcedCloseFailures.withLock {
                    $0.contains(connection.identity)
                }
                guard !forcedFailure else {
                    failedConnections.append(connection)
                    continue
                }
                do {
                    try connection.close()
                } catch {
                    failedConnections.append(connection)
                }
            }
            if failedConnections.isEmpty {
                _ = entry.lease.removeOwnedDirectory()
            } else {
                stillOpen.append(Retired(
                    connections: failedConnections,
                    directory: entry.directory,
                    exitOnly: entry.exitOnly,
                    lease: entry.lease
                ))
            }
        }
        return stillOpen
    }

    /// Deterministic barrier for one exact fixture. It never drains an unrelated
    /// suite's parked connection, so teardown-policy tests remain safe under the
    /// test runner's cross-suite parallelism.
    static func flushRegisteredForTesting(pool: DatabasePool) {
        let identity = ObjectIdentifier(pool)
        registry.withLock { state in
            let directories = Set(
                state.entries
                    .filter { $0.contains(identity) }
                    .map { $0.directory.standardizedFileURL }
            )
            let due = state.entries.filter {
                $0.contains(identity)
                    || directories.contains($0.directory.standardizedFileURL)
            }
            state.entries.removeAll {
                $0.contains(identity)
                    || directories.contains($0.directory.standardizedFileURL)
            }
            appendUnique(closeThenUnlink(due), to: &state.entries)
        }
    }

    /// Closes and unlinks every parked fixture. Runs at process exit.
    ///
    /// Keeps `retire`'s invariant: a connection that refuses to close keeps its
    /// file descriptors, so its directory is left on disk rather than unlinked
    /// out from under it. A stray temp directory is a non-event; the unlink is
    /// the API violation.
    private static func flushAllRegistered() {
        registry.withLock { state in
            let due = state.entries
            state.entries = []
            appendUnique(closeThenUnlink(due), to: &state.entries)
        }
    }

    /// Hands `pool`/`directory` over to this type for eventual close + unlink,
    /// and performs the close + unlink of whatever was handed over previously.
    ///
    /// Call this in place of a bare `FileManager.removeItem(at:)` in fixture
    /// teardown. The caller keeps ownership of everything else it does in that
    /// teardown — in particular restoring `AppDatabase.shared`, which must still
    /// happen *before* this call so no later work resolves the global to a
    /// database that is about to close.
    static func retire(pool: DatabasePool, directory: URL) {
        retire(connections: [.pool(pool)], directory: directory)
    }

    static func retire(queue: DatabaseQueue, directory: URL) {
        retire(connections: [.queue(queue)], directory: directory)
    }

    /// Retires every file-backed connection owned by one fixture directory as
    /// one unlink unit. The directory is removed only after every sibling has
    /// closed; successful closes are not retried when another sibling fails.
    /// Callers must pass the complete already-known sibling set in this one
    /// call so ownership is registered atomically before any later flush.
    static func retire(
        pools: [DatabasePool],
        queues: [DatabaseQueue] = [],
        directory: URL
    ) {
        retire(
            connections: pools.map(Connection.pool) + queues.map(Connection.queue),
            directory: directory
        )
    }

    /// Closes this exact fixture now and unlinks its directory only after a
    /// successful close. Existing fixture-specific deferred-retirement lists
    /// use this boundary once they have already provided the quiescence delay.
    /// A close failure is parked for a later retry and never followed by an
    /// unlink.
    static func closeThenUnlinkNow(pool: DatabasePool, directory: URL) {
        closeThenUnlinkNow(connections: [.pool(pool)], directory: directory)
    }

    static func closeThenUnlinkNow(queue: DatabaseQueue, directory: URL) {
        closeThenUnlinkNow(connections: [.queue(queue)], directory: directory)
    }

    private static func closeThenUnlinkNow(connections: [Connection], directory: URL) {
        registerExitFlushIfNeeded()
        registry.withLock { state in
            let standardizedDirectory = directory.standardizedFileURL
            let alreadyExitOnly = state.entries.contains {
                $0.exitOnly
                    && $0.directory.standardizedFileURL == standardizedDirectory
            }
            appendUnique(
                [makeEntry(
                    connections: connections,
                    directory: directory,
                    exitOnly: false,
                    state: state
                )],
                to: &state.entries
            )
            guard !alreadyExitOnly else { return }

            let due = state.entries.filter {
                !$0.exitOnly
                    && $0.directory.standardizedFileURL == standardizedDirectory
            }
            state.entries.removeAll {
                !$0.exitOnly
                    && $0.directory.standardizedFileURL == standardizedDirectory
            }
            appendUnique(closeThenUnlink(due), to: &state.entries)
        }
    }

    private static func retire(connections: [Connection], directory: URL) {
        guard !connections.isEmpty else { return }
        registerExitFlushIfNeeded()

        registry.withLock { state in
            let entry = makeEntry(
                connections: connections,
                directory: directory,
                exitOnly: false,
                state: state
            )
            let directoryAlreadyParked = state.entries.contains {
                $0.directory.standardizedFileURL == directory.standardizedFileURL
            }
            let identityAlreadyParked = connections.contains { connection in
                state.entries.contains { $0.contains(connection.identity) }
            }
            if directoryAlreadyParked || identityAlreadyParked {
                appendUnique([entry], to: &state.entries)
                return
            }

            let due = state.entries.filter { !$0.exitOnly }
            state.entries.removeAll { !$0.exitOnly }
            appendUnique([entry], to: &state.entries)
            appendUnique(closeThenUnlink(due), to: &state.entries)
        }
    }

    /// Keeps a complete exact file-backed fixture group alive until process
    /// exit when no earlier cleanup boundary can safely close it. Register all
    /// already-known directory siblings in one call. Identity de-duplication
    /// makes repeat registration idempotent, and exit-only ownership is sticky
    /// for the entire merged directory group.
    static func registerForProcessExit(pool: DatabasePool, directory: URL) {
        registerForProcessExit(pools: [pool], directory: directory)
    }

    static func registerForProcessExit(
        pools: [DatabasePool],
        queues: [DatabaseQueue] = [],
        directory: URL
    ) {
        registerExitFlushIfNeeded()
        let connections = pools.map(Connection.pool) + queues.map(Connection.queue)
        guard !connections.isEmpty else { return }
        registry.withLock { state in
            appendUnique(
                [makeEntry(
                    connections: connections,
                    directory: directory,
                    exitOnly: true,
                    state: state
                )],
                to: &state.entries
            )
        }
    }
}

/// Teardown policy for an on-disk fixture installed into the shared
/// `AppDatabase` singleton.
///
/// Action-driving tests are the strict motivating case: production's
/// unstructured drain/recount work can outlive every explicit test barrier.
/// The invariant is class-wide, though. Restoring a real predecessor removes
/// the fixture from the global, but it does not prove escaped work has released
/// the fixture's exact connections. Leave a nil-predecessor fixture installed;
/// restore a real predecessor when present; then retain the complete fixture
/// group until process exit in both cases. `prepareProcess()` establishes the
/// XCTest-only descriptor budget before the registry can retain those groups;
/// final close-before-unlink remains the safe process boundary. These
/// installed/action/global fixtures must never enter ordinary next-retirement
/// teardown.
enum InstalledTestDatabaseLifetime {
    static func finish(
        previous: AppDatabase?,
        pool: DatabasePool,
        queues: [DatabaseQueue] = [],
        directory: URL
    ) {
        if let previous {
            AppDatabase.shared.withLock { $0 = previous }
        }
        TestDatabaseTeardown.registerForProcessExit(
            pools: [pool],
            queues: queues,
            directory: directory
        )
    }
}

@Suite("Test database close-before-unlink policy", .serialized)
struct TestDatabaseTeardownInvariantTests {
    private func makeFixture() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("teardown-invariant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path
        )
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)")
        }
        return (pool, directory)
    }

    @Test("deterministic flush closes before removing the fixture directory")
    func deterministicFlushRemovesDirectoryAtSafeBoundary() throws {
        let fixture = try makeFixture()
        defer {
            TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: false)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
        }

        // An unrelated suite may retire another fixture between these lines.
        // Pin this exact pool open until our deterministic exact-pool flush.
        TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: true)
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))

        TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: false)
        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!TestDatabaseTeardown.isPendingForTesting(pool: fixture.pool))
    }

    @Test("close failure never unlinks a live SQLite vnode and remains retryable")
    func closeFailureNeverUnlinksLiveSQLite() throws {
        let fixture = try makeFixture()
        defer {
            TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: false)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
        }
        TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: true)
        TestDatabaseTeardown.closeThenUnlinkNow(
            pool: fixture.pool,
            directory: fixture.directory
        )

        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(TestDatabaseTeardown.isPendingForTesting(pool: fixture.pool))

        TestDatabaseTeardown.forceCloseFailureForTesting(pool: fixture.pool, enabled: false)
        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("process-exit registration is idempotent and has a deterministic flush seam")
    func processExitRegistrationIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool) }

        TestDatabaseTeardown.registerForProcessExit(
            pool: fixture.pool,
            directory: fixture.directory
        )
        TestDatabaseTeardown.registerForProcessExit(
            pool: fixture.pool,
            directory: fixture.directory
        )
        #expect(
            TestDatabaseTeardown.isRegisteredForProcessExitForTesting(pool: fixture.pool)
        )
        #expect(
            TestDatabaseTeardown.processExitRegistrationCountForTesting(
                pool: fixture.pool
            ) == 1
        )

        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(
            !TestDatabaseTeardown.isRegisteredForProcessExitForTesting(pool: fixture.pool)
        )
    }

    @Test("next test-host launch reaps only unlocked fixture markers")
    func staleOwnerReapingKeepsLiveFixtureAndRemovesDeadOwner() throws {
        let live = try makeFixture()
        let staleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("teardown-stale-\(UUID().uuidString)", isDirectory: true)
        let unmarkedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("teardown-unmarked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staleDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unmarkedDirectory,
            withIntermediateDirectories: true
        )
        try TestDatabaseTeardown.createUnlockedStaleMarkerForTesting(
            directory: staleDirectory
        )
        defer {
            TestDatabaseTeardown.flushRegisteredForTesting(pool: live.pool)
            try? FileManager.default.removeItem(at: staleDirectory)
            try? FileManager.default.removeItem(at: unmarkedDirectory)
        }

        TestDatabaseTeardown.registerForProcessExit(
            pool: live.pool,
            directory: live.directory
        )
        // Do not exclude the registry here: this models an independently
        // starting host whose only knowledge is the kernel lock. The live
        // fixture must remain usable while the unlocked stale marker is reaped.
        TestDatabaseTeardown.reapStaleDirectoriesAsCompetingHostForTesting()

        #expect(FileManager.default.fileExists(atPath: live.directory.path))
        #expect(!FileManager.default.fileExists(atPath: staleDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unmarkedDirectory.path))
        let rowCount = try live.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe")
        }
        #expect(rowCount == 0)
    }

    @Test("a failed final rmdir remains marked for the next host to retry")
    func failedFinalRmdirRemainsReapable() throws {
        let fixture = try makeFixture()
        defer {
            TestDatabaseTeardown.forceRmdirObstructionForTesting(
                directory: fixture.directory,
                enabled: false
            )
            TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        TestDatabaseTeardown.registerForProcessExit(
            pool: fixture.pool,
            directory: fixture.directory
        )
        TestDatabaseTeardown.forceRmdirObstructionForTesting(
            directory: fixture.directory,
            enabled: true
        )
        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))

        TestDatabaseTeardown.forceRmdirObstructionForTesting(
            directory: fixture.directory,
            enabled: false
        )
        TestDatabaseTeardown.reapStaleDirectoriesAsCompetingHostForTesting()

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("concurrent ordinary and exit-only ownership remains one sticky directory group")
    func concurrentCrossModeOwnershipStaysGrouped() throws {
        let fixture = try makeFixture()
        let sibling = try DatabasePool(
            path: fixture.directory.appendingPathComponent("test.sqlite").path
        )
        let trigger = try makeFixture()
        defer {
            TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: sibling)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: trigger.pool)
        }

        TestDatabaseTeardown.registerForProcessExit(
            pools: [fixture.pool, fixture.pool, sibling],
            directory: fixture.directory
        )
        #expect(TestDatabaseTeardown.connectionCountForTesting(
            directory: fixture.directory
        ) == 2)

        DispatchQueue.concurrentPerform(iterations: 32) { iteration in
            switch iteration % 3 {
            case 0:
                TestDatabaseTeardown.retire(
                    pools: [fixture.pool, fixture.pool],
                    directory: fixture.directory
                )
            case 1:
                TestDatabaseTeardown.registerForProcessExit(
                    pools: [sibling],
                    directory: fixture.directory
                )
            default:
                TestDatabaseTeardown.retire(
                    pool: fixture.pool,
                    directory: fixture.directory
                )
            }
        }

        #expect(TestDatabaseTeardown.connectionCountForTesting(
            directory: fixture.directory
        ) == 2)
        #expect(!TestDatabaseTeardown.isPendingForTesting(pool: fixture.pool))
        #expect(!TestDatabaseTeardown.isPendingForTesting(pool: sibling))
        #expect(TestDatabaseTeardown.isRegisteredForProcessExitForTesting(
            pool: fixture.pool
        ))
        #expect(TestDatabaseTeardown.isRegisteredForProcessExitForTesting(
            pool: sibling
        ))

        // A later ordinary retirement drains only ordinary groups. The shared
        // fixture remains intact because one sibling upgraded the whole group
        // to the process-exit boundary.
        TestDatabaseTeardown.retire(
            pool: trigger.pool,
            directory: trigger.directory
        )
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))

        // Exact-pool flush selects the directory group, not one connection.
        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!TestDatabaseTeardown.isRegisteredForProcessExitForTesting(
            pool: fixture.pool
        ))
        #expect(!TestDatabaseTeardown.isRegisteredForProcessExitForTesting(
            pool: sibling
        ))
    }

    @Test("a sibling close failure keeps the shared directory until only that sibling retries")
    func siblingCloseFailureKeepsSharedDirectory() throws {
        let fixture = try makeFixture()
        let sibling = try DatabasePool(
            path: fixture.directory.appendingPathComponent("test.sqlite").path
        )
        defer {
            TestDatabaseTeardown.forceCloseFailureForTesting(pool: sibling, enabled: false)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)
            TestDatabaseTeardown.flushRegisteredForTesting(pool: sibling)
        }

        // Arm before parking the group so an unrelated retirement can never
        // close every sibling before this test observes the failure-only retry.
        TestDatabaseTeardown.forceCloseFailureForTesting(pool: sibling, enabled: true)
        TestDatabaseTeardown.retire(
            pools: [fixture.pool, sibling],
            directory: fixture.directory
        )
        TestDatabaseTeardown.flushRegisteredForTesting(pool: fixture.pool)

        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!TestDatabaseTeardown.isPendingForTesting(pool: fixture.pool))
        #expect(TestDatabaseTeardown.isPendingForTesting(pool: sibling))

        TestDatabaseTeardown.forceCloseFailureForTesting(pool: sibling, enabled: false)
        TestDatabaseTeardown.flushRegisteredForTesting(pool: sibling)

        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!TestDatabaseTeardown.isPendingForTesting(pool: sibling))
    }

    @Test("the process database sink owns one exact process-exit registration")
    func processDatabaseSinkRegistersOnce() {
        let pool = TestAppDatabaseSink.database.dbPool
        #expect(TestDatabaseTeardown.isRegisteredForProcessExitForTesting(pool: pool))
        #expect(TestDatabaseTeardown.processExitRegistrationCountForTesting(pool: pool) == 1)
    }

    @Test("the XCTest host establishes the descriptor budget before retaining fixtures")
    func processHasRequiredFileDescriptorBudget() {
        TestDatabaseTeardown.prepareProcess()
        #expect(TestDatabaseTeardown.fileDescriptorSoftLimitForTesting() >= 4_096)
    }
}
