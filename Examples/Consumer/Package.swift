// swift-tools-version: 6.3

import PackageDescription

let executableName = "Const" + "Expr" + "Consumer"
let localSupport: Target.Dependency = "LocalSupport"
let minimumPlatform: SupportedPlatform = .macOS(.v13)
let packageTraits: Set<Trait> = [
    .default(enabledTraits: ["Metrics"]),
    "Metrics",
]

let supportProduct: Product = .library(
    name: "ConstExprConsumerSupport",
    targets: ["LocalSupport"]
)
let executableProduct: Product = .executable(
    name: executableName,
    targets: [executableName]
)
let authorDependency: Package.Dependency = .package(
    path: "../LibraryAuthor"
)

let supportTarget: Target = .target(name: "LocalSupport")
let applicationTarget: Target = .executableTarget(
    name: executableName,
    dependencies: [
        localSupport,
        .product(
            name: "ManifestValues",
            package: "LibraryAuthor"
        ),
    ]
)

let package: Package = .init(
    name: executableName,
    platforms: [minimumPlatform],
    products: [
        supportProduct,
        executableProduct,
    ],
    traits: packageTraits,
    dependencies: [
        authorDependency,
    ],
    targets: [
        supportTarget,
        applicationTarget,
    ]
)

// The facade can carry the otherwise non-renderable Package instance through
// the binding and resolve a later terminal property.
let resolvedProductName = executableProduct.name
let resolvedTargetName = applicationTarget.name
let resolvedPackageName = package.name
