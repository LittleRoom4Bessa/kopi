import Foundation
import Testing
@testable import KopiCore

struct HashingTests {

    private func hex(_ algorithm: HashAlgorithm, _ string: String) -> String {
        var hasher = algorithm.makeHasher()
        Data(string.utf8).withUnsafeBytes { hasher.update($0) }
        return hasher.finalize()
    }

    // Known-answer vectors (spec task 1.4)
    @Test func md5Vectors() {
        #expect(hex(.md5, "") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(hex(.md5, "abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(hex(.md5, "The quick brown fox jumps over the lazy dog")
            == "9e107d9d372bb6826bd81d3542a419d6")
    }

    @Test func sha256Vectors() {
        #expect(hex(.sha256, "")
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(.sha256, "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(.sha256, "The quick brown fox jumps over the lazy dog")
            == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    // Seed 0 vectors from the xxHash specification
    @Test func xxh64Vectors() {
        #expect(hex(.xxh64, "") == "ef46db3751d8e999")
        #expect(hex(.xxh64, "abc") == "44bc2cf5ad770999")
        #expect(hex(.xxh64, "Hello, world!") == "f58336a78b6f9476")
    }

    // Streaming in multiple updates must equal a single update
    @Test func streamingMatchesSingleShot() {
        let text = String(repeating: "kopi-", count: 10_000)
        for algorithm in HashAlgorithm.allCases {
            var one = algorithm.makeHasher()
            Data(text.utf8).withUnsafeBytes { one.update($0) }

            var streamed = algorithm.makeHasher()
            let data = Data(text.utf8)
            for chunkStart in stride(from: 0, to: data.count, by: 777) {
                let end = min(chunkStart + 777, data.count)
                data[chunkStart..<end].withUnsafeBytes { streamed.update($0) }
            }
            #expect(one.finalize() == streamed.finalize(), "\(algorithm) streaming mismatch")
        }
    }

    // Manifest naming per algorithm
    @Test func manifestNamingPerAlgorithm() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let files = [(relativePath: "a.jpg", hash: "deadbeef")]
        let md5URL = try #require(try ManifestWriter.write(
            destinationRoot: f.destination, verifiedFiles: files, algorithm: .md5))
        let xxhURL = try #require(try ManifestWriter.write(
            destinationRoot: f.destination, verifiedFiles: files, algorithm: .xxh64))
        let shaURL = try #require(try ManifestWriter.write(
            destinationRoot: f.destination, verifiedFiles: files, algorithm: .sha256))

        #expect(md5URL.pathExtension == "md5")
        #expect(xxhURL.pathExtension == "xxh64")
        #expect(shaURL.pathExtension == "sha256")
        for url in [md5URL, xxhURL, shaURL] {
            #expect(url.lastPathComponent.hasPrefix("kopi-manifest-"))
            #expect(try String(contentsOf: url) == "deadbeef  a.jpg\n")
        }
    }

    // Engine honors the plan's algorithm end-to-end
    @Test func engineUsesPlanAlgorithm() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", "alpha")
        for algorithm in HashAlgorithm.allCases {
            let plan = CopyPlan(
                sourceRoot: f.source,
                destinationRoot: f.destination,
                entries: try SourceEnumerator.plan(
                    source: f.source, destination: f.destination).entries,
                algorithm: algorithm
            )
            let report = CopyEngine().run(plan: plan) { _ in }
            let dest = report.primaryDestination
            #expect(report.algorithm == algorithm)
            #expect(dest?.copied.first?.hash == hex(algorithm, "alpha"))
            #expect(dest?.manifestURL?.pathExtension == algorithm.manifestExtension)
            try FileManager.default.removeItem(at: f.destination.appendingPathComponent("a.jpg"))
        }
    }
}
