import DiskArbitration
import Foundation

/// Characterizes mounted volumes via statfs + DiskArbitration (design D1).
/// All platform glue lives here; classification is pure in DiskClassifier.
public enum DiskInspector {

    /// Characterize the volume hosting `path`. Never throws — undeterminable
    /// fields degrade to explicit unknowns.
    public static func inspect(path: URL) -> DiskDescriptor {
        DiskClassifier.describe(path: path, raw: rawInfo(for: path))
    }

    public static func rawInfo(for path: URL) -> RawDiskInfo {
        var raw = RawDiskInfo()

        // Capacity / free space
        if let values = try? path.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey
        ]) {
            raw.totalBytes = values.volumeTotalCapacity.map(Int64.init)
            raw.freeBytes = values.volumeAvailableCapacity.map(Int64.init)
            raw.volumeName = values.volumeName
        }

        // statfs: BSD name / filesystem type / mount source
        var sb = statfs()
        guard statfs(path.path, &sb) == 0 else { return raw }
        let mountFrom = tupleToString(sb.f_mntfromname)
        let fsType = tupleToString(sb.f_fstypename)
        let isNetworkFS = ["smbfs", "nfs", "webdavfs", "osxfuse"].contains(fsType)
            || mountFrom.hasPrefix("//")

        if isNetworkFS {
            raw.isNetwork = true
            raw.mediaIdentity = .network(mountFrom)
            // DiskArbitration may still know the volume name.
            if raw.volumeName == nil, let desc = diskDescription(bsdName: nil, path: path) {
                raw.volumeName = desc["DAVolumeName"] as? String
            }
            return raw
        }

        let bsdName = mountFrom.replacingOccurrences(of: "/dev/", with: "")
        guard !bsdName.isEmpty, let desc = diskDescription(bsdName: bsdName, path: path) else {
            raw.mediaIdentity = .unknown
            return raw
        }

        raw.volumeName = raw.volumeName ?? desc["DAVolumeName"] as? String
        raw.isNetwork = (desc["DAVolumeNetwork"] as? Bool) ?? false
        raw.isInternal = (desc["DADeviceInternal"] as? Bool) ?? false
        raw.protocolString = desc["DADeviceProtocol"] as? String
        raw.model = desc["DADeviceModel"] as? String
        // Rotational isn't published for all disks; try known keys.
        for key in ["DAMediaRotational", "Rotational"] {
            if let value = desc[key] as? Bool { raw.rotational = value }
        }

        if raw.isNetwork {
            raw.mediaIdentity = .network(mountFrom)
        } else if let unit = desc["DAMediaBSDUnit"] as? Int {
            // Whole-disk identity: the BSD unit number identifies the physical
            // disk regardless of which partition/volume was picked.
            raw.mediaIdentity = .local("disk\(unit)")
        } else {
            raw.mediaIdentity = .unknown
        }
        return raw
    }

    private static func diskDescription(bsdName: String?, path: URL) -> [String: Any]? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let disk: DADisk?
        if let bsdName {
            disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
        } else {
            disk = nil
        }
        guard let disk else { return nil }
        return DADiskCopyDescription(disk) as? [String: Any]
    }

    private static func tupleToString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
