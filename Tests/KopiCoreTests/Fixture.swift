import Foundation
import Testing

final class Fixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kopi-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("CARD")
        destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func writeSource(_ relativePath: String, _ content: String) throws -> URL {
        try write(content, at: source.appendingPathComponent(relativePath))
    }

    @discardableResult
    func writeDestination(_ relativePath: String, _ content: String) throws -> URL {
        try write(content, at: destination.appendingPathComponent(relativePath))
    }

    @discardableResult
    private func write(_ content: String, at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    func readDestination(_ relativePath: String) throws -> String {
        let data = try Data(contentsOf: destination.appendingPathComponent(relativePath))
        return String(decoding: data, as: UTF8.self)
    }

    func destinationExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(relativePath).path)
    }

    /// Extra destination roots for multi-destination tests.
    func makeDestination(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ relativePath: String, _ content: String, in root: URL) throws {
        try write(content, at: root.appendingPathComponent(relativePath))
    }

    func read(_ relativePath: String, in root: URL) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return String(decoding: data, as: UTF8.self)
    }

    func exists(_ relativePath: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }
}
