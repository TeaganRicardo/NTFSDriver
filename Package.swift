// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NTFSDriver",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ntfs-inspect", targets: ["NTFSInspect"]),
        .library(name: "NTFSFSKit", targets: ["NTFSFSKit"]),
    ],
    targets: [
        .target(name: "NTFSCore"),
        .executableTarget(name: "NTFSInspect", dependencies: ["NTFSCore"]),
        .target(name: "NTFSFSKit", dependencies: ["NTFSCore"]),
        .testTarget(name: "NTFSDriverTests", dependencies: ["NTFSCore", "NTFSFSKit"]),
    ]
)
