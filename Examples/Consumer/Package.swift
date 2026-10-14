// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PacketDemo",
    platforms: [.macOS(.v11)],
    dependencies: [
        .package(path: "../LibraryAuthor"),
    ],
    targets: [
        .executableTarget(
            name: "PacketDemo",
            dependencies: [
                .product(name: "PacketKit", package: "LibraryAuthor"),
            ]
        ),
        .testTarget(
            name: "PacketDemoTests",
            dependencies: [
                "PacketDemo",
                .product(name: "PacketKit", package: "LibraryAuthor"),
            ]
        ),
    ]
)
