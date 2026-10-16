// swift-tools-version: 6.3

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "PacketKit",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "PacketKit", targets: ["PacketKit"]),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
    ],
    targets: [
        .target(
            name: "PacketKit",
            dependencies: ["PacketKitModel", "PacketKitMacros"]
        ),
        // Shared by the public API and the host-side macro, avoiding a cycle.
        .target(
            name: "PacketKitModel",
            dependencies: [
                .product(name: "ConstExpr", package: "swift-constexpr"),
            ]
        ),
        .macro(
            name: "PacketKitMacros",
            dependencies: [
                "PacketKitModel",
                .product(name: "ConstExpr", package: "swift-constexpr"),
                .product(name: "ConstExprMacroSupport", package: "swift-constexpr"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "PacketKitMacrosTests",
            dependencies: [
                "PacketKitMacros",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
