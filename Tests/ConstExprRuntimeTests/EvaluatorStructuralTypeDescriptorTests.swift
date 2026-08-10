import Testing
@testable import ConstExpr

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
