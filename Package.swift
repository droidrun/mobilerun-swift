// swift-tools-version: 6.0
// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "MobilerunStream",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "MobilerunProtocol", targets: ["MobilerunProtocol"]),
        .library(name: "MobilerunStreamCore", targets: ["MobilerunStreamCore"]),
    ],
    targets: [
        .target(name: "MobilerunProtocol"),
        .target(name: "MobilerunStreamCore"),
        .testTarget(
            name: "MobilerunConformanceTests",
            dependencies: ["MobilerunProtocol", "MobilerunStreamCore"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
