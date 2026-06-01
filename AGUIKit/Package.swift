// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AGUIKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "AGUIKit", targets: ["AGUIKit"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AGUIKit",
            path: "Sources/AGUIKit"
        ),
        .testTarget(
            name: "AGUIKitTests",
            dependencies: ["AGUIKit"],
            path: "Tests/AGUIKitTests"
        ),
    ]
)
