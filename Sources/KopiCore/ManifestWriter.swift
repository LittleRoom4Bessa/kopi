import Foundation

/// Writes the per-session manifest: `<hash>  <relative/path>` lines,
/// one per verified file, sorted by path. Filename extension records the
/// session's algorithm (`kopi-manifest-<ts>.md5|xxh64|sha256`).
public enum ManifestWriter {

    public static func manifestName(date: Date = Date(), algorithm: HashAlgorithm = .md5) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "kopi-manifest-\(formatter.string(from: date)).\(algorithm.manifestExtension)"
    }

    /// Returns the manifest URL, or nil if there were no verified files.
    @discardableResult
    public static func write(
        destinationRoot: URL,
        verifiedFiles: [(relativePath: String, hash: String)],
        algorithm: HashAlgorithm = .md5,
        date: Date = Date()
    ) throws -> URL? {
        guard !verifiedFiles.isEmpty else { return nil }
        let body = verifiedFiles
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.hash)  \($0.relativePath)" }
            .joined(separator: "\n") + "\n"
        let url = destinationRoot.appendingPathComponent(manifestName(date: date, algorithm: algorithm))
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
