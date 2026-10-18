// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
        .executable(name: "DiskLensApp", targets: ["DiskLensApp"]),
        .executable(name: "disklens-cli", targets: ["disklens-cli"]),
    ],
    targets: [
        .target(name: "DiskLensCore"),
        // DISKLENS_SNAPSHOTS enables the offscreen --snapshot/--demo renderer used for store
        // screenshots. The Xcode (App Store) target does not define it, so it is compiled out there.
        .executableTarget(name: "DiskLensApp", dependencies: ["DiskLensCore"],
                          swiftSettings: [.define("DISKLENS_SNAPSHOTS")]),
        .executableTarget(name: "disklens-cli", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
