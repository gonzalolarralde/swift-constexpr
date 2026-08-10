// swift-tools-version: 6.3

import Foundation
import PackageDescription

private func requiredPath(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fatalError("missing required environment variable \(name)")
    }
    return value
}

let package = Package(
    name: "ConstExprConsumerDriver",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(
            name: "swift-constexpr",
            path: requiredPath("CONSTEXPR_ROOT")
        ),
        .package(
            name: "LibraryAuthor",
            path: requiredPath("LIBRARY_AUTHOR_ROOT")
        ),
    ],
    targets: [
        .executableTarget(
            name: "ConstExprConsumerDriver",
            dependencies: [
                .product(name: "ConstExpr", package: "swift-constexpr"),
                .product(
                    name: "ManifestValuesConstExprProvider",
                    package: "LibraryAuthor"
                ),
                .product(
                    name: "PackageDescriptionConstExprProvider",
                    package: "LibraryAuthor"
                ),
            ]
        ),
    ]
)
