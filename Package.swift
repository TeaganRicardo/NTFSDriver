// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NTFSDriver",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ntfs-inspect", targets: ["NTFSInspect"]),
        .executable(name: "ntfs-read", targets: ["NTFSRead"]),
        .executable(name: "NTFSModule", targets: ["NTFSModule"]),
        .executable(name: "NTFSManager", targets: ["NTFSManager"]),
        .library(name: "NTFSFSKit", targets: ["NTFSFSKit"]),
    ],
    targets: [
        .target(name: "NTFSCore"),
        .target(name: "CNTFSEngine", path: "Vendor/NTFS3G",
                exclude: ["AUTHORS", "COPYING", "COPYING.LIB", "README", "UPSTREAM.json"],
                sources: ["libntfs-3g"], publicHeadersPath: "include",
                cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("include/ntfs-3g")]),
        .target(name: "CNTFSBridge", dependencies: ["CNTFSEngine"]),
        .target(name: "NTFSReadOnly", dependencies: ["CNTFSBridge", "NTFSCore"]),
        .executableTarget(name: "NTFSRead", dependencies: ["NTFSReadOnly"]),
        .executableTarget(name: "NTFSModule", dependencies: ["NTFSFSKit"],
                           swiftSettings: [.unsafeFlags(["-application-extension"])]),
        .executableTarget(name: "NTFSManager"),
        .executableTarget(name: "NTFSInspect", dependencies: ["NTFSCore"]),
        .target(name: "NTFSFSKit", dependencies: ["NTFSCore", "NTFSReadOnly"]),
        .testTarget(name: "NTFSDriverTests", dependencies: ["NTFSCore", "NTFSFSKit", "NTFSReadOnly", "CNTFSBridge"],
                    resources: [.copy("Fixtures")]),
    ],
    cLanguageStandard: .gnu17
)
