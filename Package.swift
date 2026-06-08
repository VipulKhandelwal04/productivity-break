// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cat-break",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "cat-break",
            path: "Sources/cat-break"
        )
    ]
)
