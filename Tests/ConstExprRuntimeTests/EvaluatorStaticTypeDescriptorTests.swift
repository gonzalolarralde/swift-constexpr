import Testing
@testable import ConstExpr

private protocol DescriptorValueProtocol {}
private protocol DescriptorClassProtocol: AnyObject {}

private class DescriptorBase: DescriptorValueProtocol {}
private final class DescriptorDerived: DescriptorBase {}
private final class DescriptorBoth: DescriptorValueProtocol, DescriptorClassProtocol {}

private class DescriptorUnrelatedBase {}
private final class DescriptorDynamicConformer: DescriptorUnrelatedBase, DescriptorValueProtocol {}

private let descriptorValueExistential: ConstExprStaticTypeDescriptor = .leaf(
    type: (any DescriptorValueProtocol).self,
    sourceName: "any DescriptorValueProtocol",
    isExistential: true,
    isClassBound: false,
    acceptsSourceType: { $0 is any DescriptorValueProtocol.Type }
)

private let descriptorClassExistential: ConstExprStaticTypeDescriptor = .leaf(
    type: (any DescriptorClassProtocol).self,
    sourceName: "any DescriptorClassProtocol",
    isExistential: true,
    isClassBound: true,
    acceptsSourceType: { $0 is any DescriptorClassProtocol.Type }
)

private func descriptorLeaf(
    _ type: Any.Type,
    sourceName: String
) -> ConstExprStaticTypeDescriptor {
    .leaf(
        type: type,
        sourceName: sourceName,
        isExistential: false,
        isClassBound: type is AnyClass,
        acceptsSourceType: nil
    )
}

@Test func evaluatorUsesDeclaredProtocolConformanceInsteadOfADynamicSubclass() {
    final class Counter: @unchecked Sendable { var factory = 0; var selected = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDescriptorBase",
            kind: .function,
            resultType: DescriptorBase.self,
            resultTypeDescriptor: descriptorLeaf(
                DescriptorBase.self,
                sourceName: "DescriptorBase"
            )
        ) { _, _ in
            counter.factory += 1
            // The implementation's dynamic result is more specific than its
            // declaration. Overload resolution must still see DescriptorBase.
            return ConstExprValue(DescriptorDerived())
        },
        ConstExprRegistration(
            name: "describeDescriptorBase",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any DescriptorValueProtocol).self],
            parameterTypeDescriptors: [descriptorValueExistential],
            resultType: String.self,
            declarationID: "descriptor-protocol"
        ) { _, arguments in
            counter.selected += 1
            _ = try arguments[0]!.require((any DescriptorValueProtocol).self)
            return ConstExprValue("protocol")
        },
        ConstExprRegistration(
            name: "describeDescriptorBase",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self,
            declarationID: "descriptor-any"
        ) { _, _ in
            counter.selected += 1
            return ConstExprValue("any")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = describeDescriptorBase(makeDescriptorBase())"
    )

    #expect(result.source == "let value = \"protocol\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.selected == 1)
}

@Test func evaluatorDistinguishesClassBoundAndValueExistentialsRecursively() {
    final class Counter: @unchecked Sendable { var factories = 0; var selected = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDescriptorClassValues",
            kind: .function,
            resultType: [any DescriptorClassProtocol].self,
            resultTypeDescriptor: .array(descriptorClassExistential)
        ) { _, _ in
            counter.factories += 1
            let classValues: [any DescriptorClassProtocol] = [DescriptorBoth()]
            return ConstExprValue(classValues)
        },
        ConstExprRegistration(
            name: "makeOptionalDescriptorClassValue",
            kind: .function,
            resultType: (any DescriptorClassProtocol)?.self,
            resultTypeDescriptor: .optional(descriptorClassExistential)
        ) { _, _ in
            counter.factories += 1
            let classValue: (any DescriptorClassProtocol)? = DescriptorBoth()
            return ConstExprValue(classValue)
        },
        ConstExprRegistration(
            name: "makeDescriptorValueValues",
            kind: .function,
            resultType: [any DescriptorValueProtocol].self,
            resultTypeDescriptor: .array(descriptorValueExistential)
        ) { _, _ in
            counter.factories += 1
            let valueValues: [any DescriptorValueProtocol] = [DescriptorBoth()]
            return ConstExprValue(valueValues)
        },
        ConstExprRegistration(
            name: "describeDescriptorClassValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[AnyObject].self],
            resultType: String.self,
            declarationID: "descriptor-array-object"
        ) { _, arguments in
            counter.selected += 1
            _ = try arguments[0]!.require([AnyObject].self)
            return ConstExprValue("objects")
        },
        ConstExprRegistration(
            name: "describeDescriptorClassValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Any].self],
            resultType: String.self,
            declarationID: "descriptor-array-any"
        ) { _, _ in
            counter.selected += 1
            return ConstExprValue("any")
        },
        ConstExprRegistration(
            name: "describeOptionalDescriptorClassValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject?.self],
            resultType: String.self,
            declarationID: "descriptor-optional-object"
        ) { _, arguments in
            counter.selected += 1
            _ = try arguments[0]!.require(AnyObject?.self)
            return ConstExprValue("object")
        },
        ConstExprRegistration(
            name: "describeOptionalDescriptorClassValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any?.self],
            resultType: String.self,
            declarationID: "descriptor-optional-any"
        ) { _, _ in
            counter.selected += 1
            return ConstExprValue("any")
        },
        ConstExprRegistration(
            name: "describeDescriptorValueValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[AnyObject].self],
            resultType: String.self,
            declarationID: "descriptor-value-array-object"
        ) { _, _ in
            counter.selected += 1
            return ConstExprValue("wrong")
        },
        ConstExprRegistration(
            name: "describeDescriptorValueValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Any].self],
            resultType: String.self,
            declarationID: "descriptor-value-array-any"
        ) { _, arguments in
            counter.selected += 1
            _ = try arguments[0]!.require([Any].self)
            return ConstExprValue("any")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let array = describeDescriptorClassValues(makeDescriptorClassValues())
        let optional = describeOptionalDescriptorClassValue(makeOptionalDescriptorClassValue())
        let valueArray = describeDescriptorValueValues(makeDescriptorValueValues())
        """)

    #expect(result.source == """
        let array = "objects"
        let optional = "object"
        let valueArray = "any"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factories == 3)
    #expect(counter.selected == 3)
}

@Test func evaluatorKeepsIncomparableClassAndProtocolOverloadsAmbiguous() {
    final class Counter: @unchecked Sendable { var factories = 0; var overloads = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDescriptorBoth",
            kind: .function,
            resultType: DescriptorBoth.self
        ) { _, _ in
            counter.factories += 1
            return ConstExprValue(DescriptorBoth())
        },
        ConstExprRegistration(
            name: "makeDescriptorDerived",
            kind: .function,
            resultType: DescriptorDerived.self
        ) { _, _ in
            counter.factories += 1
            return ConstExprValue(DescriptorDerived())
        },
        ConstExprRegistration(
            name: "nonClassDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any DescriptorValueProtocol).self],
            parameterTypeDescriptors: [descriptorValueExistential],
            resultType: String.self,
            declarationID: "nonclass-protocol"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("protocol") },
        ConstExprRegistration(
            name: "nonClassDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject.self],
            resultType: String.self,
            declarationID: "nonclass-object"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("object") },
        ConstExprRegistration(
            name: "superclassDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DescriptorBase.self],
            resultType: String.self,
            declarationID: "superclass-base"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("base") },
        ConstExprRegistration(
            name: "superclassDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any DescriptorValueProtocol).self],
            parameterTypeDescriptors: [descriptorValueExistential],
            resultType: String.self,
            declarationID: "superclass-protocol"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("protocol") },
        ConstExprRegistration(
            name: "classBoundDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any DescriptorClassProtocol).self],
            parameterTypeDescriptors: [descriptorClassExistential],
            resultType: String.self,
            declarationID: "classbound-protocol"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("class protocol") },
        ConstExprRegistration(
            name: "classBoundDescriptorChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject.self],
            resultType: String.self,
            declarationID: "classbound-object"
        ) { _, _ in counter.overloads += 1; return ConstExprValue("object") },
    ])
    let source = """
        let ambiguousObject = nonClassDescriptorChoice(makeDescriptorBoth())
        let ambiguousSuperclass = superclassDescriptorChoice(makeDescriptorDerived())
        let classBound = classBoundDescriptorChoice(makeDescriptorBoth())
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == """
        let ambiguousObject = nonClassDescriptorChoice(makeDescriptorBoth())
        let ambiguousSuperclass = superclassDescriptorChoice(makeDescriptorDerived())
        let classBound = "class protocol"
        """)
    #expect(result.diagnostics.count == 2)
    #expect(result.diagnostics.allSatisfy { $0.code == "ambiguous-overload" })
    #expect(counter.factories == 3)
    #expect(counter.overloads == 1)
}

@Test func evaluatorRejectsDynamicDowncastsAndMalformedDescriptorShapes() {
    final class Counter: @unchecked Sendable { var factory = 0; var invalid = 0 }
    let counter = Counter()
    let invalid = ConstExprRegistration(
        name: "invalidDescriptor",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        parameterTypeDescriptors: [.array(.inferred(Int.self))],
        resultType: String.self
    ) { _, _ in
        counter.invalid += 1
        return ConstExprValue("wrong")
    }
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDescriptorUnrelatedBase",
            kind: .function,
            resultType: DescriptorUnrelatedBase.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DescriptorDynamicConformer())
        },
        ConstExprRegistration(
            name: "acceptDescriptorProtocol",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any DescriptorValueProtocol).self],
            parameterTypeDescriptors: [descriptorValueExistential],
            resultType: String.self
        ) { _, _ in ConstExprValue("wrong") },
        invalid,
    ])
    let source = """
        let dynamic = acceptDescriptorProtocol(makeDescriptorUnrelatedBase())
        let malformed = invalidDescriptor(1)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.contains { $0.code == "no-matching-overload" })
    #expect(result.diagnostics.contains { $0.code == "invalid-registration" })
    #expect(counter.factory == 1)
    #expect(counter.invalid == 0)
}

@Test func evaluatorRejectsTupleDescriptorsWithTheWrongRuntimeShape() {
    let registration = ConstExprRegistration(
        name: "invalidTupleDescriptor",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [(Int, Int, Int).self],
        parameterTypeDescriptors: [
            .tuple([.inferred(Int.self), .inferred(Int.self)])
        ],
        resultType: Int.self
    ) { _, _ in ConstExprValue(0) }

    #expect(!registration.isValid)
    #expect(registration.validationDiagnostics.count == 1)
    #expect(registration.validationDiagnostics.first?.code == "invalid-registration")
}

@Test func evaluatorFlowsExactBoxedTupleResultsBeyondStructuralDecoderArities() {
    let descriptor: ConstExprStaticTypeDescriptor = .tuple([
        .inferred(Int.self), .inferred(Int.self), .inferred(Int.self),
        .inferred(Int.self), .inferred(Int.self),
    ])
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeFiveTuple",
            kind: .function,
            resultType: (Int, Int, Int, Int, Int).self,
            resultTypeDescriptor: descriptor
        ) { _, _ in ConstExprValue((1, 2, 3, 4, 5)) },
        ConstExprRegistration(
            name: "sumFiveTuple",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(Int, Int, Int, Int, Int).self],
            parameterTypeDescriptors: [descriptor],
            resultType: Int.self
        ) { _, arguments in
            let value = try arguments[0]!.require((Int, Int, Int, Int, Int).self)
            return ConstExprValue(value.0 + value.1 + value.2 + value.3 + value.4)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = sumFiveTuple(makeFiveTuple())"
    )

    #expect(result.source == "let value = 15")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorHonorsTupleLabelsDuringConversionAndOverloadRanking() {
    final class Counter: @unchecked Sendable {
        var wrong = 0
        var exact = 0
        var unlabeled = 0
    }
    let counter = Counter()
    let tupleDescriptor: ConstExprStaticTypeDescriptor = .tuple([
        .inferred(Int.self), .inferred(Int.self),
    ])
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeLabeledTupleForRanking",
            kind: .function,
            resultType: (x: Int, y: Int).self,
            resultTypeDescriptor: tupleDescriptor
        ) { _, _ in ConstExprValue((x: 1, y: 2)) },
        ConstExprRegistration(
            name: "consumeWrongTupleLabels",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(a: Int, b: Int).self],
            parameterTypeDescriptors: [tupleDescriptor],
            resultType: String.self
        ) { _, _ in
            counter.wrong += 1
            return ConstExprValue("wrong")
        },
        ConstExprRegistration(
            name: "tupleLabelChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(x: Int, y: Int).self],
            parameterTypeDescriptors: [tupleDescriptor],
            resultType: String.self,
            declarationID: "tuple-label-exact"
        ) { _, _ in
            counter.exact += 1
            return ConstExprValue("exact")
        },
        ConstExprRegistration(
            name: "tupleLabelChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(Int, Int).self],
            parameterTypeDescriptors: [tupleDescriptor],
            resultType: String.self,
            declarationID: "tuple-label-unlabeled"
        ) { _, _ in
            counter.unlabeled += 1
            return ConstExprValue("unlabeled")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let invalid = consumeWrongTupleLabels(makeLabeledTupleForRanking())
        let preferred = tupleLabelChoice(makeLabeledTupleForRanking())
        """)

    #expect(!result.source.contains("\"wrong\""))
    #expect(result.source.contains("let preferred = \"exact\""))
    #expect(result.diagnostics.contains { $0.code == "no-matching-overload" })
    #expect(counter.wrong == 0)
    #expect(counter.exact == 1)
    #expect(counter.unlabeled == 0)
}

@Test func evaluatorAppliesTupleResultDescriptorsToProjections() {
    let tupleDescriptor: ConstExprStaticTypeDescriptor = .tuple([
        descriptorLeaf(DescriptorBase.self, sourceName: "DescriptorBase"),
        .inferred(Any.self, sourceName: "Any"),
    ])
    let labeledTupleDescriptor: ConstExprStaticTypeDescriptor = .tuple([
        .inferred(Int.self, sourceName: "Int"),
        .inferred(String.self, sourceName: "String"),
    ])
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDescriptorTuple",
            kind: .function,
            resultType: (DescriptorBase, Any).self,
            resultTypeDescriptor: tupleDescriptor
        ) { _, _ in
            let value: (DescriptorBase, Any) = (DescriptorDerived(), 7)
            return ConstExprValue(value)
        },
        ConstExprRegistration(
            name: "makeLabeledDescriptorTuple",
            kind: .function,
            resultType: (first: Int, second: String).self,
            resultTypeDescriptor: labeledTupleDescriptor
        ) { _, _ in
            let value: (first: Int, second: String) = (4, "four")
            return ConstExprValue(value)
        },
        ConstExprRegistration(
            name: "descriptorTupleBaseChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DescriptorBase.self],
            resultType: String.self,
            declarationID: "tuple-base"
        ) { _, _ in ConstExprValue("base") },
        ConstExprRegistration(
            name: "descriptorTupleBaseChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DescriptorDerived.self],
            resultType: String.self,
            declarationID: "tuple-derived"
        ) { _, _ in ConstExprValue("derived") },
        ConstExprRegistration(
            name: "descriptorTupleAnyChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self,
            declarationID: "tuple-any"
        ) { _, _ in ConstExprValue("any") },
        ConstExprRegistration(
            name: "descriptorTupleAnyChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: String.self,
            declarationID: "tuple-int"
        ) { _, _ in ConstExprValue("int") },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let base = descriptorTupleBaseChoice(makeDescriptorTuple().0)
        let erased = descriptorTupleAnyChoice(makeDescriptorTuple().1)
        let label = makeLabeledDescriptorTuple().first
        """)

    #expect(result.source == """
        let base = "base"
        let erased = "any"
        let label = 4
        """)
    #expect(result.diagnostics.isEmpty)
}
