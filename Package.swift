// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PackageDescription

// The host peer for the embedded↔host interoperability check on MQTT. It does
// not build the firmware; the Zenoh peer has its own manifest under
// Tests/zenoh-host-peer because it links the native zenoh-c archive. This one
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
        .executable(name: "HostSmokeAgent", targets: ["HostSmokeAgent"]),
        .executable(name: "HostAgentExchange", targets: ["HostAgentExchange"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/phynics/axoloty.git",
            revision: "087bd9bb1bfb563d0347799245ea4dd43e509bc9"
        ),
        .package(
            url: "https://github.com/swift-server-community/mqtt-nio.git",
            from: "2.13.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.101.2"
        ),
    ],
    targets: [
        .target(
            name: "DeviceSmokeApplication",
            dependencies: [
                "DeviceSmokeHostSupport",
                .product(name: "AxolotyWire", package: "Axoloty"),
                .product(name: "AxolotyProtocol", package: "Axoloty"),
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyCoatyModels", package: "Axoloty"),
            ],
            path: "Applications/device-smoke-agent/main",
            exclude: [
                // The ABI entry needs the @EmbeddedApplication plugin and the
                // EmbeddedCapabilities module. Only the firmware build wires
                // both; the host harness drives the seam directly.
                "DeviceSmokeCapabilityBridge.swift",
                "EmbeddedApplication.swift",
            ],
            swiftSettings: [
                .define("HOST_AGENT_EXCHANGE"),
                .swiftLanguageMode(.v5),
            ]
        ),
        // The carrier takes its topic and payload bounds from the composition.
        // The host package builds the smoke application's, 256 and 2,048, from
        // files that Tests/embedded/check-profile-composition.sh keeps equal to
        // what Tools/validate-composition.py writes for that profile.
        .target(
            name: "HostCarrierBounds",
            path: "Tests/host-carrier-bounds/Sources/HostCarrierBounds"
        ),
        .target(
            name: "EmbeddedMQTTClient",
            dependencies: ["MQTTCarrierInterop", "HostCarrierBounds"],
            path: "Transports/mqtt-espidf/main",
            sources: ["EmbeddedMQTTClient.swift", "CarrierNetworkProbe.swift"],
            swiftSettings: [.define("EMBEDDED_MQTT_HOST_TEST"), .define("EMBEDDED_MQTT_HOST_PACKAGE")]
        ),
        .target(
            name: "MQTTCarrierInterop",
            path: "Transports/mqtt-espidf",
            sources: ["main/mqtt_event_validation.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("../../Tests/host-carrier-bounds/include")]
        ),
        .target(
            name: "DeviceSmokeHostSupport",
            dependencies: ["EmbeddedMQTTClient"],
            path: "Tests/host-agent-support",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EmbeddedHostPeer",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
            ],
            path: "Tests/host-peer/Sources/EmbeddedHostPeer"
        ),
        .executableTarget(
            name: "HostSmokeAgent",
            dependencies: [
                "DeviceSmokeApplication",
                "EmbeddedMQTTClient",
                "MQTTCarrierInterop",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Tests/host-agent-exchange",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HostAgentExchange",
            dependencies: [
                .product(name: "AxolotyTestBroker", package: "Axoloty"),
            ],
            path: "Tests/embedded/broker"
        ),
    ],
    swiftLanguageModes: [.v6]
)
