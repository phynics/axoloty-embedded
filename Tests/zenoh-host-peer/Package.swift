// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

// The host peer for the embedded↔host check on the Zenoh profile. It is separate
// from the root manifest because AxolotyZenoh links the native zenoh-c archive and
// is published only as a subdirectory package of Core, which SwiftPM cannot resolve
// from a URL. The runner reads both directories from the Core preparation report
// and refuses a report that is not clean and at the locked revision.
let environment = Context.environment
guard let core = environment["AXOLOTY_SOURCE_DIR"],
      let zenohPackage = environment["AXOLOTY_ZENOH_PACKAGE_DIR"] else {
    fatalError("AXOLOTY_SOURCE_DIR and AXOLOTY_ZENOH_PACKAGE_DIR are required")
}

let package = Package(
    name: "axoloty-embedded-zenoh-host",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ZenohHostPeer", targets: ["ZenohHostPeer"]),
    ],
    dependencies: [
        .package(name: "Axoloty", path: core),
        .package(name: "AxolotyZenoh", path: zenohPackage),
    ],
    targets: [
        .executableTarget(
            name: "ZenohHostPeer",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
                .product(name: "AxolotyZenoh", package: "AxolotyZenoh"),
            ]
        ),
    ]
)
