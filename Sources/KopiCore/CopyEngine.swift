import Foundation

/// Per-destination progress snapshot within a session.
public struct DestinationProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case active
        case done
        case stopped(AbortReason)
    }
    public let root: URL
    public let filesFinished: Int
    public let filesFailed: Int
    public let state: State
}

/// Live progress snapshot, emitted after each file completes.
public struct CopyProgress: Equatable, Sendable {
    public let currentFile: String
    public let filesCompleted: Int
    public let totalFiles: Int
    public let bytesCompleted: Int64
    public let totalBytes: Int64
    public let destinations: [DestinationProgress]
}

/// The verified copy engine. Synchronous; callers run it off the main thread.
///
/// Pipeline per file (design D3): the source is streamed ONCE, hashed
/// in-stream, and chunks are pushed to a bounded queue per destination. Each
/// destination has its own writer thread which writes its `.kopi-tmp`, waits
/// on a per-file hash barrier, re-reads the tmp from storage (page cache
/// bypassed), and renames on match — autonomously, so a stalled NAS blocks
/// neither other destinations' writes nor their verification.
///
/// Backpressure: a destination's queue fills (64 MiB) → reader throttles for
/// that destination only; a destination with 2 files still in flight pauses
/// further fan-out to it.
///
/// Skip path: destinations holding a same-path, same-size file are verified
/// against an up-front source hash and skipped; only the rest join fan-out.
///
/// Failure semantics (verified-copy spec): destination-full/disconnected stops
/// only that destination; source-ejected aborts the whole session; hash
/// mismatch retries the file once (serially, per destination).
public final class CopyEngine: @unchecked Sendable {

    public static let tempSuffix = ".kopi-tmp"

    private let transport: any CopyTransport
    private let fileManager = FileManager.default
    /// Bounded queue depth per destination, in 1 MiB chunks (~64 MiB).
    private let queueBound = 64
    private let chunkSize = 1 << 20

    /// Guards every DestinationReport read/mutation (writer threads + reader).
    private let stateLock = NSLock()
    private let writerGroup = DispatchGroup()

    public init(transport: any CopyTransport = RealCopyTransport()) {
        self.transport = transport
    }

    /// Mutable per-destination session state.
    private final class DestinationState: @unchecked Sendable {
        var report: DestinationReport
        var live = true
        /// In-progress temp file, for cleanup on destination/session stop.
        var tmpURL: URL?
        /// Bounds files concurrently in flight for this destination.
        let inflight = DispatchSemaphore(value: 2)

        init(root: URL) { report = DestinationReport(root: root) }
    }

    /// Runs the full plan and returns a session report. Never throws:
    /// all failures are captured in the report.
    public func run(plan: CopyPlan, progress: @escaping @Sendable (CopyProgress) -> Void) -> SessionReport {
        var session = SessionReport()
        session.algorithm = plan.algorithm
        let dests = plan.destinationRoots.map { DestinationState(root: $0) }
        for dest in dests { removeOrphanedTempFiles(under: dest.report.root) }

        var bytesCompleted: Int64 = 0

        for (index, entry) in plan.entries.enumerated() {
            // Source-level abort check before every file.
            guard fileManager.fileExists(atPath: plan.sourceRoot.path) else {
                session.abortReason = .sourceUnavailable
                break
            }
            // Per-destination liveness: a missing root stops only that destination.
            stateLock.lock()
            for dest in dests where dest.live {
                if !fileManager.fileExists(atPath: dest.report.root.path) {
                    stopDestination(dest, reason: .destinationUnavailable)
                }
            }
            let anyLive = dests.contains { $0.live }
            stateLock.unlock()
            if !anyLive { break }

            if let abort = processFile(entry, dests: dests, plan: plan) {
                session.abortReason = abort
                break
            }

            bytesCompleted += entry.size
            stateLock.lock()
            let snapshot = makeProgress(entry: entry, index: index, plan: plan,
                                        bytesCompleted: bytesCompleted, dests: dests)
            stateLock.unlock()
            progress(snapshot)
        }

        // All writer threads must finish before manifests and the final report.
        writerGroup.wait()

        stateLock.lock()
        for dest in dests {
            cleanupInProgressTmp(dest)
            dest.live = false
            writeManifest(for: dest, algorithm: plan.algorithm)
        }
        session.destinations = dests.map(\.report)
        stateLock.unlock()
        return session
    }

    // MARK: - Per-file pipeline

    /// Returns a session-level abort reason when the source died mid-file.
    private func processFile(_ entry: CopyPlanEntry, dests: [DestinationState], plan: CopyPlan) -> AbortReason? {
        stateLock.lock()
        let live = dests.filter(\.live)
        let candidates = live.filter { existingFileSize(entry, root: $0.report.root) == entry.size }
        var needsCopy = live.filter { dest in !candidates.contains { $0 === dest } }
        stateLock.unlock()
        guard !live.isEmpty else { return nil }

        // Phase 1: skip analysis. Candidates need the source hash to compare.
        if !candidates.isEmpty {
            do {
                let sourceHash = try transport.hashFile(at: entry.sourceURL, algorithm: plan.algorithm)
                for dest in candidates {
                    let existing = entry.destinationURL(under: dest.report.root)
                    let destHash = try? transport.hashFile(at: existing, algorithm: plan.algorithm)
                    stateLock.lock()
                    if destHash == sourceHash {
                        dest.report.verifiedSkipped.append(VerifiedSkippedFile(
                            relativePath: entry.relativePath, hash: sourceHash, bytes: entry.size))
                    } else {
                        // Divergent or unreadable existing file: re-copy.
                        needsCopy.append(dest)
                    }
                    stateLock.unlock()
                }
            } catch {
                // Source unreadable: file fails on every live destination.
                stateLock.lock()
                for dest in live {
                    dest.report.failed.append(FailedFile(
                        relativePath: entry.relativePath,
                        reason: .readError(error.localizedDescription)))
                }
                stateLock.unlock()
                return fileManager.fileExists(atPath: plan.sourceRoot.path) ? nil : .sourceUnavailable
            }
        }

        guard !needsCopy.isEmpty else { return nil }

        // Phase 2: read the source once, fan out to all needing destinations.
        return fanOutCopy(entry, dests: needsCopy, plan: plan)
    }

    private struct FanOutTarget {
        let dest: DestinationState
        let tmpURL: URL
        let queue: ChunkQueue
        let stream: any DestinationStream
    }

    /// Streams the source file once, pushing chunks to every destination's
    /// bounded queue. Writer threads verify+rename autonomously behind the
    /// hash barrier. Returns a session-level abort reason if the source died.
    private func fanOutCopy(_ entry: CopyPlanEntry, dests: [DestinationState], plan: CopyPlan) -> AbortReason? {
        // Open destination streams; a failure here is handled per destination.
        var targets: [FanOutTarget] = []
        for dest in dests {
            dest.inflight.wait() // bound in-flight files per destination
            let tmpURL = tmpURLFor(entry, root: dest.report.root)
            do {
                let stream = try transport.openDestination(at: tmpURL)
                stateLock.lock()
                dest.tmpURL = tmpURL
                stateLock.unlock()
                targets.append(FanOutTarget(dest: dest, tmpURL: tmpURL,
                                            queue: ChunkQueue(bound: queueBound), stream: stream))
            } catch {
                dest.inflight.signal()
                stateLock.lock()
                handleDestinationError(error, dest: dest, entry: entry, tmpURL: tmpURL)
                stateLock.unlock()
            }
        }
        guard !targets.isEmpty else { return nil }

        let barrier = HashBarrier()

        // Writer threads: write → finish → wait for source hash → verify → rename.
        for target in targets {
            writerGroup.enter()
            Thread.detachNewThread { [self] in
                defer {
                    target.dest.inflight.signal()
                    writerGroup.leave()
                }
                writerMain(target: target, entry: entry, barrier: barrier, plan: plan)
            }
        }

        // Reader loop (this thread): one source read, hash in-stream.
        var liveTargets = targets
        do {
            let source = try transport.openSource(at: entry.sourceURL)
            var hasher = plan.algorithm.makeHasher()
            while true {
                let chunk = try source.readChunk(maxCount: chunkSize)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                for target in liveTargets where !target.queue.push(chunk) {
                    // Writer already classified the failure; just stop feeding.
                    liveTargets.removeAll { $0.queue === target.queue }
                }
            }
            barrier.setHash(hasher.finalize())
            for target in liveTargets { target.queue.close() }
            return nil
        } catch {
            barrier.setFailure(error)
            for target in targets { target.queue.close() }
            return fileManager.fileExists(atPath: plan.sourceRoot.path) ? nil : .sourceUnavailable
        }
    }

    /// One destination's write-verify-rename lifecycle for one file.
    private func writerMain(
        target: FanOutTarget, entry: CopyPlanEntry, barrier: HashBarrier, plan: CopyPlan
    ) {
        let dest = target.dest
        while let chunk = target.queue.pop() {
            do {
                try target.stream.writeChunk(chunk)
            } catch {
                target.queue.fail(error)
                stateLock.lock()
                handleDestinationError(error, dest: dest, entry: entry, tmpURL: target.tmpURL)
                stateLock.unlock()
                return
            }
        }
        if target.queue.failure != nil { return } // failed above

        do {
            try target.stream.finish()
        } catch {
            stateLock.lock()
            handleDestinationError(error, dest: dest, entry: entry, tmpURL: target.tmpURL)
            stateLock.unlock()
            return
        }

        let sourceHash: String
        do {
            sourceHash = try barrier.wait()
        } catch {
            // Source read failed mid-file.
            stateLock.lock()
            cleanupTmp(target.tmpURL)
            dest.tmpURL = nil
            dest.report.failed.append(FailedFile(
                relativePath: entry.relativePath, reason: .readError(error.localizedDescription)))
            stateLock.unlock()
            return
        }

        stateLock.lock()
        verifyAndRename(entry: entry, dest: dest, tmpURL: target.tmpURL,
                        sourceHash: sourceHash, plan: plan)
        stateLock.unlock()
    }

    /// Destination re-read → compare → rename-on-match. Retries once serially
    /// on mismatch (design D4 carried into fan-out).
    /// Call with stateLock held.
    private func verifyAndRename(
        entry: CopyPlanEntry, dest: DestinationState, tmpURL: URL, sourceHash: String, plan: CopyPlan
    ) {
        let finalURL = entry.destinationURL(under: dest.report.root)
        do {
            let destHash = try transport.hashFile(at: tmpURL, algorithm: plan.algorithm)
            if destHash == sourceHash {
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: tmpURL, to: finalURL)
                dest.tmpURL = nil
                dest.report.copied.append(CopiedFile(
                    relativePath: entry.relativePath, hash: sourceHash, bytes: entry.size))
                return
            }
            throw FileFailure(reason: .hashMismatch)
        } catch {
            if let failure = error as? FileFailure, failure.reason == .hashMismatch {
                // Serial single-destination retry (one extra source read).
                if retryCopy(entry: entry, dest: dest, tmpURL: tmpURL, plan: plan) {
                    dest.tmpURL = nil
                    return
                }
                dest.tmpURL = nil // tmp kept on disk for inspection; orphan cleanup covers it
                dest.report.failed.append(FailedFile(
                    relativePath: entry.relativePath, reason: .hashMismatch))
            } else {
                handleDestinationError(error, dest: dest, entry: entry, tmpURL: tmpURL)
            }
        }
    }

    /// One-shot serial re-copy of a file to a single destination. Returns true
    /// when verified and renamed. Call with stateLock held.
    private func retryCopy(
        entry: CopyPlanEntry, dest: DestinationState, tmpURL: URL, plan: CopyPlan
    ) -> Bool {
        do {
            let source = try transport.openSource(at: entry.sourceURL)
            let stream = try transport.openDestination(at: tmpURL)
            var hasher = plan.algorithm.makeHasher()
            while true {
                let chunk = try source.readChunk(maxCount: chunkSize)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try stream.writeChunk(chunk)
            }
            try stream.finish()
            let sourceHash = hasher.finalize()
            let destHash = try transport.hashFile(at: tmpURL, algorithm: plan.algorithm)
            guard sourceHash == destHash else { return false }
            let finalURL = entry.destinationURL(under: dest.report.root)
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: tmpURL, to: finalURL)
            dest.report.copied.append(CopiedFile(
                relativePath: entry.relativePath, hash: sourceHash, bytes: entry.size))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Failure classification (per-destination semantics, verified-copy spec)

    /// Call with stateLock held.
    private func handleDestinationError(
        _ error: Error, dest: DestinationState, entry: CopyPlanEntry, tmpURL: URL
    ) {
        let nsError = error as NSError
        // Destination-level stops: full or disconnected.
        if !fileManager.fileExists(atPath: dest.report.root.path) {
            stopDestination(dest, reason: .destinationUnavailable)
            return
        }
        if (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOSPC)
            || nsError.code == NSFileWriteOutOfSpaceError {
            stopDestination(dest, reason: .destinationFull)
            return
        }
        // File-level failure: destination keeps going.
        cleanupTmp(tmpURL)
        dest.tmpURL = nil
        dest.report.failed.append(FailedFile(
            relativePath: entry.relativePath, reason: .writeError(error.localizedDescription)))
    }

    /// Destination-level stop: delete in-progress tmp, mark dead, record reason.
    /// Call with stateLock held.
    private func stopDestination(_ dest: DestinationState, reason: AbortReason) {
        dest.live = false
        dest.report.abortReason = reason
        cleanupInProgressTmp(dest)
    }

    private func cleanupInProgressTmp(_ dest: DestinationState) {
        if let tmp = dest.tmpURL { cleanupTmp(tmp) }
        dest.tmpURL = nil
    }

    private func cleanupTmp(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Helpers

    private func existingFileSize(_ entry: CopyPlanEntry, root: URL) -> Int64? {
        let url = entry.destinationURL(under: root)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    private func tmpURLFor(_ entry: CopyPlanEntry, root: URL) -> URL {
        entry.destinationURL(under: root)
            .appendingPathExtension(String(Self.tempSuffix.dropFirst()))
    }

    /// Call with stateLock held.
    private func writeManifest(for dest: DestinationState, algorithm: HashAlgorithm) {
        let verified = dest.report.copied.map { ($0.relativePath, $0.hash) }
            + dest.report.verifiedSkipped.map { ($0.relativePath, $0.hash) }
        dest.report.manifestURL = try? ManifestWriter.write(
            destinationRoot: dest.report.root,
            verifiedFiles: verified,
            algorithm: algorithm
        )
    }

    /// Call with stateLock held.
    private func makeProgress(
        entry: CopyPlanEntry, index: Int, plan: CopyPlan,
        bytesCompleted: Int64, dests: [DestinationState]
    ) -> CopyProgress {
        CopyProgress(
            currentFile: entry.relativePath,
            filesCompleted: index + 1,
            totalFiles: plan.fileCount,
            bytesCompleted: bytesCompleted,
            totalBytes: plan.totalBytes,
            destinations: dests.map { dest in
                DestinationProgress(
                    root: dest.report.root,
                    filesFinished: dest.report.finishedFileCount,
                    filesFailed: dest.report.failed.count,
                    state: dest.report.abortReason.map(DestinationProgress.State.stopped)
                        ?? (dest.live ? .active : .done)
                )
            }
        )
    }

    /// Interrupted sessions can only leave `.kopi-tmp` files behind (never
    /// partial final-named files). Remove them; the affected files re-copy fresh.
    private func removeOrphanedTempFiles(under root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(Self.tempSuffix) {
            try? fileManager.removeItem(at: url)
        }
    }

    private struct FileFailure: Error { let reason: FileFailureReason }
}

/// Bounded blocking queue feeding one destination writer thread (design D3).
final class ChunkQueue: @unchecked Sendable {
    private let bound: Int
    private let cond = NSCondition()
    private var items: [Data] = []
    private var closed = false
    private(set) var failure: (any Error)?

    init(bound: Int) { self.bound = bound }

    /// Returns false when the queue has failed (destination write error).
    func push(_ data: Data) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while items.count >= bound && failure == nil { cond.wait() }
        if failure != nil { return false }
        items.append(data)
        cond.signal()
        return true
    }

    /// Reader finished normally; the writer drains remaining items.
    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    /// Destination writer failed; reader stops pushing, writer drains out.
    func fail(_ error: any Error) {
        cond.lock()
        failure = error
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    /// nil when closed-and-drained or failed.
    func pop() -> Data? {
        cond.lock()
        defer { cond.unlock() }
        while items.isEmpty && !closed && failure == nil { cond.wait() }
        if failure != nil { return nil }
        if !items.isEmpty {
            defer { cond.signal() }
            return items.removeFirst()
        }
        return nil
    }
}

/// Per-file rendezvous: the reader publishes the source-stream hash once the
/// file is fully read; destination writers wait for it before verifying.
final class HashBarrier: @unchecked Sendable {
    private let cond = NSCondition()
    private var hash: String?
    private var failure: (any Error)?

    func setHash(_ hash: String) {
        cond.lock()
        self.hash = hash
        cond.broadcast()
        cond.unlock()
    }

    func setFailure(_ error: any Error) {
        cond.lock()
        self.failure = error
        cond.broadcast()
        cond.unlock()
    }

    func wait() throws -> String {
        cond.lock()
        while hash == nil && failure == nil { cond.wait() }
        defer { cond.unlock() }
        if let failure { throw failure }
        return hash!
    }
}
