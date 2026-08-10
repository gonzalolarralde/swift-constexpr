import Testing
@testable import ConstExpr

@ConstExpr
private enum AvailableEnumCase {
    @available(macOS 11, *)
    case current

    @available(macOS, introduced: 11, obsoleted: 99)
    case obsoleteSurface
}

private let availableEnumCaseRegistry = #constExprRegistry(
    AvailableEnumCase.self
)

@ConstExpr
private struct ObsoletedPropertySurface {
    @available(macOS, introduced: 11, obsoleted: 99)
    static var obsolete: Self { Self() }
}

private let obsoletedPropertyRegistry = #constExprRegistry(
    ObsoletedPropertySurface.self
)

@Test func introducedEnumCaseCarriesMetadataWhileObsoletedCaseIsOmitted() {
    let current = availableEnumCaseRegistry.candidates(
        named: "current",
        kind: .staticProperty
    )
    #expect(current.count == 1)
    #expect(current[0].availability.contains {
        $0.domain == "macOS" && $0.introduced?.major == 11
    })
    #expect(
        availableEnumCaseRegistry.candidates(
            named: "obsoleteSurface",
            kind: .staticProperty
        ).isEmpty
    )

    let result = ConstExprRunner(
        registry: availableEnumCaseRegistry,
        options: .init(availabilityContext: .init(versions: [
            "macOS": .init(major: 14),
        ]))
    ).evaluate(
        source: "let value: AvailableEnumCase = AvailableEnumCase.current",
        binding: "value",
        as: AvailableEnumCase.self
    )
    guard case .success(let value) = result else {
        Issue.record("introduced enum case unexpectedly fell back")
        return
    }
    #expect(value == .current)
}

@Test func obsoletedWholeNominalPropertyIsOmittedFromTheHostProvider() {
    #expect(
        obsoletedPropertyRegistry.candidates(
            named: "obsolete",
            kind: .staticProperty
        ).isEmpty
    )
}
