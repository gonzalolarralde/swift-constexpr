import Testing
@testable import ConstExpr

private final class AvailabilityInvocationCounter: @unchecked Sendable {
    var value = 0
}

private func availabilityRegistry() -> ConstExprRegistry {
    ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "select",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: String.self,
            isDisfavoredOverload: true,
            declarationID: "legacy-select"
        ) { _, _ in ConstExprValue("legacy") },
        ConstExprRegistration(
            name: "select",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: String.self,
            availability: [ConstExprAvailability(
                domain: "_PackageDescription",
                introduced: .init(major: 6)
            )],
            declarationID: "modern-select"
        ) { _, _ in ConstExprValue("modern") },
    ])
}

@Test func unknownAvailabilityContextPreservesTheOverloadSet() {
    let runner = ConstExprRunner(registry: availabilityRegistry())
    let rewrite = runner.rewrite(source: "let value = select(1)")
    #expect(rewrite.source == "let value = select(1)")

    let terminal = runner.evaluateValue(
        source: "let value = select(1)",
        binding: "value"
    )
    guard case .fallback(let fallback) = terminal else {
        Issue.record("unknown availability unexpectedly evaluated")
        return
    }
    #expect(fallback.reason == .unresolvedBinding)
    #expect(fallback.message.contains("availability context"))
}

@Test func availabilityContextFiltersIntroducedOverloads() {
    let versionFive = ConstExprRunner(
        registry: availabilityRegistry(),
        options: ConstExprRewriteOptions(availabilityContext: .init(versions: [
            "_PackageDescription": .init(major: 5),
        ]))
    )
    let versionSix = ConstExprRunner(
        registry: availabilityRegistry(),
        options: ConstExprRewriteOptions(availabilityContext: .init(versions: [
            "_PackageDescription": .init(major: 6),
        ]))
    )

    #expect(versionFive.rewrite(source: "let value = select(1)").source == "let value = \"legacy\"")
    #expect(versionSix.rewrite(source: "let value = select(1)").source == "let value = \"modern\"")
}

@Test func availabilityHonorsObsoletedAndUnavailableRequirements() {
    let obsolete = ConstExprAvailability(
        domain: "_PackageDescription",
        introduced: .init(major: 5),
        obsoleted: .init(major: 6)
    )
    #expect(
        ConstExprRegistration(
            name: "old",
            kind: .constant,
            availability: [obsolete]
        ) { _, _ in ConstExprValue(0) }.availabilityState(
            in: .init(versions: ["_PackageDescription": .init(major: 5)])
        ) == .available
    )
    #expect(
        ConstExprRegistration(
            name: "old",
            kind: .constant,
            availability: [obsolete]
        ) { _, _ in ConstExprValue(0) }.availabilityState(
            in: .init(versions: ["_PackageDescription": .init(major: 6)])
        ) == .unavailable
    )
    #expect(
        ConstExprRegistration(
            name: "never",
            kind: .constant,
            availability: [.init(domain: "*", isUnavailable: true)]
        ) { _, _ in ConstExprValue(0) }.availabilityState(in: nil) == .unavailable
    )
}

@Test func availabilityDeclinesDeprecatedRegistrationsToPreserveCompilerWarnings() {
    let versioned = ConstExprAvailability(
        domain: "_PackageDescription",
        deprecated: .init(major: 6, minor: 1)
    )
    let registration = ConstExprRegistration(
        name: "legacy",
        kind: .constant,
        availability: [versioned]
    ) { _, _ in ConstExprValue(0) }
    #expect(registration.availabilityState(
        in: .init(versions: ["_PackageDescription": .init(major: 6)])
    ) == .available)
    #expect(registration.availabilityState(
        in: .init(versions: ["_PackageDescription": .init(major: 6, minor: 1)])
    ) == .unavailable)

    let alwaysDeprecated = ConstExprRegistration(
        name: "legacy",
        kind: .constant,
        availability: [.init(domain: "*", isDeprecated: true)]
    ) { _, _ in ConstExprValue(0) }
    #expect(alwaysDeprecated.availabilityState(in: nil) == .unavailable)

    let counter = AvailabilityInvocationCounter()
    let runner = ConstExprRunner(
        registry: ConstExprRegistry(registrations: [
            ConstExprRegistration(
                name: "legacy",
                kind: .function,
                resultType: Int.self,
                availability: [versioned]
            ) { _, _ in
                counter.value += 1
                return ConstExprValue(1)
            },
        ]),
        options: .init(availabilityContext: .init(versions: [
            "_PackageDescription": .init(major: 6, minor: 1),
        ]))
    )
    #expect(runner.rewrite(source: "let value = legacy()").source == "let value = legacy()")
    #expect(counter.value == 0)
}
