import Foundation

/// Byte-moving operations, isolated behind a protocol so tests can inject
/// corruption, stalls, and failures per destination. Everything else
/// (rename, mkdir, delete) goes through FileManager in the engine.
public protocol CopyTransport: Sendable {
    /// Opens a read stream for a source file. Read-only; empty Data signals EOF.
    func openSource(at url: URL) throws -> any SourceStream
    /// Opens a write stream for a destination temp file (creating parent dirs).
    func openDestination(at url: URL) throws -> any DestinationStream
    /// Re-reads the file at `url` from storage and returns its hex digest.
    /// Bypasses the OS page cache so verification reflects what's actually on disk.
    func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String
}

public protocol SourceStream: Sendable {
    func readChunk(maxCount: Int) throws -> Data
}

public protocol DestinationStream: Sendable {
    func writeChunk(_ data: Data) throws
    func finish() throws
}

private final class FileSourceStream: SourceStream, @unchecked Sendable {
    private let handle: FileHandle
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    func readChunk(maxCount: Int) throws -> Data { try handle.read(upToCount: maxCount) ?? Data() }
    deinit { try? handle.close() }
}

private final class FileDestinationStream: DestinationStream, @unchecked Sendable {
    private let handle: FileHandle
    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func writeChunk(_ data: Data) throws { try handle.write(contentsOf: data) }
    func finish() throws { try handle.close() }
    deinit { try? handle.close() }
}

public struct RealCopyTransport: CopyTransport {
    private let chunkSize = 1 << 20 // 1 MiB

    public init() {}

    public func openSource(at url: URL) throws -> any SourceStream {
        try FileSourceStream(url: url)
    }

    public func openDestination(at url: URL) throws -> any DestinationStream {
        try FileDestinationStream(url: url)
    }

    public func hashFile(at url: URL, algorithm: HashAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Don't let the page cache serve us the bytes we just wrote —
        // verification must reflect what's on storage.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

        var hasher = algorithm.makeHasher()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
