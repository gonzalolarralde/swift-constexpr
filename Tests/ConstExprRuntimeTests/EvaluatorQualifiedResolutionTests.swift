import Testing
@testable import ConstExpr

@Test func evaluatorResolvesModuleQualifiedFunctionsConstantsAndInitializers() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            moduleName: "DemoConstants",
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        },
        ConstExprRegistration(
            moduleName: "DemoConstants",
            name: "answer",
            kind: .constant,
            resultType: Int.self
        ) { _, _ in ConstExprValue(42) },
        ConstExprRegistration(
            moduleName: "DemoConstants",
            name: "ModuleResolutionBox",
            kind: .initializer,
            ownerType: ModuleResolutionBox.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: ModuleResolutionBox.self
        ) { _, arguments in
            ConstExprValue(ModuleResolutionBox(value: try arguments[0]!.require(Int.self)))
        },
        ConstExprRegistration(
            moduleName: "DemoConstants",
            name: "value",
            kind: .instanceProperty,
            ownerType: ModuleResolutionBox.self,
            resultType: Int.self
        ) { receiver, _ in
            ConstExprValue(try receiver!.require(ModuleResolutionBox.self).value)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let function = DemoConstants.increment(1)
        let constant = DemoConstants.answer
        let initializer = DemoConstants.ModuleResolutionBox(3).value
        let unrelated = OtherConstants.answer
        """)

    #expect(result.source == """
        let function = 2
        let constant = 42
        let initializer = 3
        let unrelated = OtherConstants.answer
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorDoesNotResolveQualifiedRegistrationsThroughLexicalShadows() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "acceptStatic",
            kind: .staticMethod,
            ownerType: ContextualArgumentReceiver.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: UInt8.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(UInt8.self))
        },
        ConstExprRegistration(
            moduleName: "DemoConstants",
            name: "answer",
            kind: .constant,
            resultType: Int.self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(42)
        },
    ])
    let source = """
        func localTypeWins() {
            struct ContextualArgumentReceiver {
                static func acceptStatic(_ value: UInt8) -> UInt8 { value }
            }
            let value = ContextualArgumentReceiver.acceptStatic(1)
        }
        func localValueWins() {
            let DemoConstants = external()
            let value = DemoConstants.answer
        }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(counter.value == 0)
    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorResolvesStaticRegistrationsWithATextualOwner() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "answer",
            kind: .staticProperty,
            ownerName: "TextualOwner",
            resultType: Int.self
        ) { _, _ in ConstExprValue(21) },
        ConstExprRegistration(
            name: "twice",
            kind: .staticMethod,
            ownerName: "TextualOwner",
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) * 2)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let property = TextualOwner.answer
        let method = TextualOwner.twice(4)
        """)

    #expect(result.source == """
        let property = 21
        let method = 8
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorTracksNestedScopesAndClosureParameters() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    ])
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let outer = 4
        func nested() {
            let inner = increment(outer)
            consume(inner)
        }
        let closure = { outer in increment(outer) }
        """)

    #expect(result.source == """
        let outer = 4
        func nested() {
            let inner = 5
            consume(5)
        }
        let closure = { outer in increment(outer) }
        """)
}

@Test func evaluatorReportsAmbiguousOverloadsWithoutExecutingThem() {
    let first = ConstExprRegistration(
        name: "ambiguous",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self,
        declarationID: "first"
    ) { _, _ in ConstExprValue(1) }
    let second = ConstExprRegistration(
        name: "ambiguous",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self,
        declarationID: "second"
    ) { _, _ in ConstExprValue(2) }

    let result = ConstExprRunner(registry: .init(registrations: [first, second]))
        .rewrite(source: "let result = ambiguous(1)")

    #expect(result.source == "let result = ambiguous(1)")
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
}

@Test func evaluatorUsesParetoDominanceForCrossRankedArguments() {
    let leftExact = ConstExprRegistration(
        name: "crossRanked",
        kind: .function,
        parameterLabels: [nil, nil],
        parameterTypes: [Int.self, Int64.self],
        resultType: String.self,
        declarationID: "cross-left"
    ) { _, _ in ConstExprValue("left") }
    let rightExact = ConstExprRegistration(
        name: "crossRanked",
        kind: .function,
        parameterLabels: [nil, nil],
        parameterTypes: [Int64.self, Int.self],
        resultType: String.self,
        declarationID: "cross-right"
    ) { _, _ in ConstExprValue("right") }

    let result = ConstExprRunner(registry: .init(registrations: [leftExact, rightExact]))
        .rewrite(source: "let value = crossRanked(1, 1)")

    #expect(result.source == "let value = crossRanked(1, 1)")
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
}

@Test func evaluatorSupportsOptionalInjectionWithoutOutrankingAnExactOverload() {
    let exact = ConstExprRegistration(
        name: "optionalOverload",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: String.self,
        declarationID: "optional-overload-exact"
    ) { _, _ in ConstExprValue("exact") }
    let optional = ConstExprRegistration(
        name: "optionalOverload",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int?.self],
        resultType: String.self,
        declarationID: "optional-overload-optional"
    ) { _, arguments in
        let value = try arguments[0]!.require(Int?.self)
        return ConstExprValue(value.map(String.init) ?? "nil")
    }
    let optionalOnly = ConstExprRegistration(
        name: "optionalOnly",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int?.self],
        resultType: String.self
    ) { _, arguments in
        let value = try arguments[0]!.require(Int?.self)
        return ConstExprValue(value.map(String.init) ?? "nil")
    }

    let result = ConstExprRunner(
        registry: .init(registrations: [exact, optional, optionalOnly])
    ).rewrite(source: """
        let exact = optionalOverload(1)
        let computed = 1 + 1
        let injectedLiteral = optionalOnly(1)
        let injectedComputed = optionalOnly(computed)
        """)

    #expect(result.source == """
        let exact = "exact"
        let computed = 2
        let injectedLiteral = "1"
        let injectedComputed = "2"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorAllowsRecursiveOptionalInjectionForNestedCallResults() {
    final class Counts: @unchecked Sendable {
        var exactResult = 0
        var injectedResult = 0
    }
    let counts = Counts()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeOptionalInjectionItem",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: OptionalInjectionItem.self
        ) { _, arguments in
            ConstExprValue(
                OptionalInjectionItem(value: try arguments[0]!.require(Int.self))
            )
        },
        ConstExprRegistration(
            name: "describeOptionalInjectionItem",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [OptionalInjectionItem?.self],
            resultType: String.self
        ) { _, arguments in
            let item = try arguments[0]!.require(OptionalInjectionItem?.self)
            return ConstExprValue(item.map { "optional:\($0.value)" } ?? "none")
        },
        ConstExprRegistration(
            name: "describeNestedOptionalInjectionItem",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [OptionalInjectionItem??.self],
            resultType: String.self
        ) { _, arguments in
            let item = try arguments[0]!.require(OptionalInjectionItem??.self)
            return ConstExprValue(item??.value.description ?? "none")
        },
        ConstExprRegistration(
            name: "makeResultChoice",
            kind: .function,
            resultType: OptionalInjectionItem.self,
            declarationID: "optional-result-injected"
        ) { _, _ in
            counts.injectedResult += 1
            return ConstExprValue(OptionalInjectionItem(value: 1))
        },
        ConstExprRegistration(
            name: "makeResultChoice",
            kind: .function,
            resultType: OptionalInjectionItem?.self,
            declarationID: "optional-result-exact"
        ) { _, _ in
            counts.exactResult += 1
            return ConstExprValue(Optional(OptionalInjectionItem(value: 2)))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let once = describeOptionalInjectionItem(makeOptionalInjectionItem(4))
        let twice = describeNestedOptionalInjectionItem(makeOptionalInjectionItem(5))
        let exact = describeOptionalInjectionItem(makeResultChoice())
        """)

    #expect(result.source == """
        let once = "optional:4"
        let twice = "5"
        let exact = "optional:2"
        """)
    #expect(counts.injectedResult == 0)
    #expect(counts.exactResult == 1)
    #expect(result.diagnostics.isEmpty)
}
