import Testing
@testable import ConstExpr

private struct MetatypeLiteralSetting {
    let usesMainActor: Bool
}

private enum AlternateIsolation {}

private final class MetatypeLiteralCounter: @unchecked Sendable {
    var mainActor = 0
    var alternate = 0
}

private func metatypeLiteralRegistry(
    counter: MetatypeLiteralCounter,
    includeAmbiguousOverload: Bool = false
) -> ConstExprRegistry {
    var registrations = [
        ConstExprRegistration(
            name: "defaultIsolation",
            kind: .staticMethod,
            ownerType: MetatypeLiteralSetting.self,
            parameterLabels: [nil],
            parameterTypes: [Optional<MainActor.Type>.self],
            resultType: MetatypeLiteralSetting.self
        ) { _, arguments in
            counter.mainActor += 1
            let isolation = try arguments[0]!.require(MainActor.Type?.self)
            return ConstExprValue(MetatypeLiteralSetting(
                usesMainActor: isolation != nil
            ))
        },
    ]
    if includeAmbiguousOverload {
        registrations.append(ConstExprRegistration(
            name: "defaultIsolation",
            kind: .staticMethod,
            ownerType: MetatypeLiteralSetting.self,
            parameterLabels: [nil],
            parameterTypes: [Optional<AlternateIsolation.Type>.self],
            resultType: MetatypeLiteralSetting.self,
            declarationID: "alternate-default-isolation"
        ) { _, _ in
            counter.alternate += 1
            return ConstExprValue(MetatypeLiteralSetting(usesMainActor: false))
        })
    }
    return ConstExprRegistry(registrations: registrations)
}

@Test func exactRegisteredMetatypeLiteralEvaluates() {
    let counter = MetatypeLiteralCounter()
    let result = ConstExprRunner(
        registry: metatypeLiteralRegistry(counter: counter)
    ).evaluate(
        source: """
            let setting = MetatypeLiteralSetting.defaultIsolation(MainActor.self)
            """,
        binding: "setting",
        as: MetatypeLiteralSetting.self
    )

    switch result {
    case .success(let setting):
        #expect(setting.usesMainActor)
    case .fallback(let fallback):
        Issue.record("unexpected metatype fallback: \(fallback)")
    }
    #expect(counter.mainActor == 1)
}

@Test func ambiguousRegisteredMetatypeContextFallsBackWithoutInvocation() {
    let counter = MetatypeLiteralCounter()
    let result = ConstExprRunner(
        registry: metatypeLiteralRegistry(
            counter: counter,
            includeAmbiguousOverload: true
        )
    ).evaluateValue(
        source: """
            let setting = MetatypeLiteralSetting.defaultIsolation(MainActor.self)
            """,
        binding: "setting"
    )

    guard case .fallback = result else {
        Issue.record("ambiguous metatype unexpectedly evaluated")
        return
    }
    #expect(counter.mainActor == 0)
    #expect(counter.alternate == 0)
}

@Test func unknownOrShadowedMetatypeLiteralFallsBackWithoutInvocation() {
    for source in [
        "let setting = MetatypeLiteralSetting.defaultIsolation(ImportedActor.self)",
        """
        let MainActor = importedActor
        let setting = MetatypeLiteralSetting.defaultIsolation(MainActor.self)
        """,
    ] {
        let counter = MetatypeLiteralCounter()
        let result = ConstExprRunner(
            registry: metatypeLiteralRegistry(counter: counter)
        ).evaluateValue(source: source, binding: "setting")

        guard case .fallback = result else {
            Issue.record("unknown or shadowed metatype unexpectedly evaluated")
            continue
        }
        #expect(counter.mainActor == 0)
    }
}
