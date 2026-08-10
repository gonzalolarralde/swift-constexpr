import SwiftSyntax
import Testing
@testable import ConstExpr

@Test func valueDictionariesDecodeRenderDeterministicallyAndHandleEmptyLiteral() throws {
    let structural = ConstExprValue.dictionary([
        (.stringLiteral("b"), .array([.integerLiteral(2)])),
        (.stringLiteral("a"), .array([.integerLiteral(1), .integerLiteral(3)])),
    ])
    #expect(structural.kind == .dictionary)
    #expect(structural.dictionaryEntries?.count == 2)
    #expect(try structural.require([String: [Int]].self) == ["a": [1, 3], "b": [2]])
    #expect(try structural.renderSource() == "[\"a\": [1, 3], \"b\": [2]]")

    let empty = ConstExprValue.dictionary([])
    #expect(try empty.renderSource() == "[:]")

    let typedEmpty = ConstExprValue([String: Int]())
    #expect(ObjectIdentifier(typedEmpty.staticType) == ObjectIdentifier([String: Int].self))
    #expect(
        try typedEmpty.renderSource()
            == "([:]) as Swift.Dictionary<Swift.String, Swift.Int>"
    )

    let typed = try ConstExprValue.dictionary(
        [(.stringLiteral("answer"), .integerLiteral(42))],
        as: [String: Int64].self
    )
    #expect(try typed.require([String: Int64].self) == ["answer": 42])
}

@Test func valueTuplesExposeComponentsRenderLabelsAndSupportTypedDecoding() throws {
    let elements: [(label: String?, value: ConstExprValue)] = [
        ("count", .integerLiteral(2)),
        ("name", .stringLiteral("two")),
    ]
    let structural = ConstExprValue.tuple(elements)
    #expect(structural.kind == .tuple)
    #expect(structural.tupleElements?.map(\.label) == ["count", "name"])
    #expect(try structural.renderSource() == "(count: 2, name: \"two\")")
    let structurallyDecoded = try structural.require((Int, String).self)
    #expect(structurallyDecoded.0 == 2)
    #expect(structurallyDecoded.1 == "two")

    let typed = try ConstExprValue.tuple(elements, as: (Int, String).self)
    let decoded = try typed.require((Int, String).self)
    #expect(decoded.0 == 2)
    #expect(decoded.1 == "two")
    #expect(ObjectIdentifier(typed.staticType) == ObjectIdentifier((Int, String).self))

    let triple = try ConstExprValue.tuple(
        [
            (nil, .integerLiteral(1)),
            (nil, .stringLiteral("x")),
            (nil, .booleanLiteral(true)),
        ],
        as: (Int, String, Bool).self
    )
    let decodedTriple = try triple.require((Int, String, Bool).self)
    #expect(decodedTriple.0 == 1)
    #expect(decodedTriple.1 == "x")
    #expect(decodedTriple.2)

    #expect(throws: ConstExprValueError.self) {
        try ConstExprValue.tuple(elements, as: (Int, String, Bool).self)
    }
}

@Test func valueCustomRepresentableAndOpaqueValuesHaveClearMaterializationBehavior() throws {
    struct RenderedID: ConstExprRepresentable {
        let value: Int
        func constExprExpression() throws -> ExprSyntax {
            ExprSyntax(stringLiteral: "ID(rawValue: \(value))")
        }
    }
    struct OpaqueOnly { let value: Int }

    let rendered = ConstExprValue(RenderedID(value: 3))
    #expect(rendered.kind == .opaque)
    #expect(try rendered.sourceExpression().description == "ID(rawValue: 3)")
    #expect(rendered.renderedSource == "ID(rawValue: 3)")

    let opaque = ConstExprValue.opaque(OpaqueOnly(value: 4))
    #expect(try opaque.require(OpaqueOnly.self).value == 4)
    #expect(opaque.cast(to: OpaqueOnly.self)?.value == 4)
    #expect(opaque.renderedSource == nil)
    #expect(throws: ConstExprValueError.self) {
        try opaque.renderSource()
    }
}

@Test func registrationMapsNonTrailingDefaultsAndRepeatedLabelsInOrder() {
    let registration = ConstExprRegistration(
        name: "describe",
        kind: .function,
        parameterLabels: ["prefix", "number"],
        parameterTypes: [String.self, Int.self],
        defaultedParameters: [0],
        resultType: String.self
    ) { _, _ in ConstExprValue("") }

    #expect(registration.minimumArgumentCount == 1)
    #expect(registration.maximumArgumentCount == 2)
    #expect(registration.argumentMapping(labels: ["number"]) == [nil, 0])
    #expect(registration.argumentMapping(labels: ["prefix", "number"]) == [0, 1])
    #expect(registration.argumentMapping(labels: ["prefix"]) == nil)

    let repeated = ConstExprRegistration(
        name: "pair",
        kind: .function,
        parameterLabels: ["with", "with"],
        parameterTypes: [Int.self, Int.self]
    ) { _, _ in ConstExprValue(0) }
    #expect(repeated.argumentMapping(labels: ["with", "with"]) == [0, 1])
}

@Test func registryReportsInvalidMetadataAndExactCollisionsWithoutTrapping() {
    let invalid = ConstExprRegistration(
        name: "member",
        kind: .instanceMethod,
        parameterLabels: [nil],
        parameterTypes: [],
        defaultedParameters: [2]
    ) { _, _ in ConstExprValue(0) }
    #expect(!invalid.isValid)
    #expect(invalid.validationDiagnostics.map(\.code) == [
        "invalid-registration",
        "invalid-registration",
        "invalid-registration",
    ])

    let first = ConstExprRegistration(
        name: "f",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, _ in ConstExprValue(1) }
    let duplicate = ConstExprRegistration(
        name: "f",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, _ in ConstExprValue(2) }
    let overload = ConstExprRegistration(
        name: "f",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [String.self],
        resultType: Int.self
    ) { _, _ in ConstExprValue(3) }

    let registry = ConstExprRegistry(first, duplicate, overload)
    #expect(!registry.isValid)
    #expect(registry.validationDiagnostics.map(\.code) == ["registry-collision"])
    #expect(registry.candidates(named: "f", kind: .function).count == 3)
}

@Test func registryOwnerLookupAppendingAndManualOperatorFactoriesAreErgonomic() throws {
    struct Owner {}

    let member = ConstExprRegistration(
        name: "value",
        kind: .instanceProperty,
        ownerType: Owner.self,
        resultType: Int.self
    ) { _, _ in ConstExprValue(1) }
    let textual = ConstExprRegistration(
        moduleName: "Feature",
        name: "make",
        kind: .staticMethod,
        ownerName: "Feature.Factory",
        resultType: Int.self
    ) { _, _ in ConstExprValue(2) }
    let unusableTextualInstance = ConstExprRegistration(
        name: "value",
        kind: .instanceProperty,
        ownerName: "Feature.Factory",
        resultType: Int.self
    ) { _, _ in ConstExprValue(3) }

    var registry = ConstExprRegistry(member)
    registry = registry.appending(textual)
    #expect(registry.candidates(named: "value", ownerType: Owner.self).count == 1)
    #expect(registry.candidates(named: "make", ownerName: "Factory").count == 1)
    #expect(registry.candidates(named: "make", ownerName: "Feature.Factory").count == 1)
    #expect(registry.candidates(named: "make", ownerName: "Bogus.Factory").isEmpty)
    #expect(registry.isValid)
    #expect(!unusableTextualInstance.isValid)
    #expect(
        unusableTextualInstance.validationDiagnostics.first?.message.contains(
            "requires an owner type for receiver dispatch"
        ) == true
    )

    let prefix = ConstExprRegistration.prefixOperator("~", operand: Int.self) { ~$0 }
    let infix = ConstExprRegistration.infixOperator(
        "**",
        left: Int.self,
        right: Int.self,
        precedenceGroup: "MultiplicationPrecedence",
        associativity: .left
    ) { $0 * $1 }
    let postfix = ConstExprRegistration.postfixOperator("!", operand: Int.self) { $0 + 1 }

    #expect(try prefix.invoke(arguments: [.some(ConstExprValue(1))]).require(Int.self) == ~1)
    #expect(
        try infix.invoke(arguments: [.some(ConstExprValue(3)), .some(ConstExprValue(4))])
            .require(Int.self) == 12
    )
    #expect(try postfix.invoke(arguments: [.some(ConstExprValue(4))]).require(Int.self) == 5)
    #expect(infix.precedenceGroup == "MultiplicationPrecedence")
    #expect(infix.associativity == .left)
}

@Test func operatorRegistrationsRejectMetadataThatCannotParticipateInDispatch() {
    let labeled = ConstExprRegistration(
        name: "<+>",
        kind: .infixOperator,
        parameterLabels: ["left", nil],
        parameterTypes: [Int.self, Int.self],
        resultType: Int.self
    ) { _, _ in ConstExprValue(0) }
    let prefixWithPrecedence = ConstExprRegistration(
        name: "<^>",
        kind: .prefixOperator,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self,
        precedenceGroup: "AdditionPrecedence"
    ) { _, _ in ConstExprValue(0) }
    let functionWithAssociativity = ConstExprRegistration(
        name: "ordinary",
        kind: .function,
        associativity: .left
    ) { _, _ in ConstExprValue(0) }

    #expect(!labeled.isValid)
    #expect(labeled.validationDiagnostics.map(\.message).contains {
        $0.contains("require unlabeled parameters")
    })
    #expect(!prefixWithPrecedence.isValid)
    #expect(prefixWithPrecedence.validationDiagnostics.map(\.message).contains {
        $0.contains("valid only for infix operators")
    })
    #expect(!functionWithAssociativity.isValid)
    #expect(functionWithAssociativity.validationDiagnostics.map(\.message).contains {
        $0.contains("valid only for infix operators")
    })
}

@Test func diagnosticsExposeStableLocationsAndResultConveniences() {
    let location = ConstExprSourceLocation(
        fileName: "Input.swift",
        line: 4,
        column: 9,
        offset: 27
    )
    let diagnostic = ConstExprDiagnostic(
        severity: .error,
        code: "bad-value",
        message: "could not evaluate value",
        location: location
    )
    #expect(diagnostic.location == location)
    #expect(diagnostic.isError)
    #expect(
        diagnostic.description
            == "Input.swift:4:9: error [bad-value]: could not evaluate value"
    )

    let result = ConstExprRewriteResult(source: "let x = 1", diagnostics: [diagnostic])
    #expect(result.hasDiagnostics)
    #expect(result.hasErrors)
    #expect(ConstExprRewriteResult(source: "").diagnostics.isEmpty)
    #expect(ConstExprRewriteOptions.default.maximumEvaluationSteps == 10_000)
    #expect(ConstExprRewriteOptions.default.maximumRecursionDepth == 256)
}

@Test func erasedOptionalMetatypesProduceExactlyTypedNilValues() throws {
    let integerNil = try #require(
        ConstExprValue.nilValue(ofOptionalType: Optional<Int>.self)
    )
    #expect(integerNil.isOptional)
    #expect(integerNil.isNil)
    #expect(integerNil.optionalWraps(Int.self))
    #expect(try integerNil.renderSource() == "nil as Swift.Optional<Swift.Int>")

    let nestedNil = try #require(
        ConstExprValue.nilValue(ofOptionalType: Optional<Optional<String>>.self)
    )
    #expect(nestedNil.optionalWraps(Optional<String>.self))
    #expect(ConstExprValue.nilValue(ofOptionalType: Int.self)?.isNil == nil)
}
