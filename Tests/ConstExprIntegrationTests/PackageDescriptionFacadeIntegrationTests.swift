import ConstExpr
import Testing

// This intentionally mirrors only the declarative core of PackageDescription.
// The names are distinct so the test cannot accidentally resolve against the
// real manifest API imported by SwiftPM while compiling this package.

@ConstExpr
private struct SwiftPMFixtureVersion: ExpressibleByStringLiteral {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }
}

@ConstExpr
private struct SwiftPMFixtureSupportedPlatform {
    @ConstExpr
    enum MacOSVersion {
        case v13
        case v14

        var text: String {
            switch self {
            case .v13: "13.0"
            case .v14: "14.0"
            }
        }
    }

    let summary: String

    static func macOS(_ version: MacOSVersion) -> SwiftPMFixtureSupportedPlatform {
        SwiftPMFixtureSupportedPlatform(summary: "macos:\(version.text)")
    }
}

@ConstExpr
private struct SwiftPMFixtureProduct {
    @ConstExpr
    enum LibraryType {
        case automatic
        case dynamic

        var text: String {
            switch self {
            case .automatic: "automatic"
            case .dynamic: "dynamic"
            }
        }
    }

    let summary: String

    static func library(
        name: String,
        type: LibraryType? = nil,
        targets: [String]
    ) -> SwiftPMFixtureProduct {
        let typeName = type?.text ?? LibraryType.automatic.text
        return SwiftPMFixtureProduct(
            summary: "library:\(name):\(typeName):[\(targets.joined(separator: ","))]"
        )
    }

    static func executable(
        name: String,
        targets: [String]
    ) -> SwiftPMFixtureProduct {
        SwiftPMFixtureProduct(
            summary: "executable:\(name):[\(targets.joined(separator: ","))]"
        )
    }
}

@ConstExpr
private struct SwiftPMFixtureTarget {
    @ConstExpr
    enum Dependency: ExpressibleByStringLiteral {
        case byNameItem(String)
        case productItem(name: String, package: String)

        init(stringLiteral value: String) {
            self = .byNameItem(value)
        }

        static func product(name: String, package: String) -> Dependency {
            .productItem(name: name, package: package)
        }

        var summary: String {
            switch self {
            case .byNameItem(let name):
                "name:\(name)"
            case .productItem(let name, let package):
                "product:\(name)@\(package)"
            }
        }
    }

    let summary: String

    init(name: String, dependencies: [Dependency] = []) {
        self.init(role: "target", name: name, dependencies: dependencies)
    }

    init(role: String, name: String, dependencies: [Dependency]) {
        let dependencySummary = dependencies.map(\.summary).joined(separator: ",")
        summary = "\(role):\(name):[\(dependencySummary)]"
    }

    static func target(
        name: String,
        dependencies: [Dependency] = []
    ) -> SwiftPMFixtureTarget {
        SwiftPMFixtureTarget(role: "target", name: name, dependencies: dependencies)
    }

    static func testTarget(
        name: String,
        dependencies: [Dependency] = []
    ) -> SwiftPMFixtureTarget {
        SwiftPMFixtureTarget(role: "test", name: name, dependencies: dependencies)
    }
}

@ConstExpr
private struct SwiftPMFixtureTrait: Hashable, ExpressibleByStringLiteral {
    let name: String
    let enabledTraits: Set<String>

    init(stringLiteral value: String) {
        name = value
        enabledTraits = []
    }

    static func `default`(enabledTraits: Set<String>) -> SwiftPMFixtureTrait {
        SwiftPMFixtureTrait(
            name: "default",
            enabledTraits: enabledTraits
        )
    }

    init(name: String, enabledTraits: Set<String>) {
        self.name = name
        self.enabledTraits = enabledTraits
    }

    var summary: String {
        guard !enabledTraits.isEmpty else { return name }
        return "\(name):[\(enabledTraits.sorted().joined(separator: ","))]"
    }
}

@ConstExpr
private struct SwiftPMFixturePackage {
    @ConstExpr
    struct Dependency {
        let summary: String

        static func package(path: String) -> Dependency {
            Dependency(summary: "path:\(path)")
        }

        static func package(
            url: String,
            from version: SwiftPMFixtureVersion
        ) -> Dependency {
            Dependency(summary: "url:\(url)@\(version.text)")
        }
    }

    let name: String
    let platforms: [SwiftPMFixtureSupportedPlatform]
    let products: [SwiftPMFixtureProduct]
    let traits: Set<SwiftPMFixtureTrait>
    let dependencies: [Dependency]
    let targets: [SwiftPMFixtureTarget]

    init(
        name: String,
        platforms: [SwiftPMFixtureSupportedPlatform] = [],
        products: [SwiftPMFixtureProduct] = [],
        traits: Set<SwiftPMFixtureTrait> = [],
        dependencies: [Dependency] = [],
        targets: [SwiftPMFixtureTarget] = []
    ) {
        self.name = name
        self.platforms = platforms
        self.products = products
        self.traits = traits
        self.dependencies = dependencies
        self.targets = targets
    }
}

@ConstExpr
private func swiftPMFixtureSummary(_ package: SwiftPMFixturePackage) -> String {
    let platforms = package.platforms.map(\.summary).joined(separator: ",")
    let products = package.products.map(\.summary).joined(separator: ",")
    let traits = package.traits.map(\.summary).sorted().joined(separator: ",")
    let dependencies = package.dependencies.map(\.summary).joined(separator: ",")
    let targets = package.targets.map(\.summary).joined(separator: ",")
    return "name=\(package.name);platforms=\(platforms);products=\(products);traits=\(traits);dependencies=\(dependencies);targets=\(targets)"
}

@ConstExpr
private struct SwiftPMFixtureAmbiguousInitializer {
    let value: Int

    init(_ value: Int8) {
        self.value = Int(value)
    }

    init(_ value: Int16) {
        self.value = Int(value)
    }
}

private extension SwiftPMFixtureTarget {
    static func extensionOnly(name: String) -> SwiftPMFixtureTarget {
        SwiftPMFixtureTarget(name: name)
    }
}

private let swiftPMFixtureRegistry = #constExprRegistry(
    SwiftPMFixtureVersion.self,
    SwiftPMFixtureSupportedPlatform.self,
    SwiftPMFixtureSupportedPlatform.MacOSVersion.self,
    SwiftPMFixtureProduct.self,
    SwiftPMFixtureProduct.LibraryType.self,
    SwiftPMFixtureTarget.self,
    SwiftPMFixtureTarget.Dependency.self,
    SwiftPMFixtureTrait.self,
    SwiftPMFixturePackage.self,
    SwiftPMFixturePackage.Dependency.self,
    SwiftPMFixtureAmbiguousInitializer.self,
    swiftPMFixtureSummary(_:)
)

@Test func packageDescriptionFacadeResolvesARepresentativeNestedManifest() {
    let source = """
        let sharedDependencies: [SwiftPMFixtureTarget.Dependency] = [
            "CoreSupport",
            .product(name: "Logging", package: "swift-log"),
        ]
        let core: SwiftPMFixtureTarget = .init(
            name: "Core",
            dependencies: sharedDependencies
        )
        let manifest: SwiftPMFixturePackage = .init(
            name: "Garden",
            platforms: [.macOS(.v14)],
            products: [
                .library(name: "Garden", type: .dynamic, targets: ["Core"]),
                .executable(name: "GardenTool", targets: ["GardenTool"]),
            ],
            traits: [
                .default(enabledTraits: ["Metrics"]),
                "Metrics",
            ],
            dependencies: [
                .package(path: "../Local"),
                .package(url: "https://example.com/swift-log.git", from: "1.5.0"),
            ],
            targets: [
                core,
                .testTarget(name: "GardenTests", dependencies: ["Core"]),
            ]
        )
        let __manifestSummary = swiftPMFixtureSummary(manifest)
        """

    let result = ConstExprRunner(registry: swiftPMFixtureRegistry).rewrite(source: source)

    #expect(result.source == """
        let sharedDependencies: [SwiftPMFixtureTarget.Dependency] = [
            "CoreSupport",
            .product(name: "Logging", package: "swift-log"),
        ]
        let core: SwiftPMFixtureTarget = .init(
            name: "Core",
            dependencies: sharedDependencies
        )
        let manifest: SwiftPMFixturePackage = .init(
            name: "Garden",
            platforms: [.macOS(.v14)],
            products: [
                .library(name: "Garden", type: .dynamic, targets: ["Core"]),
                .executable(name: "GardenTool", targets: ["GardenTool"]),
            ],
            traits: [
                .default(enabledTraits: ["Metrics"]),
                "Metrics",
            ],
            dependencies: [
                .package(path: "../Local"),
                .package(url: "https://example.com/swift-log.git", from: "1.5.0"),
            ],
            targets: [
                core,
                .testTarget(name: "GardenTests", dependencies: ["Core"]),
            ]
        )
        let __manifestSummary = "name=Garden;platforms=macos:14.0;products=library:Garden:dynamic:[Core],executable:GardenTool:[GardenTool];traits=Metrics,default:[Metrics];dependencies=path:../Local,url:https://example.com/swift-log.git@1.5.0;targets=target:Core:[name:CoreSupport,product:Logging@swift-log],test:GardenTests:[name:Core]"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func packageDescriptionFacadePreservesAmbiguousAndUnknownExpressions() {
    let source = """
        let ambiguous: SwiftPMFixtureAmbiguousInitializer = .init(1)
        let runtimePath = loadRuntimePath()
        let dependency: SwiftPMFixturePackage.Dependency = .package(path: runtimePath)
        let manifest: SwiftPMFixturePackage = .init(
            name: "Runtime",
            dependencies: [dependency]
        )
        let summary = swiftPMFixtureSummary(manifest)
        """

    let result = ConstExprRunner(registry: swiftPMFixtureRegistry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
}

@Test func packageDescriptionFacadeDocumentsTheExtensionOnlyBoundary() {
    #expect(!swiftPMFixtureRegistry.registrations.contains {
        $0.ownerType == SwiftPMFixtureTarget.self && $0.name == "extensionOnly"
    })

    let source = """
        let target: SwiftPMFixtureTarget = .extensionOnly(name: "ExtensionTarget")
        """
    let result = ConstExprRunner(registry: swiftPMFixtureRegistry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}
