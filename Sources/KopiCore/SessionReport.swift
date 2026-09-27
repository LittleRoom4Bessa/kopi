import Foundation

/// Why work stopped before finishing the plan.
/// destination* reasons are per-destination; sourceUnavailable aborts the session.
public enum AbortReason: Equatable, Sendable {
    case destinationFull
    case destinationUnavailable
    case sourceUnavailable

    public var userMessage: String {
        switch self {
        case .destinationFull: return "Destination disk is full"
        case .destinationUnavailable: return "Destination volume was disconnected"
        case .sourceUnavailable: return "SD card was ejected"
        }
    }
}

/// Why an individual file failed (without stopping its destination).
public enum FileFailureReason: Equatable, Sendable {
    case hashMismatch
    case readError(String)
    case writeError(String)

    public var userMessage: String {
        switch self {
        case .hashMismatch: return "Hash mismatch after retry"
        case .readError(let detail): return "Read error: \(detail)"
        case .writeError(let detail): return "Write error: \(detail)"
        }
    }
}

public struct CopiedFile: Equatable, Sendable {
    public let relativePath: String
    public let hash: String
    public let bytes: Int64
    /// True when this copy replaced a divergent pre-existing file (surfaced in the UI).
    public let overwroteExisting: Bool

    public init(relativePath: String, hash: String, bytes: Int64, overwroteExisting: Bool = false) {
        self.relativePath = relativePath
        self.hash = hash
        self.bytes = bytes
        self.overwroteExisting = overwroteExisting
    }
}

public struct VerifiedSkippedFile: Equatable, Sendable {
    public let relativePath: String
    public let hash: String
    public let bytes: Int64
}

public struct FailedFile: Equatable, Sendable {
    public let relativePath: String
    public let reason: FileFailureReason
}

/// End-of-session outcome for one destination (design D8: destinations are
/// fully independent — any subset can fail or be re-run).
public struct DestinationReport: Equatable, Sendable {
    public let root: URL
    public var copied: [CopiedFile] = []
    public var verifiedSkipped: [VerifiedSkippedFile] = []
    public var failed: [FailedFile] = []
    /// Destination-level stop (full / disconnected); remaining files are not listed.
    public var abortReason: AbortReason? = nil
    public var manifestURL: URL? = nil

    public init(root: URL) { self.root = root }

    public var succeeded: Bool { abortReason == nil && failed.isEmpty }
    public var finishedFileCount: Int { copied.count + verifiedSkipped.count + failed.count }
}

/// End-of-session summary across all destinations.
public struct SessionReport: Equatable, Sendable {
    public var algorithm: HashAlgorithm = .md5
    public var destinations: [DestinationReport] = []
    /// Session-level abort (source card ejected). Destination-level stops live
    /// on the individual DestinationReports.
    public var abortReason: AbortReason? = nil

    public var succeeded: Bool {
        abortReason == nil && destinations.allSatisfy(\.succeeded)
    }

    /// Casual mode convenience.
    public var primaryDestination: DestinationReport? { destinations.first }

    // Aggregates (used by completion UI/notifications).
    public var totalCopied: Int { destinations.reduce(0) { $0 + $1.copied.count } }
    public var totalVerifiedSkipped: Int { destinations.reduce(0) { $0 + $1.verifiedSkipped.count } }
    public var totalFailed: Int { destinations.reduce(0) { $0 + $1.failed.count } }
    public var totalOverwritten: Int {
        destinations.reduce(0) { $0 + $1.copied.filter(\.overwroteExisting).count }
    }
    /// Session-level abort first, then any destination-level stop.
    public var firstAbortReason: AbortReason? {
        abortReason ?? destinations.compactMap(\.abortReason).first
    }
}
