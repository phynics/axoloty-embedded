// swift-tools-version:6.4
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "EmbeddedApplicationMacros",
    products: [
        .executable(name: "embedded-application-macro-probe", targets: ["MacroProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .macro(
            name: "EmbeddedApplicationMacroImplementation",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "MacroProbe", dependencies: ["EmbeddedApplicationMacroImplementation"]),
    ]
)
