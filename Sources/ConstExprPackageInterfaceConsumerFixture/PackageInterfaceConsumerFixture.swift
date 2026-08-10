import ConstExpr
import ConstExprPackageInterfaceFixture

private let packageInterfaceRegistry = #constExprRegistry(
    PackageInterfaceFixture.init(value:),
    PackageInterfaceNamespace.NestedVersion.self
)

public func packageInterfaceRegistrationCount() -> Int {
    packageInterfaceRegistry.registrations.count
}

public func packageInterfaceNestedNominalRewrite() -> String {
    ConstExprRunner(
        registry: packageInterfaceRegistry,
        options: ConstExprRewriteOptions(availabilityContext: .init(versions: [
            "macOS": .init(major: 14),
        ]))
    ).rewrite(source: """
        let initialized = PackageInterfaceNamespace.NestedVersion(4).adding(2)
        let introduced = PackageInterfaceNamespace.NestedVersion.introduced.adding(1)
        let legacy = PackageInterfaceNamespace.NestedVersion.legacy.adding(2)
        """).source
}

public func packageInterfaceNestedAvailabilityPolicyIsApplied() -> Bool {
    let registrations = packageInterfaceRegistry.registrations.filter {
        $0.ownerType.map(ObjectIdentifier.init)
            == ObjectIdentifier(PackageInterfaceNamespace.NestedVersion.self)
    }
    let introduced = registrations.first { $0.name == "introduced" }?.availability
    return introduced?.contains {
        $0.domain == "macOS" && $0.introduced?.major == 11
    } == true
        && !registrations.contains { $0.name == "legacy" }
        && !registrations.contains { $0.name == "unavailableAlias" }
}
