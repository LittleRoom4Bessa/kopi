// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kopi",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CxxHash",
            path: "Sources/CxxHash"
        ),
        .target(
            name: "KopiCore",
            dependencies: ["CxxHash"],
            path: "Sources/KopiCore"
        ),
        .executableTarget(
            name: "kopi",
            dependencies: ["KopiCore"],
            path: "Sources/kopi"
        ),
        .testTarget(
            name: "KopiCoreTests",
            dependencies: ["KopiCore"],
            path: "Tests/KopiCoreTests"
        )
    ]
)
