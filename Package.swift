// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "productivity_break",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        // Pure, testable logic — no AppKit / IO / network.
        .target(
            name: "ProductivityBreakCore",
            path: "Sources/ProductivityBreakCore"
        ),
        .executableTarget(
            name: "productivity_break",
            dependencies: ["ProductivityBreakCore"],
            path: "Sources/productivity_break"
        ),
        .testTarget(
            name: "ProductivityBreakCoreTests",
            dependencies: ["ProductivityBreakCore"],
            path: "Tests/ProductivityBreakCoreTests"
        )
    ]
)
