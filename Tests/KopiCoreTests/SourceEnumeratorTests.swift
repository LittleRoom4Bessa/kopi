import Foundation
import Testing
@testable import KopiCore

struct SourceEnumeratorTests {

    // Spec: junk filtering — .DS_Store, ._* excluded
    @Test func junkFilesExcluded() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("DCIM/photo.jpg", "image-data")
        try f.writeSource("DCIM/.DS_Store", "junk")
        try f.writeSource("DCIM/._photo.jpg", "appledouble")

        let plan = try SourceEnumerator.plan(source: f.source, destination: f.destination)

        #expect(plan.fileCount == 1)
        #expect(plan.entries.first?.relativePath == "DCIM/photo.jpg")
    }

    // Spec: junk filtering — .Trashes/.Spotlight-V100 etc. excluded at any depth
    @Test func junkDirectoriesExcludedAtAnyDepth() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("keep.jpg", "a")
        try f.writeSource(".Trashes/secret.jpg", "b")
        try f.writeSource("sub/.Spotlight-V100/index.jpg", "c")
        try f.writeSource(".fseventsd/log", "d")
        try f.writeSource(".TemporaryItems/t", "e")

        let plan = try SourceEnumerator.plan(source: f.source, destination: f.destination)

        #expect(plan.entries.map(\.relativePath) == ["keep.jpg"])
    }

    // Spec: pre-copy summary — totals available before copying
    @Test func planTotals() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        try f.writeSource("a.jpg", String(repeating: "x", count: 100))
        try f.writeSource("b/c.mov", String(repeating: "y", count: 250))

        let plan = try SourceEnumerator.plan(source: f.source, destination: f.destination)

        #expect(plan.fileCount == 2)
        #expect(plan.totalBytes == 350)
        #expect(plan.entries.map(\.size) == [100, 250])
    }
}
