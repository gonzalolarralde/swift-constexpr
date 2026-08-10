// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "ConstExpr",
    platforms: [.macOS(.v11)],
    products: [
        .library(
            name: "ConstExpr",
            targets: ["ConstExpr"]
        ),
        .executable(
            name: "swift-constexpr-example",
            targets: ["ConstExprExampleCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ConstExpr", dependencies: [
                "ConstExprMacros",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .macro(
            name: "ConstExprMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "ConstExprExampleDefinitions",
            dependencies: ["ConstExpr"]
        ),
        .target(
            name: "ConstExprExampleRegistry",
            dependencies: ["ConstExpr", "ConstExprExampleDefinitions"]
        ),
        .executableTarget(
            name: "ConstExprExampleCLI",
            dependencies: ["ConstExpr", "ConstExprExampleRegistry"]
        ),
        .testTarget(
            name: "ConstExprTests",
            dependencies: ["ConstExpr"]
        ),
        .testTarget(
            name: "ConstExprRuntimeTests",
            dependencies: [
                "ConstExpr",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ConstExprMacrosTests",
            dependencies: [
                "ConstExprMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ConstExprIntegrationTests",
            dependencies: [
                "ConstExpr",
                "ConstExprExampleDefinitions",
                "ConstExprExampleRegistry",
            ]
        ),
    ]
)
