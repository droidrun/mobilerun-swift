// swift-tools-version: 6.2
// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "MobilerunStream",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "MobilerunStream", targets: ["MobilerunStream"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/webrtc-xcframework", exact: "150.7871.05"),
    ],
    targets: [
        .target(name: "MobilerunProtocol"),
        .target(name: "MobilerunStreamCore", dependencies: ["MobilerunProtocol"]),
        .target(name: "MobilerunStream", dependencies: [
            "MobilerunProtocol", "MobilerunStreamCore",
            .product(name: "LiveKitWebRTC", package: "webrtc-xcframework", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(
            name: "MobilerunConformanceTests",
            dependencies: ["MobilerunProtocol", "MobilerunStreamCore", "MobilerunStream"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
