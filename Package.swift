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
            revision: "827e598f3d97c5e2e7986d7be4ba1d9a5eac7906"
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
