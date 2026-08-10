import Testing
@testable import ConstExpr

private struct OptionalResolutionContainer {
    let value: Int
}

private struct ModuleResolutionBox {
    let value: Int
}

private struct ContextualArgumentReceiver {}

private struct OptionalInjectionItem {
    let value: Int
}

private func resolutionRegistry() -> ConstExprRegistry {
    ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "describe",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue("int:\(try arguments[0]!.require(Int.self))")
        },
        ConstExprRegistration(
            name: "describe",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [String.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue("string:\(try arguments[0]!.require(String.self))")
        },
        ConstExprRegistration(
            name: "greet",
            kind: .function,
            parameterLabels: ["prefix", "name"],
            parameterTypes: [String.self, String.self],
            defaultedParameters: [0],
            resultType: String.self
        ) { _, arguments in
            let prefix = try arguments[0]?.require(String.self) ?? "Hello"
            let name = try arguments[1]!.require(String.self)
            return ConstExprValue("\(prefix), \(name)!")
        },
        .infixOperator("**", left: Int.self, right: Int.self, result: Int.self) { base, exponent in
            guard exponent >= 0 else { return 0 }
            return (0..<exponent).reduce(1) { answer, _ in answer * base }
        },
    ])
}

@Test func evaluatorResolvesOverloadsByExactTypesAndLabels() {
    let result = ConstExprRunner(registry: resolutionRegistry()).rewrite(source: """
        let first = describe(4)
        let second = describe("x")
        let greeting = greet(name: "Ada")
        """)

    #expect(result.source == """
        let first = "int:4"
        let second = "string:x"
        let greeting = "Hello, Ada!"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesMemberAndStaticParameterTypesAsArgumentContext() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "ContextualArgumentReceiver",
            kind: .initializer,
            ownerType: ContextualArgumentReceiver.self,
            resultType: ContextualArgumentReceiver.self
        ) { _, _ in ConstExprValue(ContextualArgumentReceiver()) },
        ConstExprRegistration(
            name: "acceptStatic",
            kind: .staticMethod,
            ownerType: ContextualArgumentReceiver.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: UInt8.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(UInt8.self))
        },
        ConstExprRegistration(
            name: "acceptInstance",
            kind: .instanceMethod,
            ownerType: ContextualArgumentReceiver.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: UInt8.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(UInt8.self))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let staticValue = ContextualArgumentReceiver.acceptStatic(255 &+ 1)
        let instanceValue = ContextualArgumentReceiver().acceptInstance(255 &+ 1)
        """)

    #expect(result.source == """
        let staticValue = (0) as Swift.UInt8
        let instanceValue = (0) as Swift.UInt8
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorDecodesTwoThreeAndFourElementTupleArguments() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "tuple2",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(Int, String).self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require((Int, String).self)
            return ConstExprValue("\(value.0):\(value.1)")
        },
        ConstExprRegistration(
            name: "tuple3",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(Int, String, Bool).self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require((Int, String, Bool).self)
            return ConstExprValue("\(value.0):\(value.1):\(value.2)")
        },
        ConstExprRegistration(
            name: "tuple4",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(Int, String, Bool, Double).self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require((Int, String, Bool, Double).self)
            return ConstExprValue("\(value.0):\(value.1):\(value.2):\(value.3)")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let two = tuple2((1, "one"))
        let three = tuple3((first: 2, second: "two", third: true))
        let four = tuple4((3, "three", false, 4.5))
        """)

    #expect(result.source == """
        let two = "1:one"
        let three = "2:two:true"
        let four = "3:three:false:4.5"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorRanksStructuralArrayLiteralConversionsElementByElement() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "arrayKind",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int].self],
            resultType: String.self
        ) { _, _ in ConstExprValue("Int") },
        ConstExprRegistration(
            name: "arrayKind",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int64].self],
            resultType: String.self
        ) { _, _ in ConstExprValue("Int64") },
        ConstExprRegistration(
            name: "arrayKind",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Double].self],
            resultType: String.self
        ) { _, _ in ConstExprValue("Double") },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let kind = arrayKind([1])"
    )

    #expect(result.source == "let kind = \"Int\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorInvokesManuallyRegisteredOperators() {
    let result = ConstExprRunner(registry: resolutionRegistry()).rewrite(source: """
        infix operator **: MultiplicationPrecedence
        let result = 2 ** 4 + 1
        """)

    #expect(result.source == """
        infix operator **: MultiplicationPrecedence
        let result = 17
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorInvokesManuallyRegisteredPostfixOperators() {
    let registry = ConstExprRegistry(
        .postfixOperator("^^", operand: Int.self, result: Int.self) { $0 * $0 }
    )
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        postfix operator ^^
        let value = 5^^
        """)

    #expect(result.source == """
        postfix operator ^^
        let value = 25
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorLiftsOptionalPropertyAndSubscriptResultsWithoutNesting() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeOptionalContainer",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Bool.self],
            resultType: OptionalResolutionContainer?.self
        ) { _, arguments in
            let present = try arguments[0]!.require(Bool.self)
            return ConstExprValue(
                present ? OptionalResolutionContainer(value: 7) : nil
            )
        },
        ConstExprRegistration(
            name: "value",
            kind: .instanceProperty,
            ownerType: OptionalResolutionContainer.self,
            resultType: Int.self
        ) { receiver, _ in
            ConstExprValue(try receiver!.require(OptionalResolutionContainer.self).value)
        },
        ConstExprRegistration(
            name: "optionalValue",
            kind: .instanceProperty,
            ownerType: OptionalResolutionContainer.self,
            resultType: Int?.self
        ) { receiver, _ in
            let value = try receiver!.require(OptionalResolutionContainer.self).value
            return ConstExprValue(Optional(value))
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { receiver, arguments in
            let value = try receiver!.require(OptionalResolutionContainer.self).value
            return ConstExprValue(value + (try arguments[0]!.require(Int.self)))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let property = makeOptionalContainer(true)?.value
        let absentProperty = makeOptionalContainer(false)?.value
        let alreadyOptional = makeOptionalContainer(true)?.optionalValue
        let subscriptValue = makeOptionalContainer(true)?[2]
        let absentSubscript = makeOptionalContainer(false)?[2]
        """)

    #expect(result.source == """
        let property = (7) as Int?
        let absentProperty = nil as Int?
        let alreadyOptional = (7) as Int?
        let subscriptValue = (9) as Int?
        let absentSubscript = nil as Int?
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorSkipsArgumentsOfStaticallyNilOptionalChains() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeNilContainer",
            kind: .function,
            resultType: OptionalResolutionContainer?.self
        ) { _, _ in ConstExprValue(Optional<OptionalResolutionContainer>.none) },
        ConstExprRegistration(
            name: "consume",
            kind: .instanceMethod,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let method = makeNilContainer()?.consume(1 / 0)
        let item = makeNilContainer()?[1 / 0]
        """)

    #expect(counter.value == 0)
    #expect(result.source == """
        let method = nil as Int?
        let item = nil as Int?
        """)
    #expect(!result.diagnostics.contains { $0.code == "division-by-zero" })
}

@Test func evaluatorSkipsRegisteredArgumentsOfUnknownOptionalChains() {
    final class Counts: @unchecked Sendable {
        var argument = 0
        var member = 0
    }
    let counts = Counts()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "sideEffect",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            counts.argument += 1
            return ConstExprValue(1)
        },
        ConstExprRegistration(
            name: "consume",
            kind: .instanceMethod,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counts.member += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counts.member += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
    ])
    let source = """
        let method = unknownOptional?.consume(sideEffect())
        let item = unknownOptional?[sideEffect()]
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counts.argument == 0)
    #expect(counts.member == 0)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesRegisteredOptionalSubscriptArgumentAndResultContexts() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeOptionalContainer",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Bool.self],
            resultType: OptionalResolutionContainer?.self
        ) { _, arguments in
            let present = try arguments[0]!.require(Bool.self)
            return ConstExprValue(
                present ? OptionalResolutionContainer(value: 7) : nil
            )
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: OptionalResolutionContainer.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: Int.self
        ) { receiver, arguments in
            let base = try receiver!.require(OptionalResolutionContainer.self).value
            return ConstExprValue(base + Int(try arguments[0]!.require(UInt8.self)))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let present: Int? = makeOptionalContainer(true)?[255 &+ 1]
        let absent: Int? = makeOptionalContainer(false)?[255 &+ 1]
        """)

    #expect(result.source == """
        let present: Int? = (7) as Int?
        let absent: Int? = nil as Int?
        """)
    #expect(result.diagnostics.isEmpty)
}

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
