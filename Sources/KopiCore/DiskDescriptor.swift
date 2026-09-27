import Foundation

/// Stable identity of the physical media behind a volume (design D1/D5).
/// Local volumes identify by whole-disk BSD name (partition stripped);
/// network volumes by server/share. Valid within a boot session.
public enum MediaIdentity: Equatable, Sendable {
    case local(String)   // e.g. "disk4"
    case network(String) // e.g. "//user@nas/photos"
    case unknown
}

public enum DiskType: String, Sendable {
    case sdCard, externalSSD, hdd, internalSSD, networkVolume, unknown

    public var displayName: String {
        switch self {
        case .sdCard: return "SD card"
        case .externalSSD: return "External SSD"
        case .hdd: return "External HDD"
        case .internalSSD: return "Internal SSD"
        case .networkVolume: return "Network volume"
        case .unknown: return "Unknown disk"
        }
    }
}

public enum ConnectionBus: String, Sendable {
    case usb, thunderbolt, sd, nvme, sata, network, unknown

    public var displayName: String {
        switch self {
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .sd: return "SD"
        case .nvme: return "NVMe"
        case .sata: return "SATA"
        case .network: return "Network"
        case .unknown: return "Unknown bus"
        }
    }
}

/// Theoretical interface ceiling, shown instantly on selection and clearly
/// labeled as theoretical. Never a measured value (design D2).
public func interfaceSpeedLabel(for bus: ConnectionBus) -> String {
    switch bus {
    case .usb: return "USB · up to ~10 Gbps"
    case .thunderbolt: return "Thunderbolt · up to ~40 Gbps"
    case .sd: return "SD bus · up to ~300 MB/s"
    case .nvme: return "NVMe · up to ~7 GB/s"
    case .sata: return "SATA · up to ~600 MB/s"
    case .network: return "Network · 1 GbE ≈ ~110 MB/s"
    case .unknown: return "Unknown interface speed"
    }
}

/// Characterization of a mounted volume for display and 3-2-1 rules.
/// Every field has an explicit unknown representation; missing metadata
/// never blocks use of the volume (design risk mitigation).
public struct DiskDescriptor: Equatable, Sendable {
    public let path: URL
    public let volumeName: String?
    public let type: DiskType
    public let bus: ConnectionBus
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    public let mediaIdentity: MediaIdentity

    public init(
        path: URL, volumeName: String?, type: DiskType, bus: ConnectionBus,
        totalBytes: Int64?, freeBytes: Int64?, mediaIdentity: MediaIdentity
    ) {
        self.path = path
        self.volumeName = volumeName
        self.type = type
        self.bus = bus
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.mediaIdentity = mediaIdentity
    }

    public var interfaceSpeedLabel: String { KopiCore.interfaceSpeedLabel(for: bus) }
}

/// Raw platform observations; the classifier below is pure and testable.
public struct RawDiskInfo: Equatable, Sendable {
    public var volumeName: String?
    public var isNetwork: Bool
    public var isInternal: Bool
    public var protocolString: String?
    public var model: String?
    public var rotational: Bool?
    public var totalBytes: Int64?
    public var freeBytes: Int64?
    public var mediaIdentity: MediaIdentity

    public init(
        volumeName: String? = nil, isNetwork: Bool = false, isInternal: Bool = false,
        protocolString: String? = nil, model: String? = nil, rotational: Bool? = nil,
        totalBytes: Int64? = nil, freeBytes: Int64? = nil, mediaIdentity: MediaIdentity = .unknown
    ) {
        self.volumeName = volumeName
        self.isNetwork = isNetwork
        self.isInternal = isInternal
        self.protocolString = protocolString
        self.model = model
        self.rotational = rotational
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.mediaIdentity = mediaIdentity
    }
}

/// Maps raw DiskArbitration/statfs observations to a DiskDescriptor.
public enum DiskClassifier {

    public static func bus(fromProtocol proto: String?, isNetwork: Bool) -> ConnectionBus {
        if isNetwork { return .network }
        guard let proto = proto?.lowercased() else { return .unknown }
        if proto.contains("thunderbolt") { return .thunderbolt }
        if proto.contains("usb") { return .usb }
        if proto.contains("secure digital") || proto == "sd" { return .sd }
        if proto.contains("nvme") || proto.contains("pci-express") || proto.contains("apple fabric") {
            return .nvme
        }
        if proto.contains("sata") { return .sata }
        return .unknown
    }

    public static func type(from raw: RawDiskInfo, bus: ConnectionBus) -> DiskType {
        if raw.isNetwork { return .networkVolume }
        if bus == .sd { return .sdCard }
        if raw.isInternal { return .internalSSD }
        if raw.rotational == true { return .hdd }
        if let model = raw.model?.lowercased(), model.contains("ssd") { return .externalSSD }
        // External, non-rotational media we can't further classify: most
        // external flash on USB/TB is SSD-like; NVMe/TB externals certainly are.
        if bus == .nvme || bus == .thunderbolt { return .externalSSD }
        return .unknown
    }

    public static func describe(path: URL, raw: RawDiskInfo) -> DiskDescriptor {
        let bus = bus(fromProtocol: raw.protocolString, isNetwork: raw.isNetwork)
        return DiskDescriptor(
            path: path,
            volumeName: raw.volumeName,
            type: type(from: raw, bus: bus),
            bus: bus,
            totalBytes: raw.totalBytes,
            freeBytes: raw.freeBytes,
            mediaIdentity: raw.mediaIdentity
        )
    }
}
