// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "productivity_break",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "productivity_break",
            path: "Sources/productivity_break"
        )
    ]
)
