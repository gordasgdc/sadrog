// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sadrog",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Sadrog", targets: ["Sadrog"])],
    targets: [
        .target(name: "SadrogCore"),
        .executableTarget(name: "Sadrog", dependencies: ["SadrogCore"]),
        // development tools for capture probes (not part of the app bundle)
        .executableTarget(name: "SadrogSyncProbe"),
        .executableTarget(name: "SadrogProbeGuard", dependencies: ["SadrogCore"]),
        .testTarget(name: "SadrogCoreTests", dependencies: ["SadrogCore"]),
    ],
    swiftLanguageModes: [.v5]
)
