// swift-tools-version:6.3
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

// The host peer for the embedded↔host interoperability check. This is the only
// SwiftPM manifest in this repository: it does not build the firmware. It
// consumes the Axoloty host runtime as an ordinary pinned git dependency, at
// the exact revision in axoloty-core.lock.json, and nothing from Core's
// sources is vendored or read from a sibling checkout.
let package = Package(
    name: "axoloty-embedded-host",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .executable(name: "EmbeddedHostPeer", targets: ["EmbeddedHostPeer"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/phynics/axoloty.git",
            revision: "e065a7b9c0a690db22c71499ee482d163eb36261"
        ),
    ],
    targets: [
        .executableTarget(
            name: "EmbeddedHostPeer",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
            ],
            path: "Tests/host-peer/Sources/EmbeddedHostPeer"
        ),
    ],
    swiftLanguageModes: [.v6]
)
