// swift-tools-version:6.4
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
        .executable(name: "HostSmokeAgent", targets: ["HostSmokeAgent"]),
        .executable(name: "HostAgentExchange", targets: ["HostAgentExchange"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/phynics/axoloty.git",
            revision: "0579663a9d33c0a017cbb3ad5d74dd1b80a8853f"
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
                "StaticDeviceAgentInterop",
                .product(name: "AxolotyWire", package: "Axoloty"),
                .product(name: "AxolotyProtocol", package: "Axoloty"),
                .product(name: "AxolotyObjectModel", package: "Axoloty"),
                .product(name: "AxolotyCoatyModels", package: "Axoloty"),
            ],
            path: "Applications/device-smoke-agent/main",
            swiftSettings: [
                .define("HOST_AGENT_EXCHANGE"),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "StaticDeviceAgentInterop",
            path: "Applications/device-smoke-agent",
            sources: ["interop/static_device_agent_interop.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "EmbeddedMQTTClient",
            dependencies: ["MQTTCarrierInterop"],
            path: "Transports/mqtt-espidf/main",
            sources: ["EmbeddedMQTTClient.swift", "CarrierNetworkProbe.swift"],
            swiftSettings: [.define("EMBEDDED_MQTT_HOST_TEST")]
        ),
        .target(
            name: "MQTTCarrierInterop",
            path: "Transports/mqtt-espidf",
            sources: ["main/mqtt_event_validation.c"],
            publicHeadersPath: "include"
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
