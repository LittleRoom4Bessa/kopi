import Foundation

/// Result of scanning a source: filtered entries plus totals, available
/// before any destination is chosen (pre-copy summary).
public struct SourceScan: Sendable {
    public let entries: [CopyPlanEntry]
    public let totalBytes: Int64
    public var fileCount: Int { entries.count }

    public init(entries: [CopyPlanEntry]) {
        self.entries = entries
        self.totalBytes = entries.reduce(0) { $0 + $1.size }
    }
}

/// Enumerates a source directory into a CopyPlan, filtering macOS filesystem junk.
public enum SourceEnumerator {

    static let skippedFileNames: Set<String> = [".DS_Store"]
    static let skippedDirectoryNames: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"
    ]

    /// Build a copy plan from `source` into one or more destinations, preserving relative structure.
    public static func plan(source: URL, destinations: [URL], algorithm: HashAlgorithm = .md5) throws -> CopyPlan {
        let scan = try scan(source: source)
        return CopyPlan(
            sourceRoot: source, destinationRoots: destinations,
            entries: scan.entries, algorithm: algorithm)
    }

    /// Enumerate and filter the source without binding destinations.
    public static func scan(source: URL) throws -> SourceScan {
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true } // skip unreadable entries; copy stage reports failures
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var entries: [CopyPlanEntry] = []
        let sourcePath = source.standardizedFileURL.path

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])

            if values.isDirectory == true {
                if skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue } // skip symlinks, sockets, etc.
            if skippedFileNames.contains(name) || name.hasPrefix("._") { continue }

            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(sourcePath + "/") else { continue }
            let relativePath = String(fullPath.dropFirst(sourcePath.count + 1))

            entries.append(CopyPlanEntry(
                relativePath: relativePath,
                sourceURL: url,
                size: Int64(values.fileSize ?? 0)
            ))
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return SourceScan(entries: entries)
    }

    /// Single-destination convenience (casual mode).
    public static func plan(source: URL, destination: URL) throws -> CopyPlan {
        try plan(source: source, destinations: [destination])
    }
}
