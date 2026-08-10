import Testing
@testable import ConstExpr

private struct ContextualOperatorVersion: Comparable, ExpressibleByStringLiteral, Sendable {
    let value: String

    init(stringLiteral value: String) {
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

private struct AmbiguousContextualOperatorVersion: Comparable, ExpressibleByStringLiteral {
    let value: String

    init(stringLiteral value: String) {
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

private struct ContextualDependency {
    let url: String
    let versions: Range<ContextualOperatorVersion>
}

private struct ContextualPackage {
    let dependencies: [ContextualDependency]
}

private final class ContextualOperatorCounter: @unchecked Sendable {
    var literal = 0
    var range = 0
    var ambiguousLiteral = 0
    var ambiguousRange = 0
    var staticRange = 0
    var dependency = 0
    var closedDependency = 0
    var package = 0
}

private func contextualOperatorRegistry(
    counter: ContextualOperatorCounter,
    includeAmbiguousOverload: Bool = false
) -> ConstExprRegistry {
    var registrations = [
        ConstExprRegistration(
            name: "ContextualOperatorVersion",
            kind: .initializer,
            ownerType: ContextualOperatorVersion.self,
            parameterLabels: ["stringLiteral"],
            parameterTypes: [String.self],
            resultType: ContextualOperatorVersion.self
        ) { _, arguments in
            counter.literal += 1
            return ConstExprValue(ContextualOperatorVersion(
                stringLiteral: try arguments[0]!.require(String.self)
            ))
        },
        ConstExprRegistration.infixOperator(
            "..<",
            left: ContextualOperatorVersion.self,
            right: ContextualOperatorVersion.self,
            result: Range<ContextualOperatorVersion>.self,
            precedenceGroup: "RangeFormationPrecedence",
            associativity: ConstExprOperatorAssociativity.none
        ) { lower, upper in
            counter.range += 1
            return lower..<upper
        },
        ConstExprRegistration(
            name: "upToNextMajor",
            kind: .staticMethod,
            ownerType: Range<ContextualOperatorVersion>.self,
            parameterLabels: ["from"],
            parameterTypes: [ContextualOperatorVersion.self],
            resultType: Range<ContextualOperatorVersion>.self
        ) { _, arguments in
            counter.staticRange += 1
            let lower = try arguments[0]!.require(ContextualOperatorVersion.self)
            let upper = ContextualOperatorVersion(
                stringLiteral: lower.value + ".next"
            )
            return ConstExprValue(lower..<upper)
        },
        ConstExprRegistration(
            name: "package",
            kind: .staticMethod,
            ownerType: ContextualDependency.self,
            parameterLabels: ["url", nil],
            parameterTypes: [
                String.self,
                Range<ContextualOperatorVersion>.self,
            ],
            resultType: ContextualDependency.self
        ) { _, arguments in
            counter.dependency += 1
            return ConstExprValue(ContextualDependency(
                url: try arguments[0]!.require(String.self),
                versions: try arguments[1]!.require(
                    Range<ContextualOperatorVersion>.self
                )
            ))
        },
        ConstExprRegistration(
            name: "package",
            kind: .staticMethod,
            ownerType: ContextualDependency.self,
            parameterLabels: ["url", nil],
            parameterTypes: [
                String.self,
                ClosedRange<ContextualOperatorVersion>.self,
            ],
            resultType: ContextualDependency.self
        ) { _, arguments in
            counter.closedDependency += 1
            let versions = try arguments[1]!.require(
                ClosedRange<ContextualOperatorVersion>.self
            )
            return ConstExprValue(ContextualDependency(
                url: try arguments[0]!.require(String.self),
                versions: versions.lowerBound..<versions.upperBound
            ))
        },
        ConstExprRegistration(
            name: "ContextualPackage",
            kind: .initializer,
            ownerType: ContextualPackage.self,
            parameterLabels: ["dependencies"],
            parameterTypes: [[ContextualDependency].self],
            resultType: ContextualPackage.self
        ) { _, arguments in
            counter.package += 1
            return ConstExprValue(ContextualPackage(
                dependencies: try arguments[0]!.require(
                    [ContextualDependency].self
                )
            ))
        },
    ]
    if includeAmbiguousOverload {
        registrations.append(contentsOf: [
            ConstExprRegistration(
                name: "AmbiguousContextualOperatorVersion",
                kind: .initializer,
                ownerType: AmbiguousContextualOperatorVersion.self,
                parameterLabels: ["stringLiteral"],
                parameterTypes: [String.self],
                resultType: AmbiguousContextualOperatorVersion.self
            ) { _, arguments in
                counter.ambiguousLiteral += 1
                return ConstExprValue(AmbiguousContextualOperatorVersion(
                    stringLiteral: try arguments[0]!.require(String.self)
                ))
            },
            ConstExprRegistration(
                name: "..<",
                kind: .infixOperator,
                parameterLabels: [nil, nil],
                parameterTypes: [
                    AmbiguousContextualOperatorVersion.self,
                    AmbiguousContextualOperatorVersion.self,
                ],
                resultType: Range<ContextualOperatorVersion>.self,
                precedenceGroup: "RangeFormationPrecedence",
                associativity: ConstExprOperatorAssociativity.none,
                declarationID: "ambiguous-contextual-range"
            ) { _, _ in
                counter.ambiguousRange += 1
                let lower = ContextualOperatorVersion(stringLiteral: "z")
                let upper = ContextualOperatorVersion(stringLiteral: "zz")
                return ConstExprValue(lower..<upper)
            },
        ])
    }
    return ConstExprRegistry(registrations: registrations)
}

@Test func contextualResultSelectsRegisteredOperatorLiteralOperandTypes() {
    let counter = ContextualOperatorCounter()
    let runner = ConstExprRunner(registry: contextualOperatorRegistry(counter: counter))

    let result = runner.evaluate(
        source: """
            let versions: Range<ContextualOperatorVersion> = "1.2.3"..<"2.0.0"
            """,
        binding: "versions",
        as: Range<ContextualOperatorVersion>.self
    )

    switch result {
    case .success(let versions):
        #expect(versions.lowerBound.value == "1.2.3")
        #expect(versions.upperBound.value == "2.0.0")
    case .fallback(let fallback):
        Issue.record("unexpected fallback: \(fallback)")
    }
    #expect(counter.literal == 2)
    #expect(counter.range == 1)
}

@Test func ambiguousContextualOperatorOperandTypesRemainCompilerWork() {
    let counter = ContextualOperatorCounter()
    let source = """
        let versions: Range<ContextualOperatorVersion> = "1.2.3"..<"2.0.0"
        """
    let result = ConstExprRunner(
        registry: contextualOperatorRegistry(
            counter: counter,
            includeAmbiguousOverload: true
        )
    ).evaluateValue(source: source, binding: "versions")

    guard case .fallback = result else {
        Issue.record("ambiguous operator unexpectedly evaluated")
        return
    }
    #expect(counter.literal == 0)
    #expect(counter.range == 0)
    #expect(counter.ambiguousLiteral == 0)
    #expect(counter.ambiguousRange == 0)
}

@Test func unknownContextualOperatorOperandRemainsCompilerWork() {
    let counter = ContextualOperatorCounter()
    let source = """
        let versions: Range<ContextualOperatorVersion> = "1.2.3"..<importedUpperBound
        """
    let result = ConstExprRunner(
        registry: contextualOperatorRegistry(counter: counter)
    ).evaluateValue(source: source, binding: "versions")

    guard case .fallback = result else {
        Issue.record("unknown operand unexpectedly evaluated")
        return
    }
    #expect(counter.range == 0)
}

@Test func nestedContextualStaticFactoryReceivesOuterCandidateParameterType() {
    let counter = ContextualOperatorCounter()
    let registry = contextualOperatorRegistry(counter: counter)
    #expect(registry.isValid)
    #expect(registry.candidates(named: "package", kind: .staticMethod).count == 2)
    #expect(registry.candidates(named: "upToNextMajor", kind: .staticMethod).count == 1)
    let resolver = ConstExprTypeResolver(index: registry.index)
    #expect(resolver.resolve(sourceName: "ContextualDependency")?.type != nil)
    #expect(
        resolver.resolve(
            sourceName: String(reflecting: Range<ContextualOperatorVersion>.self)
        )?.type != nil
    )
    let result = ConstExprRunner(
        registry: registry
    ).evaluate(
        source: """
            let dependency: ContextualDependency = .package(
                url: "https://example.invalid/repository.git",
                .upToNextMajor(from: "2.27.0")
            )
            """,
        binding: "dependency",
        as: ContextualDependency.self
    )

    switch result {
    case .success(let dependency):
        #expect(dependency.url.hasPrefix("https://"))
        #expect(dependency.versions.lowerBound.value == "2.27.0")
    case .fallback(let fallback):
        Issue.record("unexpected nested contextual fallback: \(fallback)")
    }
    #expect(counter.literal == 1)
    #expect(counter.staticRange == 1)
    #expect(counter.dependency == 1)
    #expect(counter.closedDependency == 0)
}

@Test func nestedRawRangeReceivesOuterCandidateParameterType() {
    let counter = ContextualOperatorCounter()
    let result = ConstExprRunner(
        registry: contextualOperatorRegistry(counter: counter)
    ).evaluate(
        source: """
            let dependency: ContextualDependency = .package(
                url: "https://example.invalid/repository.git",
                "509.0.0"..<"605.0.0"
            )
            """,
        binding: "dependency",
        as: ContextualDependency.self
    )

    switch result {
    case .success(let dependency):
        #expect(dependency.versions.lowerBound.value == "509.0.0")
        #expect(dependency.versions.upperBound.value == "605.0.0")
    case .fallback(let fallback):
        Issue.record("unexpected raw range fallback: \(fallback)")
    }
    #expect(counter.literal == 2)
    #expect(counter.range == 1)
    #expect(counter.dependency == 1)
    #expect(counter.closedDependency == 0)
}

@Test func ambiguousNestedRawRangeDoesNotInvokeDuringNarrowing() {
    let counter = ContextualOperatorCounter()
    let result = ConstExprRunner(
        registry: contextualOperatorRegistry(
            counter: counter,
            includeAmbiguousOverload: true
        )
    ).evaluateValue(
        source: """
            let dependency: ContextualDependency = .package(
                url: "https://example.invalid/repository.git",
                "509.0.0"..<"605.0.0"
            )
            """,
        binding: "dependency"
    )

    guard case .fallback = result else {
        Issue.record("ambiguous nested operator unexpectedly evaluated")
        return
    }
    #expect(counter.literal == 0)
    #expect(counter.range == 0)
    #expect(counter.ambiguousLiteral == 0)
    #expect(counter.ambiguousRange == 0)
    #expect(counter.dependency == 0)
    #expect(counter.closedDependency == 0)
}

@Test func nestedContextFlowsThroughArrayAndOverloadedOuterFactory() {
    let counter = ContextualOperatorCounter()
    let result = ConstExprRunner(
        registry: contextualOperatorRegistry(counter: counter)
    ).evaluate(
        source: """
            let package = ContextualPackage(dependencies: [
                .package(
                    url: "https://example.invalid/repository.git",
                    .upToNextMajor(from: "2.27.0")
                )
            ])
            """,
        binding: "package",
        as: ContextualPackage.self
    )

    switch result {
    case .success(let package):
        #expect(package.dependencies.count == 1)
        #expect(package.dependencies[0].versions.lowerBound.value == "2.27.0")
    case .fallback(let fallback):
        Issue.record("unexpected array contextual fallback: \(fallback)")
    }
    #expect(counter.literal == 1)
    #expect(counter.staticRange == 1)
    #expect(counter.dependency == 1)
    #expect(counter.closedDependency == 0)
    #expect(counter.package == 1)
}
