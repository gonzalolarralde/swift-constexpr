import SwiftSyntax
import SwiftSyntaxBuilder
import Testing
@testable import ConstExpr

private class ManualTupleBase {}
private final class ManualTupleDerived: ManualTupleBase {}

private final class RuntimeBoundaryCounter: @unchecked Sendable {
    var derivedOverload = 0
    var integerOverload = 0
    var operatorInvocations = 0
    var throwingOperatorInvocations = 0
}

private struct MultiStatementRenderedValue: ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: "1\nlet injected = 2")
    }
}

private func requireSendable<T: Sendable>(_: T) {}

@Test func runtimeConfigurationTypesAreCheckedSendableValues() {
    let invocation: ConstExprRegistration.Invocation = { _, _ in
        ConstExprValue(1)
    }
    let registration = ConstExprRegistration(
        name: "sendableValue",
        kind: .function,
        resultType: Int.self
    ) { try invocation($0, $1) }

    requireSendable(invocation)
    requireSendable(registration)
    requireSendable(ConstExprRegistry(registration))
    requireSendable(ConstExprStaticTypeDescriptor.inferred(Int.self))
    requireSendable(ConstExprRunner(registry: ConstExprRegistry(registration)))
}

@Test func inferredManualTupleResultsNeverNarrowTheirDeclaredElementTypes() {
    let counter = RuntimeBoundaryCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeManualTuple",
            kind: .function,
            resultType: (ManualTupleBase, Any).self
        ) { _, _ in
            let result: (ManualTupleBase, Any) = (ManualTupleDerived(), 7)
            return ConstExprValue(result)
        },
        ConstExprRegistration(
            name: "manualTupleBaseChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ManualTupleBase.self],
            resultType: String.self,
            declarationID: "manual-tuple-base"
        ) { _, _ in ConstExprValue("base") },
        ConstExprRegistration(
            name: "manualTupleBaseChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ManualTupleDerived.self],
            resultType: String.self,
            declarationID: "manual-tuple-derived"
        ) { _, _ in
            counter.derivedOverload += 1
            return ConstExprValue("derived")
        },
        ConstExprRegistration(
            name: "manualTupleAnyChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self,
            declarationID: "manual-tuple-any"
        ) { _, _ in ConstExprValue("any") },
        ConstExprRegistration(
            name: "manualTupleAnyChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: String.self,
            declarationID: "manual-tuple-int"
        ) { _, _ in
            counter.integerOverload += 1
            return ConstExprValue("int")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let base = manualTupleBaseChoice(makeManualTuple().0)
        let erased = manualTupleAnyChoice(makeManualTuple().1)
        """)

    #expect(!result.source.contains("= \"derived\""))
    #expect(!result.source.contains("= \"int\""))
    #expect(counter.derivedOverload == 0)
    #expect(counter.integerOverload == 0)
}

@Test func aCustomRendererMustProduceExactlyOneExpression() {
    let value = ConstExprValue(MultiStatementRenderedValue())
    #expect(throws: ConstExprValueError.self) {
        try value.renderSource()
    }

    let registration = ConstExprRegistration(
        name: "multiStatementRenderedValue",
        kind: .function,
        resultType: MultiStatementRenderedValue.self
    ) { _, _ in ConstExprValue(MultiStatementRenderedValue()) }
    let source = "let value = multiStatementRenderedValue()"
    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: source
    )

    #expect(result.source == source)
}

@Test func preservingStaticTypeNeverEmitsAnIncompatibleRuntimePayload() throws {
    let dishonest = ConstExprValue(
        "x" as Any,
        preservingStaticType: Int.self
    )
    let dishonestSource = try dishonest.renderSource()
    #expect(!dishonestSource.contains("as Swift.Int"))
    #expect(ObjectIdentifier(dishonest.staticType) == ObjectIdentifier(String.self))

    let concreteValueClaim = ConstExprValue(
        1 as Any,
        preservingStaticType: Int.self,
        isStaticallyAnyObject: true
    )
    let erasedValueClaim = ConstExprValue(
        1 as Any,
        preservingStaticType: Any.self,
        isStaticallyAnyObject: true
    )
    let knownClassClaim = ConstExprValue(
        ManualTupleDerived() as Any,
        preservingStaticType: ManualTupleBase.self,
        isStaticallyAnyObject: false
    )
    #expect(!concreteValueClaim.isStaticallyAnyObject)
    #expect(!erasedValueClaim.isStaticallyAnyObject)
    #expect(knownClassClaim.isStaticallyAnyObject)

    let registration = ConstExprRegistration(
        name: "dishonestStaticResult",
        kind: .function,
        resultType: Int.self
    ) { _, _ in
        ConstExprValue("x" as Any, preservingStaticType: Int.self)
    }
    let source = "let value = dishonestStaticResult()"
    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: source
    )

    #expect(result.source == source)
    #expect(!result.source.contains("as Swift.Int"))
    #expect(result.diagnostics.map(\.code) == ["evaluation-threw"])
}

@Test func structuralValuesErasedToAnyPreserveTheirBoxedRuntimeValue() throws {
    func eraseToAny(_ value: ConstExprValue) throws -> ConstExprValue {
        try value.staticallyConverted(
            to: Any.self,
            descriptor: .inferred(Any.self, sourceName: "Any"),
            sourceTypeName: "Any"
        )
    }
    func dynamicTypeName(of value: Any) -> String {
        String(reflecting: Swift.type(of: value))
    }

    let none = try eraseToAny(.optional(nil, wrappedBy: Int.self))
    let some = try eraseToAny(.optional(5, wrappedBy: Int.self))
    let recursivelyInjected = try ConstExprValue.integerLiteral(5).staticallyConverted(
        to: Int??.self,
        descriptor: .optional(.optional(.inferred(Int.self, sourceName: "Int"))),
        sourceTypeName: "Int??"
    )
    let innerOptional = try #require(recursivelyInjected.wrappedValue)
    #expect(
        ObjectIdentifier(innerOptional.staticType)
            == ObjectIdentifier(Int?.self)
    )
    let decodedOuter = try #require(try recursivelyInjected.require(Int??.self))
    let decodedInner = try #require(decodedOuter)
    #expect(decodedInner == 5)

    let structuralArray = try ConstExprValue.array(
        [.integerLiteral(1)],
        typeName: "[Any]"
    ).withStaticType(
        [Any].self,
        descriptor: .array(.inferred(Any.self, sourceName: "Any"))
    )
    let array = try eraseToAny(structuralArray)

    let structuralDictionary = try ConstExprValue.dictionary(
        [(.stringLiteral("one"), .integerLiteral(1))],
        typeName: "[String: Any]"
    ).withStaticType(
        [String: Any].self,
        descriptor: .dictionary(
            key: .inferred(String.self, sourceName: "String"),
            value: .inferred(Any.self, sourceName: "Any")
        )
    )
    let dictionary = try eraseToAny(structuralDictionary)

    let structuralTuple = try ConstExprValue.tuple(
        [(label: nil, value: .integerLiteral(1)),
         (label: nil, value: .stringLiteral("one"))],
        typeName: "(Swift.Int, Swift.String)"
    ).withStaticType(
        (Int, String).self,
        descriptor: .tuple([
            .inferred(Int.self, sourceName: "Swift.Int"),
            .inferred(String.self, sourceName: "Swift.String"),
        ])
    )
    let tuple = try eraseToAny(structuralTuple)

    let noneSource = try none.renderSource()
    let someSource = try some.renderSource()
    let arraySource = try array.renderSource()
    let dictionarySource = try dictionary.renderSource()
    let tupleSource = try tuple.renderSource()
    #expect(noneSource.contains("Optional<Swift.Int>"))
    #expect(someSource.contains("Optional<Swift.Int>"))
    #expect(arraySource.contains("[Any]"))
    #expect(dictionarySource.contains("[String: Any]"))
    #expect(tupleSource.contains("(Swift.Int, Swift.String)"))
    for source in [noneSource, someSource, arraySource, dictionarySource, tupleSource] {
        #expect(source.hasSuffix(" as Any"))
    }

    let boxedNone = try none.require(Any.self)
    let boxedSome = try some.require(Any.self)
    let boxedArray = try array.require(Any.self)
    let boxedDictionary = try dictionary.require(Any.self)
    #expect(dynamicTypeName(of: boxedNone) == "Swift.Optional<Swift.Int>")
    #expect(dynamicTypeName(of: boxedSome) == "Swift.Optional<Swift.Int>")
    #expect(dynamicTypeName(of: boxedArray) == "Swift.Array<Any>")
    #expect(dynamicTypeName(of: boxedDictionary) == "Swift.Dictionary<Swift.String, Any>")
}

@Test func optionalInjectionAndRecursiveAnyErasureRetainEveryBoxingLevel() {
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "runtimeBoundaryIncrement",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let source = """
        let some: Int? = runtimeBoundaryIncrement(1)
        let none: Int? = nil
        let optionals: [Int?] = [some, none]
        let erasedElements: [Any] = optionals
        let optionalDictionary: [String: Int?] = ["some": some, "none": none]
        let erasedValues: [String: Any] = optionalDictionary
        let nestedOptional: Int?? = some
        let erasedNested: Any = nestedOptional
        let injectedAny: Any? = runtimeBoundaryIncrement(2)
        consume(erasedElements, erasedValues, erasedNested, injectedAny as Any)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    // The erased container elements must remain Optional values rather than
    // becoming bare Ints under the outer `[Any]` / `[String: Any]` context.
    #expect(result.source.contains("[((2) as Int?) as Any, (nil as Int?) as Any]"))
    #expect(result.source.contains("\"some\": ((2) as Int?) as Any"))
    #expect(result.source.contains("\"none\": (nil as Int?) as Any"))
    // Recursive optional injection and `Any?` injection must also survive a
    // later erasure to `Any` without flattening either optional level.
    #expect(result.source.contains("as Int??) as Any)"))
    #expect(result.source.contains("(((3) as Any?) as Any)"))
    #expect(result.diagnostics.isEmpty)
}

@Test func diagnosticsExposeUTF8OffsetsIntoTheOriginalSource() {
    let parseSource = "let text = \"é\"\nlet ="
    let parseResult = ConstExprRunner(registry: .empty).rewrite(source: parseSource)
    let secondLineOffset = parseSource.range(of: "let =").map {
        parseSource[..<$0.lowerBound].utf8.count
    }
    #expect(secondLineOffset != nil)
    #expect(
        parseResult.diagnostics.filter { $0.code == "parse-error" }.map(\.offset)
            == [secondLineOffset.map { $0 + "let ".utf8.count }, parseSource.utf8.count]
    )

    let evaluationSource = "let text = \"é\"\nlet value = 1 / 0"
    let evaluationResult = ConstExprRunner(registry: .empty).rewrite(
        source: evaluationSource
    )
    let expressionOffset = evaluationSource.range(of: "1 / 0").map {
        evaluationSource[..<$0.lowerBound].utf8.count
    }
    #expect(evaluationResult.diagnostics.map(\.offset) == [expressionOffset])

    let operatorSource = "let text = \"é\"\nlet value = 1 <+> 2"
    let operatorResult = ConstExprRunner(registry: .empty).rewrite(source: operatorSource)
    let operatorOffset = operatorSource.range(of: "<+>").map {
        operatorSource[..<$0.lowerBound].utf8.count
    }
    #expect(operatorResult.diagnostics.map(\.offset) == [operatorOffset])

    let byteOrderMarkSource = "\u{FEFF}let value = 1 / 0"
    let byteOrderMarkResult = ConstExprRunner(registry: .empty).rewrite(
        source: byteOrderMarkSource
    )
    let byteOrderMarkExpressionOffset = byteOrderMarkSource.range(of: "1 / 0").map {
        byteOrderMarkSource[..<$0.lowerBound].utf8.count
    }
    #expect(
        byteOrderMarkResult.diagnostics.map(\.offset)
            == [byteOrderMarkExpressionOffset]
    )
}

@Test func rewritingPreservesAUTF8ByteOrderMark() {
    let byteOrderMark = "\u{FEFF}"
    let unchanged = byteOrderMark + "let value = external(1)\n"
    let rewritten = byteOrderMark + "let value = 1 + 2\n"

    let unchangedResult = ConstExprRunner(registry: .empty).rewrite(source: unchanged)
    let rewrittenResult = ConstExprRunner(registry: .empty).rewrite(source: rewritten)

    #expect(unchangedResult.source == unchanged)
    #expect(rewrittenResult.source == byteOrderMark + "let value = 3\n")
    #expect(unchangedResult.diagnostics.isEmpty)
    #expect(rewrittenResult.diagnostics.isEmpty)
}

@Test func rewritingPreservesCRLFTrivia() {
    let source = "let folded = 1 + 2\r\nlet unchanged = external(3)\r\n"
    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == "let folded = 3\r\nlet unchanged = external(3)\r\n")
    #expect(result.diagnostics.isEmpty)
}

@Test func operatorAssociativityMetadataCannotBeSilentlyIgnored() {
    let counter = RuntimeBoundaryCounter()
    let registration = ConstExprRegistration.infixOperator(
        "^^^",
        left: Int.self,
        right: Int.self,
        result: Int.self,
        precedenceGroup: "AdditionPrecedence",
        associativity: .right
    ) { left, right in
        counter.operatorInvocations += 1
        return left * 10 + right
    }
    let source = "let value = 1 ^^^ 2 ^^^ 3"
    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: source
    )

    #expect(result.source == source)
    #expect(counter.operatorInvocations == 0)
    #expect(result.diagnostics.contains { $0.code.contains("operator") })

    let declaredSource = """
        infix operator ^^^: AdditionPrecedence
        let value = 1 ^^^ 2 ^^^ 3
        """
    let declaredResult = ConstExprRunner(
        registry: ConstExprRegistry(registration)
    ).rewrite(source: declaredSource)

    #expect(declaredResult.source == """
        infix operator ^^^: AdditionPrecedence
        let value = 123
        """)
    #expect(counter.operatorInvocations == 2)
    #expect(declaredResult.diagnostics.isEmpty)
}

@Test func throwingOperatorFactoriesPreserveMissingTryAndNestedTryScopes() {
    let counter = RuntimeBoundaryCounter()
    let registration = ConstExprRegistration.infixOperator(
        "<~>",
        left: Int.self,
        right: Int.self,
        result: Int.self,
        precedenceGroup: "AdditionPrecedence",
        associativity: .left,
        isThrowing: true
    ) { left, right in
        counter.throwingOperatorInvocations += 1
        return left + right
    }
    #expect(registration.isThrowing)

    let source = """
        let missingTry = 1 <~> 2
        let explicitTry = try 3 <~> 4
        let missingNestedTry = try consumeThrowingClosure {
            5 <~> 6
        }
        let explicitNestedTry = try consumeThrowingClosure {
            try 7 <~> 8
        }
        """
    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: source
    )

    #expect(result.source == """
        let missingTry = 1 <~> 2
        let explicitTry = 7
        let missingNestedTry = try consumeThrowingClosure {
            5 <~> 6
        }
        let explicitNestedTry = try consumeThrowingClosure {
            try 7 <~> 8
        }
        """)
    #expect(counter.throwingOperatorInvocations == 1)
    #expect(result.diagnostics.isEmpty)
}
