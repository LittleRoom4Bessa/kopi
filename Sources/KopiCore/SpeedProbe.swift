import Foundation

public enum SpeedProbeError: Error, Equatable {
    case cancelled
    case noReadableFile
}

/// Measured throughput from a speed probe. Nil components mean that phase
/// didn't run (e.g. source probes never write).
public struct ProbeResult: Equatable, Sendable {
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?

    public init(readBytesPerSecond: Double? = nil, writeBytesPerSecond: Double? = nil) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

/// On-demand, explicit, cancellable speed probe (design D2).
/// Destination probe writes a temp file and reads it back (page-cache bypassed);
/// source probe is strictly read-only — the source volume is never written to.
public enum SpeedProbe {

    public static let defaultProbeBytes = 256 << 20 // 256 MiB
    private static let chunkSize = 1 << 20          // 1 MiB

    /// Write-then-read probe on a destination volume. The temp file is always
    /// removed — on success, failure, or cancellation.
    public static func probeDestination(
        at directory: URL,
        totalBytes: Int = defaultProbeBytes,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ProbeResult {
        let temp = directory.appendingPathComponent(".kopi-speedtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        // Write phase (buffer is arbitrary data; content is never verified).
        let chunk = Data((0..<chunkSize).map { UInt8(truncatingIfNeeded: $0) })
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        let writeSeconds: Double
        do {
            writeSeconds = try measure {
                var written = 0
                while written < totalBytes {
                    if isCancelled() { throw SpeedProbeError.cancelled }
                    try handle.write(contentsOf: chunk)
                    written += chunk.count
                }
                try handle.synchronize()
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // Read phase, page cache bypassed so it reflects storage, not RAM.
        let readSeconds = try measure {
            let handle = try FileHandle(forReadingFrom: temp)
            defer { try? handle.close() }
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
            var readTotal = 0
            while readTotal < totalBytes {
                if isCancelled() { throw SpeedProbeError.cancelled }
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                readTotal += data.count
            }
        }

        return ProbeResult(
            readBytesPerSecond: Double(totalBytes) / max(readSeconds, .ulpOfOne),
            writeBytesPerSecond: Double(totalBytes) / max(writeSeconds, .ulpOfOne)
        )
    }

    /// Read-only probe for source volumes: streams up to `maxBytes` from the
    /// largest regular file under `root`, page cache bypassed.
    public static func probeSource(
        at root: URL,
        maxBytes: Int = defaultProbeBytes,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ProbeResult {
        guard let target = largestRegularFile(under: root) else {
            throw SpeedProbeError.noReadableFile
        }
        var readTotal = 0
        let seconds = try measure {
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
            while readTotal < maxBytes {
                if isCancelled() { throw SpeedProbeError.cancelled }
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                readTotal += data.count
            }
        }
        // Throughput is computed from bytes actually read — a file smaller
        // than maxBytes must not inflate the measured speed.
        guard readTotal > 0 else { throw SpeedProbeError.noReadableFile }
        return ProbeResult(readBytesPerSecond: Double(readTotal) / max(seconds, .ulpOfOne))
    }

    // MARK: - Internals

    static func largestRegularFile(under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var best: (url: URL, size: Int)?
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            if size > (best?.size ?? -1) { best = (url, size) }
        }
        return best?.url
    }

    private static func measure(_ body: () throws -> Void) throws -> Double {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
