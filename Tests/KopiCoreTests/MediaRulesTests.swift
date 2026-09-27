import Foundation
import Testing
@testable import KopiCore

struct MediaRulesTests {

    private func disk(
        _ path: String, identity: MediaIdentity, type: DiskType = .externalSSD
    ) -> DiskDescriptor {
        DiskDescriptor(
            path: URL(fileURLWithPath: path), volumeName: URL(fileURLWithPath: path).lastPathComponent,
            type: type, bus: .usb, totalBytes: 1 << 30, freeBytes: 1 << 29,
            mediaIdentity: identity
        )
    }

    private let source = DiskDescriptor(
        path: URL(fileURLWithPath: "/Volumes/CARD"), volumeName: "CARD",
        type: .sdCard, bus: .sd, totalBytes: 1 << 30, freeBytes: 1 << 29,
        mediaIdentity: .local("disk4")
    )

    // Spec: warn mode — same-disk destinations badge but don't block
    @Test func sameDiskWarnsButAllowsInWarnMode() {
        let dests = [
            disk("/Volumes/A", identity: .local("disk5")),
            disk("/Volumes/B", identity: .local("disk5")),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(violations == [.samePhysicalDisk("disk5")])
        #expect(MediaRules.canStart(violations: violations, strictMode: false))
    }

    // Spec: strict mode — same-disk destinations block Start
    @Test func sameDiskBlocksInStrictMode() {
        let dests = [
            disk("/Volumes/A", identity: .local("disk5")),
            disk("/Volumes/B", identity: .local("disk5")),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(!MediaRules.canStart(violations: violations, strictMode: true))
    }

    // Spec: no network destination — warn in warn mode, block in strict
    @Test func noNetworkDestination() {
        let dests = [
            disk("/Volumes/A", identity: .local("disk5")),
            disk("/Volumes/B", identity: .local("disk6")),
            disk("/Volumes/C", identity: .local("disk7")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(violations == [.noNetworkDestination])
        #expect(MediaRules.canStart(violations: violations, strictMode: false))
        #expect(!MediaRules.canStart(violations: violations, strictMode: true))
    }

    // Spec: destination on the source disk is always a hard error
    @Test func destinationOnSourceAlwaysBlocks() {
        let dests = [
            disk("/Volumes/CARD/out", identity: .local("disk4")),
            disk("/Volumes/B", identity: .local("disk6")),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        for strict in [false, true] {
            let violations = MediaRules.evaluate(source: source, destinations: dests)
            #expect(violations.contains(.destinationOnSource("disk4")))
            #expect(!MediaRules.canStart(violations: violations, strictMode: strict))
        }
    }

    // Spec: duplicate folder is always a hard error
    @Test func duplicateFolderAlwaysBlocks() {
        let dests = [
            disk("/Volumes/A/out", identity: .local("disk5")),
            disk("/Volumes/A/out", identity: .local("disk5")),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(violations.contains(.duplicateDestination("/Volumes/A/out")))
        #expect(!MediaRules.canStart(violations: violations, strictMode: false))
    }

    // Spec: clean 3-2-1 setup passes both modes
    @Test func cleanSetupPasses() {
        let dests = [
            disk("/", identity: .local("disk3"), type: .internalSSD),
            disk("/Volumes/Ext", identity: .local("disk6")),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(violations.isEmpty)
        #expect(MediaRules.canStart(violations: violations, strictMode: true))
    }

    // Unknown identities never accuse
    @Test func unknownIdentitiesAreNotAccused() {
        let dests = [
            disk("/Volumes/A", identity: .unknown),
            disk("/Volumes/B", identity: .unknown),
            disk("/Volumes/photos", identity: .network("//nas/photos")),
        ]
        let violations = MediaRules.evaluate(source: source, destinations: dests)
        #expect(!violations.contains { if case .samePhysicalDisk = $0 { true } else { false } })
    }

    // Settings round-trip through Codable
    @Test func proSettingsRoundTrip() throws {
        var settings = ProSettings()
        settings.destinations = ["/a", "/b", "/c"]
        settings.algorithm = .sha256
        settings.strictMode = true
        let decoded = try JSONDecoder().decode(ProSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(ProSettings().algorithm == .xxh64) // fast verify is the default
        #expect(ProSettings().strictMode == false) // strict is opt-in
    }
}
