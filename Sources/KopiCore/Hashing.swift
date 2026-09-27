import CryptoKit
import CxxHash
import Foundation

/// Per-file verification algorithm. Casual mode uses MD5; pro mode offers
/// xxHash64 (fast, default) or SHA-256 (forensic). Design D4.
public enum HashAlgorithm: String, CaseIterable, Codable, Sendable {
    case md5
    case xxh64
    case sha256

    /// Manifest filename extension (`kopi-manifest-<ts>.<ext>`).
    public var manifestExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .md5: return "MD5"
        case .xxh64: return "xxHash64"
        case .sha256: return "SHA-256"
        }
    }

    /// Pro-mode label shown next to the picker.
    public var subtitle: String {
        switch self {
        case .md5: return "casual"
        case .xxh64: return "fast verify"
        case .sha256: return "forensic"
        }
    }
}

/// Streaming hasher producing a lowercase hex digest.
public protocol Hasher {
    mutating func update(_ bytes: UnsafeRawBufferPointer)
    /// Consumes the hasher; do not update after finalizing.
    mutating func finalize() -> String
}

extension Hasher {
    public mutating func update(data: Data) {
        data.withUnsafeBytes { update($0) }
    }
}

public struct MD5Hasher: Hasher {
    private var inner = Insecure.MD5()
    public init() {}
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        inner.update(bufferPointer: bytes)
    }
    public mutating func finalize() -> String {
        inner.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SHA256Hasher: Hasher {
    private var inner = SHA256()
    public init() {}
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        inner.update(bufferPointer: bytes)
    }
    public mutating func finalize() -> String {
        inner.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// xxHash64 via the vendored official C reference implementation (xxHash v0.8.3,
/// BSD-2-Clause, in Sources/CxxHash — upstream ships no Package.swift).
/// A class (not struct) so the heap-allocated XXH64 state has exactly one
/// owner with a `deinit` — no double-free or leak on copies/early exit.
public final class XXH64Hasher: Hasher {
    private var state: OpaquePointer?

    public init() {
        state = XXH64_createState()
        XXH64_reset(state, 0)
    }

    public func update(_ bytes: UnsafeRawBufferPointer) {
        guard let state, let base = bytes.baseAddress, bytes.count > 0 else { return }
        XXH64_update(state, base, bytes.count)
    }

    public func finalize() -> String {
        guard let state else { return String(repeating: "0", count: 16) }
        let digest = XXH64_digest(state)
        XXH64_freeState(state)
        self.state = nil
        return String(format: "%016llx", digest)
    }

    deinit {
        if let state { XXH64_freeState(state) }
    }
}

extension HashAlgorithm {
    public func makeHasher() -> any Hasher {
        switch self {
        case .md5: return MD5Hasher()
        case .xxh64: return XXH64Hasher()
        case .sha256: return SHA256Hasher()
        }
    }
}
