import Foundation

/// Pro mode settings, persisted across launches (pro-mode spec).
public struct ProSettings: Codable, Equatable, Sendable {
    public static let destinationCount = 3

    public var destinations: [String]
    public var algorithm: HashAlgorithm
    public var strictMode: Bool

    public init(
        destinations: [String] = Array(repeating: "", count: ProSettings.destinationCount),
        algorithm: HashAlgorithm = .xxh64,
        strictMode: Bool = false
    ) {
        self.destinations = destinations
        self.algorithm = algorithm
        self.strictMode = strictMode
    }
}

/// A 3-2-1 rule outcome. Warn-level violations badge but don't block;
/// hard errors always block Start (pro-mode spec).
public enum RuleViolation: Equatable, Sendable {
    /// Two destinations resolve to the same physical disk (names it).
    case samePhysicalDisk(String)
    /// No network/remote destination among the three.
    case noNetworkDestination
    /// A destination sits on the source's physical disk. Hard error.
    case destinationOnSource(String)
    /// The same folder was picked twice. Hard error.
    case duplicateDestination(String)

    public var isHardError: Bool {
        switch self {
        case .destinationOnSource, .duplicateDestination: return true
        case .samePhysicalDisk, .noNetworkDestination: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .samePhysicalDisk(let disk):
            return "Two destinations are on the same physical disk (\(disk)) — violates 2-media"
        case .noNetworkDestination:
            return "No network/remote destination — 3-2-1 wants 1 remote copy"
        case .destinationOnSource(let disk):
            return "A destination is on the source disk (\(disk)) — pick another disk"
        case .duplicateDestination(let path):
            return "Same folder picked twice: \(path)"
        }
    }
}

/// Pure 3-2-1 media-rule evaluation (design D5). Undeterminable identities
/// are never used to accuse: unknown media identities don't trigger
/// same-disk violations.
public enum MediaRules {

    public static func evaluate(
        source: DiskDescriptor?,
        destinations: [DiskDescriptor]
    ) -> [RuleViolation] {
        var violations: [RuleViolation] = []

        // Hard errors first.

        // Same folder twice (standardized paths).
        let paths = destinations.map { $0.path.standardizedFileURL.path }
        var seen = Set<String>()
        for path in paths where !seen.insert(path).inserted {
            violations.append(.duplicateDestination(path))
        }

        // Destination on the source's physical disk.
        if let source, case .local(let sourceDisk) = source.mediaIdentity {
            for dest in destinations {
                if dest.mediaIdentity == .local(sourceDisk) {
                    violations.append(.destinationOnSource(sourceDisk))
                    break
                }
            }
        }

        // Warn-level rules.

        // Two destinations on one physical disk.
        var localCounts: [String: Int] = [:]
        for dest in destinations {
            if case .local(let disk) = dest.mediaIdentity {
                localCounts[disk, default: 0] += 1
            }
        }
        for (disk, count) in localCounts.sorted(by: { $0.key < $1.key }) where count > 1 {
            violations.append(.samePhysicalDisk(disk))
        }

        // At least one network/remote destination.
        let hasNetwork = destinations.contains {
            if case .network = $0.mediaIdentity { return true }
            return false
        }
        if !hasNetwork { violations.append(.noNetworkDestination) }

        return violations
    }

    /// Start gating (design D6): hard errors always block; warn violations
    /// block only in strict mode.
    public static func canStart(violations: [RuleViolation], strictMode: Bool) -> Bool {
        if violations.contains(where: \.isHardError) { return false }
        return strictMode ? violations.isEmpty : true
    }
}
