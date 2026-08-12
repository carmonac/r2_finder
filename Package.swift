// swift-tools-version: 6.0
// R2 Finder – macOS Finder clone
// Build with:   swift build -c release
// Test with:    swift test
// Bundle with:  Scripts/bundle.sh <version>   →  .build/R2 Finder.app
import PackageDescription

let package = Package(
    name: "R2Finder",
    platforms: [.macOS(.v13)],
    targets: [
        // Service layer: filesystem, volumes, rsync transfers, 7zz archives.
        .target(
            name: "R2FinderServices",
            path: "Sources/R2FinderServices",
            // NetFS drives the system mount/authentication machinery used by
            // NetworkMountService (see Sources/R2FinderServices/NetworkMountService.swift).
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        // The app: entry point + AppKit UI. Named rs_2finder so the produced
        // binary matches CFBundleExecutable in Info.plist.
        .executableTarget(
            name: "rs_2finder",
            dependencies: ["R2FinderServices"],
            path: "Sources/R2Finder"
        ),
        .testTarget(
            name: "R2FinderTests",
            dependencies: ["R2FinderServices"],
            path: "Tests/R2FinderTests"
        ),
    ]
)
