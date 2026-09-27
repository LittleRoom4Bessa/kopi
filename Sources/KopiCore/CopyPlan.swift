import Foundation

/// One file planned for copy. Destinations are derived per destination root.
public struct CopyPlanEntry: Equatable, Sendable {
    public let relativePath: String
    public let sourceURL: URL
    public let size: Int64

    public init(relativePath: String, sourceURL: URL, size: Int64) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.size = size
    }

    public func destinationURL(under root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }
}

/// The full plan for a session, available before any copying starts.
/// Casual mode is the single-destination case of the same pipeline (design D3).
public struct CopyPlan: Sendable {
    public let sourceRoot: URL
    public let destinationRoots: [URL]
    public let entries: [CopyPlanEntry]
    public let totalBytes: Int64
    public let algorithm: HashAlgorithm

    public var fileCount: Int { entries.count }
    /// Convenience for single-destination callers.
    public var destinationRoot: URL { destinationRoots[0] }

    public init(
        sourceRoot: URL,
        destinationRoots: [URL],
        entries: [CopyPlanEntry],
        algorithm: HashAlgorithm = .md5
    ) {
        precondition(!destinationRoots.isEmpty, "a plan needs at least one destination")
        self.sourceRoot = sourceRoot
        self.destinationRoots = destinationRoots
        self.entries = entries
        self.totalBytes = entries.reduce(0) { $0 + $1.size }
        self.algorithm = algorithm
    }

    public init(
        sourceRoot: URL, destinationRoot: URL, entries: [CopyPlanEntry],
        algorithm: HashAlgorithm = .md5
    ) {
        self.init(
            sourceRoot: sourceRoot, destinationRoots: [destinationRoot],
            entries: entries, algorithm: algorithm)
    }
}
