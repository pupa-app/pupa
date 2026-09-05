// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pupa",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // The reusable iOS/macOS app code: views, state stores, tools.
        // Drop this into an Xcode App target's Package Dependencies and import PupaApp.
        .library(name: "PupaApp", targets: ["PupaApp"]),
        // A macOS-runnable build of the same app, useful for fast iteration
        // outside Xcode. Start a backend on :8004 (see backend/), then `swift run PupaDemo`.
        .executable(name: "PupaDemo", targets: ["PupaDemo"]),
        // Debug harness: drive a real app graph headlessly against a scripted
        // or live backend. Not linked by the app — see docs/testing.md.
        .library(name: "PupaHarness", targets: ["PupaHarness"]),
        // Drive the app from a shell — chat turns, replay, record, dump.
        .executable(name: "PupaCtl", targets: ["PupaCtl"]),
    ],
    dependencies: [
        .package(path: "../AGUIKit"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // GoogleWebRTC xcframework wrapped as SwiftPM. Same dep as
        // screenshare-sidecar so publisher + viewer speak the same SDK build.
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        // Canned-backend scripting. Below PupaApp so the launched app can
        // serve a script itself (`-PupaScript`) without depending on the
        // harness that sits above it.
        .target(
            name: "PupaScripting",
            dependencies: [.product(name: "AGUIKit", package: "AGUIKit")],
            path: "Sources/PupaScripting"
        ),
        .target(
            name: "PupaApp",
            dependencies: [
                "PupaScripting",
                .product(name: "AGUIKit", package: "AGUIKit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/PupaApp",
            resources: [.process("Resources")]
        ),
        .target(
            name: "PupaHarness",
            dependencies: [
                "PupaApp",
                "PupaScripting",
                .product(name: "AGUIKit", package: "AGUIKit"),
            ],
            path: "Sources/PupaHarness"
        ),
        .executableTarget(
            name: "PupaCtl",
            dependencies: ["PupaApp", "PupaHarness", "PupaScripting"],
            path: "Sources/PupaCtl"
        ),
        .executableTarget(
            name: "PupaDemo",
            dependencies: ["PupaApp"],
            path: "Sources/PupaDemo"
        ),
        .testTarget(
            name: "PupaAppTests",
            dependencies: ["PupaApp", "PupaHarness", "PupaScripting"],
            path: "Tests/PupaAppTests"
        ),
    ]
)
