import Foundation
import Testing
@testable import KopiCore

struct DiskIntelligenceTests {

    // MARK: Classifier (pure, fixture-driven)

    @Test func sdCardClassification() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/EOS_R5"), raw: RawDiskInfo(
            volumeName: "EOS_R5", protocolString: "Secure Digital",
            model: "SDXC Reader", totalBytes: 128 << 30, freeBytes: 64 << 30,
            mediaIdentity: .local("disk4")
        ))
        #expect(d.type == .sdCard)
        #expect(d.bus == .sd)
        #expect(d.volumeName == "EOS_R5")
        #expect(d.interfaceSpeedLabel.contains("~300 MB/s"))
        #expect(d.mediaIdentity == .local("disk4"))
    }

    @Test func usbExternalSSDClassification() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/T7"), raw: RawDiskInfo(
            protocolString: "USB", model: "Samsung T7 SSD",
            mediaIdentity: .local("disk5")
        ))
        #expect(d.type == .externalSSD)
        #expect(d.bus == .usb)
        #expect(d.interfaceSpeedLabel.contains("Gbps"))
    }

    // Spec flagship scenario: SD card in a USB-C reader → type "SD card", bus "USB"
    @Test func sdCardInUSBReaderClassification() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/EOS_R5"), raw: RawDiskInfo(
            volumeName: "EOS_R5", protocolString: "USB", model: "SDXC/MMC Card Reader",
            totalBytes: 128 << 30, freeBytes: 64 << 30,
            mediaIdentity: .local("disk4")
        ))
        #expect(d.type == .sdCard)
        #expect(d.bus == .usb)
    }

    // "SD" inside "SSD" must not trigger card-reader detection
    @Test func ssdIsNotMisreadAsSDCard() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/T5"), raw: RawDiskInfo(
            protocolString: "USB", model: "Portable SSD T5",
            mediaIdentity: .local("disk5")
        ))
        #expect(d.type == .externalSSD)
    }

    @Test func rotationalExternalIsHDD() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/Archive"), raw: RawDiskInfo(
            protocolString: "USB", model: "WDC WD40", rotational: true,
            mediaIdentity: .local("disk6")
        ))
        #expect(d.type == .hdd)
    }

    @Test func internalAppleSiliconIsNVMeSSD() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/"), raw: RawDiskInfo(
            volumeName: "Macintosh HD", isInternal: true,
            protocolString: "Apple Fabric", model: "APPLE SSD AP0256Z",
            mediaIdentity: .local("disk3")
        ))
        #expect(d.type == .internalSSD)
        #expect(d.bus == .nvme)
    }

    @Test func networkVolumeClassification() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/photos"), raw: RawDiskInfo(
            volumeName: "photos", isNetwork: true,
            mediaIdentity: .network("//bessa@nas/photos")
        ))
        #expect(d.type == .networkVolume)
        #expect(d.bus == .network)
        #expect(d.mediaIdentity == .network("//bessa@nas/photos"))
    }

    @Test func unknownProtocolDegradesGracefully() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/X"), raw: RawDiskInfo())
        #expect(d.bus == .unknown)
        #expect(d.type == .unknown)
        #expect(d.totalBytes == nil)
        #expect(d.interfaceSpeedLabel == "Unknown interface speed")
    }

    @Test func thunderboltExternalDefaultsToSSD() {
        let d = DiskClassifier.describe(path: URL(fileURLWithPath: "/Volumes/Fast"), raw: RawDiskInfo(
            protocolString: "Thunderbolt", mediaIdentity: .local("disk7")
        ))
        #expect(d.type == .externalSSD)
        #expect(d.interfaceSpeedLabel.contains("~40 Gbps"))
    }

    // MARK: Real inspection of the boot volume (integration smoke test)

    @Test func inspectBootVolume() {
        let d = DiskInspector.inspect(path: URL(fileURLWithPath: "/"))
        #expect(d.type == .internalSSD)
        #expect(d.totalBytes ?? 0 > 0)
        #expect(d.freeBytes ?? 0 > 0)
        if case .local(let id) = d.mediaIdentity {
            #expect(id.hasPrefix("disk"))
        } else {
            Issue.record("expected local media identity, got \(d.mediaIdentity)")
        }
    }

    // MARK: SpeedProbe (small sizes on the real tmp volume)

    @Test func destinationProbeMeasuresAndCleansUp() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let result = try SpeedProbe.probeDestination(at: f.destination, totalBytes: 8 << 20)
        #expect(result.writeBytesPerSecond ?? 0 > 0)
        #expect(result.readBytesPerSecond ?? 0 > 0)
        // Temp file removed after probe
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.destination.path)
            .filter { $0.contains(".kopi-speedtest-") }
        #expect(leftovers.isEmpty)
    }

    @Test func destinationProbeCancelCleansUp() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        var calls = 0
        #expect(throws: SpeedProbeError.cancelled) {
            _ = try SpeedProbe.probeDestination(at: f.destination, totalBytes: 64 << 20) {
                calls += 1
                return calls > 2 // cancel after a couple of chunks
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.destination.path)
            .filter { $0.contains(".kopi-speedtest-") }
        #expect(leftovers.isEmpty)
    }

    @Test func sourceProbeIsReadOnly() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("big.bin", String(repeating: "x", count: 4 << 20))
        let before = try String(contentsOf: f.source.appendingPathComponent("big.bin"))

        let result = try SpeedProbe.probeSource(at: f.source, maxBytes: 4 << 20)

        #expect(result.readBytesPerSecond ?? 0 > 0)
        #expect(result.writeBytesPerSecond == nil)
        #expect(try String(contentsOf: f.source.appendingPathComponent("big.bin")) == before)
        // Nothing new written anywhere under the source
        let files = try FileManager.default.contentsOfDirectory(atPath: f.source.path)
        #expect(files == ["big.bin"])
    }

    @Test func sourceProbeOnEmptyVolumeThrows() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(throws: SpeedProbeError.noReadableFile) {
            _ = try SpeedProbe.probeSource(at: f.source, maxBytes: 1 << 20)
        }
    }
}
