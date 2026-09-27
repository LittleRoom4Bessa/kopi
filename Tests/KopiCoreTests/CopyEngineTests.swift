import Foundation
import Testing
@testable import KopiCore

// MARK: - Fault-injection transports

func pathUnder(_ url: URL, _ root: URL) -> Bool {
    url.path == root.path || url.path.hasPrefix(root.path + "/")
}


/// Corrupts destination bytes after write (simulating bad writes landing on
/// disk) for the first N destination streams.
final class CorruptingTransport: CopyTransport, @unchecked Sendable {
    private let real = RealCopyTransport()
    private let lock = NSLock()
    var corruptionsRemaining: Int

    init(corruptions: Int) { corruptionsRemaining = corruptions }

    func openSource(at url: URL) throws -> any SourceStream {
        try real.openSource(at: url)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        CorruptingStream(inner: try real.openDestination(at: url), url: url) { [lock] in
            lock.lock()
            defer { lock.unlock() }
            if self.corruptionsRemaining > 0 {
                self.corruptionsRemaining -= 1
                return true
            }
            return false
        }
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try real.hashFile(at: url, algorithm: algorithm)
    }

    private final class CorruptingStream: DestinationStream, @unchecked Sendable {
        let inner: any DestinationStream
        let url: URL
        let shouldCorrupt: () -> Bool
        init(inner: any DestinationStream, url: URL, shouldCorrupt: @escaping () -> Bool) {
            self.inner = inner
            self.url = url
            self.shouldCorrupt = shouldCorrupt
        }
        func writeChunk(_ data: Data) throws { try inner.writeChunk(data) }
        func finish() throws {
            try inner.finish()
            if shouldCorrupt() {
                var data = try Data(contentsOf: url)
                if !data.isEmpty {
                    data[data.count - 1] ^= 0xFF
                    try data.write(to: url)
                }
            }
        }
    }
}

/// Throws a simulated ENOSPC on writes under `targetRoot` (nil = all).
struct DiskFullTransport: CopyTransport {
    var targetRoot: URL? = nil

    func openSource(at url: URL) throws -> any SourceStream {
        try RealCopyTransport().openSource(at: url)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        if let targetRoot, !pathUnder(url, targetRoot) {
            return try RealCopyTransport().openDestination(at: url)
        }
        return FullStream()
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try RealCopyTransport().hashFile(at: url, algorithm: algorithm)
    }

    struct FullStream: DestinationStream {
        func writeChunk(_ data: Data) throws {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        func finish() throws {}
    }
}

/// Deletes the source root when a source stream opens (card ejected), then throws.
struct SourceEjectingTransport: CopyTransport {
    let sourceRoot: URL
    func openSource(at url: URL) throws -> any SourceStream {
        try? FileManager.default.removeItem(at: sourceRoot)
        throw CocoaError(.fileReadUnknown)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        try RealCopyTransport().openDestination(at: url)
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try RealCopyTransport().hashFile(at: url, algorithm: algorithm)
    }
}

/// Deletes the destination root when its stream opens (drive unplugged), then throws.
struct DestinationEjectingTransport: CopyTransport {
    let destinationRoot: URL
    func openSource(at url: URL) throws -> any SourceStream {
        try RealCopyTransport().openSource(at: url)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        if pathUnder(url, destinationRoot) {
            try? FileManager.default.removeItem(at: destinationRoot)
            throw CocoaError(.fileWriteUnknown)
        }
        return try RealCopyTransport().openDestination(at: url)
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try RealCopyTransport().hashFile(at: url, algorithm: algorithm)
    }
}

/// Counts source stream opens — proves read-once fan-out.
final class CountingTransport: CopyTransport, @unchecked Sendable {
    private let real = RealCopyTransport()
    private let lock = NSLock()
    var sourceOpens = 0

    func openSource(at url: URL) throws -> any SourceStream {
        lock.lock(); sourceOpens += 1; lock.unlock()
        return try real.openSource(at: url)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        try real.openDestination(at: url)
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try real.hashFile(at: url, algorithm: algorithm)
    }
}

/// Destination writes under `stallRoot` block on a gate until released —
/// simulates a stalled NAS.
final class StallingTransport: CopyTransport, @unchecked Sendable {
    private let real = RealCopyTransport()
    let stallRoot: URL
    let gate = DispatchSemaphore(value: 0)
    /// Fires on the first stalled write.
    let stallStarted = DispatchSemaphore(value: 0)

    init(stallRoot: URL) { self.stallRoot = stallRoot }

    func release() { gate.signal() }

    func openSource(at url: URL) throws -> any SourceStream {
        try real.openSource(at: url)
    }
    func openDestination(at url: URL) throws -> any DestinationStream {
        if pathUnder(url, stallRoot) {
            return StallingStream(inner: try real.openDestination(at: url),
                                  gate: gate, stallStarted: stallStarted)
        }
        return try real.openDestination(at: url)
    }
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        try real.hashFile(at: url, algorithm: algorithm)
    }

    private final class StallingStream: DestinationStream, @unchecked Sendable {
        let inner: any DestinationStream
        let gate: DispatchSemaphore
        let stallStarted: DispatchSemaphore
        var stalled = false

        init(inner: any DestinationStream, gate: DispatchSemaphore, stallStarted: DispatchSemaphore) {
            self.inner = inner
            self.gate = gate
            self.stallStarted = stallStarted
        }
        func writeChunk(_ data: Data) throws {
            if !stalled {
                stalled = true
                stallStarted.signal()
                gate.wait() // block until released
            }
            try inner.writeChunk(data)
        }
        func finish() throws { try inner.finish() }
    }
}

// MARK: - Engine tests

struct CopyEngineTests {

    private func runSession(
        _ f: Fixture,
        destinations: [URL]? = nil,
        algorithm: HashAlgorithm = .md5,
        transport: any CopyTransport = RealCopyTransport()
    ) throws -> SessionReport {
        let dests = destinations ?? [f.destination]
        let plan = try SourceEnumerator.plan(source: f.source, destinations: dests)
        let algPlan = CopyPlan(sourceRoot: plan.sourceRoot, destinationRoots: plan.destinationRoots,
                               entries: plan.entries, algorithm: algorithm)
        return CopyEngine(transport: transport).run(plan: algPlan) { _ in }
    }

    private func destReport(_ report: SessionReport, _ root: URL) -> DestinationReport {
        report.destinations.first { $0.root == root }!
    }

    // Spec: successful verified copy — final name present, no .kopi-tmp remains
    @Test func verifiedCopySuccess() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("DCIM/a.jpg", "alpha")
        try f.writeSource("DCIM/b.mov", "bravo")

        let report = try runSession(f)

        #expect(report.succeeded)
        #expect(report.primaryDestination?.copied.count == 2)
        #expect(try f.readDestination("DCIM/a.jpg") == "alpha")
        #expect(!f.destinationExists("DCIM/a.jpg.kopi-tmp"))
        #expect(!f.destinationExists("DCIM/b.mov.kopi-tmp"))
    }

    // Spec: hash mismatch — retried once, succeeds on second attempt
    @Test func mismatchRetriesOnceThenSucceeds() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        let report = try runSession(f, transport: CorruptingTransport(corruptions: 1))

        #expect(report.succeeded)
        #expect(report.primaryDestination?.copied.count == 1)
        #expect(try f.readDestination("a.jpg") == "alpha")
    }

    // Spec: hash mismatch — second failure keeps .kopi-tmp, flags file, excludes from manifest
    @Test func mismatchTwiceFailsAndKeepsTmp() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo")
        let report = try runSession(f, transport: CorruptingTransport(corruptions: .max))

        let dest = try #require(report.primaryDestination)
        #expect(!report.succeeded)
        #expect(report.abortReason == nil)
        #expect(dest.failed.count == 2)
        #expect(dest.failed.first?.reason == .hashMismatch)
        #expect(!f.destinationExists("a.jpg"))        // never renamed
        #expect(f.destinationExists("a.jpg.kopi-tmp")) // kept for inspection
        // Failed files excluded from manifest → no manifest at all here
        #expect(dest.manifestURL == nil)
    }

    // Spec: crash safety — orphaned .kopi-tmp from an interrupted session is
    // removed and the file re-copied on the next session
    @Test func orphanedTmpIsCleanedAndRecopied() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeDestination("a.jpg.kopi-tmp", "PARTIAL") // simulated crash litter

        let report = try runSession(f)

        #expect(report.succeeded)
        #expect(try f.readDestination("a.jpg") == "alpha")
        #expect(!f.destinationExists("a.jpg.kopi-tmp"))
    }

    // Spec: incremental skip — same path+size+hash at destination is skipped
    @Test func existingVerifiedFileIsSkipped() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeDestination("a.jpg", "alpha")

        let report = try runSession(f)

        let dest = try #require(report.primaryDestination)
        #expect(report.succeeded)
        #expect(dest.copied.count == 0)
        #expect(dest.verifiedSkipped.count == 1)
        #expect(dest.verifiedSkipped.first?.relativePath == "a.jpg")
    }

    // Spec: incremental skip — same path+size but different content is re-copied
    @Test func existingDivergentFileIsRecopied() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeDestination("a.jpg", "XXXXX") // same size, different bytes

        let report = try runSession(f)

        #expect(report.succeeded)
        #expect(report.primaryDestination?.copied.count == 1)
        #expect(try f.readDestination("a.jpg") == "alpha")
    }

    // Spec: destination full — destination stops loudly, in-progress tmp deleted
    @Test func diskFullStopsDestination() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        let report = try runSession(f, transport: DiskFullTransport())

        let dest = try #require(report.primaryDestination)
        #expect(dest.abortReason == .destinationFull)
        #expect(dest.abortReason?.userMessage == "Destination disk is full")
        #expect(!f.destinationExists("a.jpg"))
        #expect(!f.destinationExists("a.jpg.kopi-tmp"))
    }

    // Spec: card ejected mid-copy — session abort, distinct reason
    @Test func sourceEjectedAbortsSession() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo") // second file ensures the abort is hit
        let report = try runSession(f, transport: SourceEjectingTransport(sourceRoot: f.source))

        #expect(report.abortReason == .sourceUnavailable)
        #expect(report.abortReason?.userMessage == "SD card was ejected")
    }

    // Spec: destination disconnected mid-copy — distinct from full and ejected
    @Test func destinationUnavailableStopsDestination() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        let report = try runSession(f, transport: DestinationEjectingTransport(destinationRoot: f.destination))

        let dest = try #require(report.primaryDestination)
        #expect(report.abortReason == nil) // session-level stays clear
        #expect(dest.abortReason == .destinationUnavailable)
        #expect(dest.abortReason?.userMessage == "Destination volume was disconnected")
    }

    // Spec: manifest — <hash>  <path> format, verified files only
    @Test func manifestContentsMatchCopiedFiles() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("sub/b.mov", "bravo")

        let report = try runSession(f)

        let manifestURL = try #require(report.primaryDestination?.manifestURL)
        #expect(manifestURL.lastPathComponent.hasPrefix("kopi-manifest-"))
        #expect(manifestURL.pathExtension == "md5")

        let lines = try String(contentsOf: manifestURL)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)

        let real = RealCopyTransport()
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            let hash = String(parts[0])
            let relPath = String(parts[1])
            let actual = try real.hashFile(
                at: f.destination.appendingPathComponent(relPath), algorithm: .md5)
            #expect(hash == actual, "manifest hash matches destination for \(relPath)")
        }
    }

    // Spec: manifest — verified-skipped files count as verified
    @Test func manifestIncludesVerifiedSkippedFiles() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeDestination("a.jpg", "alpha")

        let report = try runSession(f)

        let manifestURL = try #require(report.primaryDestination?.manifestURL)
        let body = try String(contentsOf: manifestURL)
        #expect(body.contains("a.jpg"))
    }

    // Spec: session report — mixed outcome counts
    @Test func sessionReportMixedOutcome() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("new.jpg", "new-data")
        try f.writeSource("skip.jpg", "skip-data")
        try f.writeDestination("skip.jpg", "skip-data")
        try f.writeSource("bad.jpg", "bad-data")

        // Corrupt every write: only the pre-existing skip survives verification
        let report = try runSession(f, transport: CorruptingTransport(corruptions: .max))

        let dest = try #require(report.primaryDestination)
        #expect(dest.copied.count == 0)
        #expect(dest.verifiedSkipped.map(\.relativePath) == ["skip.jpg"])
        #expect(dest.failed.count == 2)
    }

    // Spec: source is never modified — byte-identical after session
    @Test func sourceIsNeverModified() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("sub/b.mov", "bravo")

        func snapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            let real = RealCopyTransport()
            let plan = try SourceEnumerator.plan(source: f.source, destination: f.destination)
            for entry in plan.entries {
                result[entry.relativePath] = try real.hashFile(at: entry.sourceURL, algorithm: .md5)
            }
            return result
        }

        let before = try snapshot()
        _ = try runSession(f)
        let after = try snapshot()

        #expect(before == after)
    }

    // Progress callbacks fire per file with cumulative counts
    @Test func progressCallbacks() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo")

        let plan = try SourceEnumerator.plan(source: f.source, destination: f.destination)
        final class Box: @unchecked Sendable { var updates: [CopyProgress] = [] }
        let box = Box()
        _ = CopyEngine().run(plan: plan) { box.updates.append($0) }
        let updates = box.updates

        #expect(updates.count == 2)
        #expect(updates.last?.filesCompleted == 2)
        #expect(updates.last?.totalFiles == 2)
        #expect(updates.last?.bytesCompleted == plan.totalBytes)
        #expect(updates.last?.destinations.count == 1)
    }

    // MARK: - Multi-destination fan-out (task 3.6)

    // Spec: read-once fan-out — 3 destinations, one source read per file
    @Test func fanOutReadsSourceOnce() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let b = try f.makeDestination("B")
        let c = try f.makeDestination("C")
        try f.writeSource("big.mov", String(repeating: "x", count: 3 << 20))

        let counter = CountingTransport()
        let report = try runSession(f, destinations: [f.destination, b, c], transport: counter)

        #expect(report.succeeded)
        #expect(counter.sourceOpens == 1) // one file, read exactly once
        for root in [f.destination, b, c] {
            #expect(try f.read("big.mov", in: root) == String(repeating: "x", count: 3 << 20))
            #expect(destReport(report, root).copied.count == 1)
            #expect(destReport(report, root).manifestURL != nil)
        }
    }

    // Spec: destinations at different completion states — skips and copies coexist
    @Test func perDestinationIncrementalSkip() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let b = try f.makeDestination("B")
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo")
        try f.writeDestination("a.jpg", "alpha") // A already has a.jpg
        // B is empty

        let counter = CountingTransport()
        let report = try runSession(f, destinations: [f.destination, b], transport: counter)

        let destA = destReport(report, f.destination)
        let destB = destReport(report, b)
        #expect(destA.verifiedSkipped.map(\.relativePath) == ["a.jpg"])
        #expect(destA.copied.map(\.relativePath) == ["b.jpg"])
        #expect(destB.copied.count == 2)
        #expect(destB.verifiedSkipped.isEmpty)
        #expect(report.succeeded)
        // Read-once fan-out (verified-copy spec): each file is read from the
        // source exactly once even in a mixed skip/copy session.
        #expect(counter.sourceOpens == 2) // 2 files × 1 read
    }

    // Spec: overwrite is surfaced — divergent existing file re-copied and flagged
    @Test func divergentRecopyIsFlaggedAsOverwrite() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo")
        try f.writeDestination("a.jpg", "XXXXX") // same size, different bytes

        let report = try runSession(f)

        let dest = try #require(report.primaryDestination)
        #expect(report.succeeded)
        #expect(dest.copied.count == 2)
        let overwritten = dest.copied.filter(\.overwroteExisting).map(\.relativePath)
        #expect(overwritten == ["a.jpg"])
        #expect(report.totalOverwritten == 1)
        #expect(try f.readDestination("a.jpg") == "alpha")
    }

    // Spec: destination failure isolation — full NAS fails alone, others complete
    @Test func destinationFailureIsIsolated() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let b = try f.makeDestination("B")
        let c = try f.makeDestination("C")
        try f.writeSource("a.jpg", "alpha")
        try f.writeSource("b.jpg", "bravo")

        let report = try runSession(
            f, destinations: [f.destination, b, c],
            transport: DiskFullTransport(targetRoot: b))

        let destA = destReport(report, f.destination)
        let destB = destReport(report, b)
        let destC = destReport(report, c)
        #expect(destA.succeeded && destC.succeeded)
        #expect(destA.copied.count == 2)
        #expect(destC.copied.count == 2)
        #expect(destB.abortReason == .destinationFull)
        #expect(destB.copied.isEmpty)
        #expect(!report.succeeded) // overall reflects B
        #expect(report.abortReason == nil) // but no session-level abort
    }

    // Spec: stalled destination does not block healthy destinations
    @Test func stalledDestinationDoesNotBlockOthers() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let nas = try f.makeDestination("NAS")
        // File larger than the 64-chunk bound would deadlock if the reader
        // waited on the stalled queue; 2 MiB proves healthy dests finish first.
        let payload = String(repeating: "y", count: 2 << 20)
        try f.writeSource("big.mov", payload)

        let stall = StallingTransport(stallRoot: nas)
        let plan = try SourceEnumerator.plan(source: f.source, destinations: [f.destination, nas])

        final class ReportBox: @unchecked Sendable { var report: SessionReport? }
        let box = ReportBox()
        let finished = DispatchSemaphore(value: 0)
        let runner = Thread {
            box.report = CopyEngine(transport: stall).run(plan: plan) { _ in }
            finished.signal()
        }
        runner.start()

        // Wait for the stall to engage, then give the healthy destination time
        // to finish while the NAS writer is still blocked.
        _ = stall.stallStarted.wait(timeout: .now() + 10)

        var healthyDone = false
        for _ in 0..<200 {
            if f.exists("big.mov", in: f.destination) { healthyDone = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(healthyDone) // healthy destination completed during the stall
        #expect(!f.exists("big.mov", in: nas))

        stall.release()
        _ = finished.wait(timeout: .now() + 30)

        let report = try #require(box.report)
        #expect(report.succeeded)
        #expect(try f.read("big.mov", in: nas) == payload)
    }
}
