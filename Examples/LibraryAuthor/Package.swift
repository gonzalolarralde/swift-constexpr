// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "LibraryAuthor",
    platforms: [.macOS(.v11)],
    products: [
        .library(
            name: "ManifestValues",
            targets: ["ManifestValues"]
        ),
        .library(
            name: "ManifestValuesConstExprProvider",
            targets: ["ManifestValuesConstExprProvider"]
        ),
        .library(
            name: "PackageDescriptionConstExprProvider",
            targets: ["PackageDescriptionConstExprProvider"]
        ),
    ],
    dependencies: [
        .package(name: "swift-constexpr", path: "../.."),
    ],
    targets: [
        .target(
            name: "ManifestValues",
            dependencies: [
                .product(name: "ConstExpr", package: "swift-constexpr"),
            ]
        ),
        .target(
            name: "ManifestValuesConstExprProvider",
            dependencies: [
                "ManifestValues",
                .product(name: "ConstExpr", package: "swift-constexpr"),
            ]
        ),
        .target(
            name: "PackageDescriptionModel",
            dependencies: [
                .product(name: "ConstExpr", package: "swift-constexpr"),
            ]
        ),
        .target(
            name: "PackageDescriptionConstExprProvider",
            dependencies: [
                "PackageDescriptionModel",
                .product(name: "ConstExpr", package: "swift-constexpr"),
            ]
        ),
    ]
)
