import Testing
@testable import ConstExpr

private final class ArrayLiteralAdapterCounter: @unchecked Sendable {
    var value = 0
}

private struct ArrayLiteralAdapterItem: Hashable, ExpressibleByStringLiteral {
    let value: String

    init(stringLiteral value: String) {
        self.value = value
    }
}

private struct ArrayLiteralAdapterBag: ExpressibleByArrayLiteral {
    let values: [ArrayLiteralAdapterItem]
    let origin: String

    init() {
        values = []
        origin = "ordinary"
    }

    init(arrayLiteral elements: ArrayLiteralAdapterItem...) {
        values = elements
        origin = "literal"
    }

    init(built elements: [ArrayLiteralAdapterItem]) {
        values = elements
        origin = "built"
    }
}

private struct ArrayLiteralExtensionOnlyBag {
    let values: [ArrayLiteralAdapterItem]
}

extension ArrayLiteralExtensionOnlyBag: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: ArrayLiteralAdapterItem...) {
        values = elements
    }
}

private func arrayLiteralItemRegistration(
    counter: ArrayLiteralAdapterCounter? = nil
) -> ConstExprRegistration {
    ConstExprRegistration(
        name: "ArrayLiteralAdapterItem",
        kind: .initializer,
        ownerType: ArrayLiteralAdapterItem.self,
        parameterLabels: ["stringLiteral"],
        parameterTypes: [String.self],
        resultType: ArrayLiteralAdapterItem.self
    ) { _, arguments in
        counter?.value += 1
        return ConstExprValue(ArrayLiteralAdapterItem(
            stringLiteral: try arguments[0]!.require(String.self)
        ))
    }
}

private func describeArrayLiteralBagRegistration() -> ConstExprRegistration {
    ConstExprRegistration(
        name: "describeArrayLiteralBag",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [ArrayLiteralAdapterBag.self],
        resultType: String.self
    ) { _, arguments in
        let bag = try arguments[0]!.require(ArrayLiteralAdapterBag.self)
        return ConstExprValue(
            "\(bag.origin):" + bag.values.map(\.value).joined(separator: ",")
        )
    }
}

@Test func automaticArrayLiteralAdapterUsesContextAndTheEmptyProtocolWitness() {
    let registry = ConstExprRegistry(registrations: [
        arrayLiteralItemRegistration(),
        .arrayLiteral(
            result: ArrayLiteralAdapterBag.self,
            element: ArrayLiteralAdapterItem.self
        ),
        describeArrayLiteralBagRegistration(),
        ConstExprRegistration(
            name: "describeOptionalArrayLiteralBag",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ArrayLiteralAdapterBag?.self],
            resultType: String.self
        ) { _, arguments in
            let bag = try arguments[0]!.require(ArrayLiteralAdapterBag?.self)
            return ConstExprValue(
                bag.map {
                    "some:\($0.origin):" + $0.values.map(\.value).joined(separator: ",")
                } ?? "nil"
            )
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let bag: ArrayLiteralAdapterBag = ["a", "b"]
        let scoped = describeArrayLiteralBag(bag)
        let empty = describeArrayLiteralBag([])
        let optional = describeOptionalArrayLiteralBag(["c"])
        """)

    #expect(result.source == """
        let bag: ArrayLiteralAdapterBag = ["a", "b"]
        let scoped = "literal:a,b"
        let empty = "literal:"
        let optional = "some:literal:c"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func explicitArrayLiteralBuilderCanBeUnboundedAndEnforcesAnOptionalCap() throws {
    let buildCounter = ArrayLiteralAdapterCounter()
    let unbounded = ConstExprRegistration.arrayLiteral(
        result: ArrayLiteralAdapterBag.self,
        element: ArrayLiteralAdapterItem.self
    ) { elements in
        buildCounter.value += 1
        return ArrayLiteralAdapterBag(built: elements)
    }
    let registry = ConstExprRegistry(registrations: [
        arrayLiteralItemRegistration(),
        unbounded,
        describeArrayLiteralBagRegistration(),
    ])
    let elements = (0..<40).map { "\"item\($0)\"" }.joined(separator: ", ")
    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = describeArrayLiteralBag([\(elements)])\n"
    )

    #expect(result.source == "let value = \"built:item0,item1,item2,item3,item4,item5,item6,item7,item8,item9,item10,item11,item12,item13,item14,item15,item16,item17,item18,item19,item20,item21,item22,item23,item24,item25,item26,item27,item28,item29,item30,item31,item32,item33,item34,item35,item36,item37,item38,item39\"\n")
    #expect(buildCounter.value == 1)
    #expect(result.diagnostics.isEmpty)

    let limitedCounter = ArrayLiteralAdapterCounter()
    let limited = ConstExprRegistration.arrayLiteral(
        result: ArrayLiteralAdapterBag.self,
        element: ArrayLiteralAdapterItem.self,
        maximumElementCount: 1
    ) { elements in
        limitedCounter.value += 1
        return ArrayLiteralAdapterBag(built: elements)
    }
    #expect(throws: ConstExprValueError.self) {
        try limited.invoke(arguments: [
            ConstExprValue(ArrayLiteralAdapterItem(stringLiteral: "a")),
            ConstExprValue(ArrayLiteralAdapterItem(stringLiteral: "b")),
        ])
    }
    #expect(limitedCounter.value == 0)
}

@Test func arrayLiteralAdapterAmbiguityAndUnknownElementsNeverInvokeBuilders() {
    let ambiguousCounter = ArrayLiteralAdapterCounter()
    let ambiguousElementCounter = ArrayLiteralAdapterCounter()
    let first = ConstExprRegistration.arrayLiteral(
        result: ArrayLiteralAdapterBag.self,
        element: ArrayLiteralAdapterItem.self,
        declarationID: "array-literal-adapter-first"
    ) { elements in
        ambiguousCounter.value += 1
        return ArrayLiteralAdapterBag(built: elements)
    }
    let second = ConstExprRegistration.arrayLiteral(
        result: ArrayLiteralAdapterBag.self,
        element: ArrayLiteralAdapterItem.self,
        declarationID: "array-literal-adapter-second"
    ) { elements in
        ambiguousCounter.value += 1
        return ArrayLiteralAdapterBag(built: elements)
    }
    let ambiguousSource = "let value = describeArrayLiteralBag([\"a\"])\n"
    let ambiguous = ConstExprRunner(registry: .init(registrations: [
        arrayLiteralItemRegistration(counter: ambiguousElementCounter),
        first,
        second,
        describeArrayLiteralBagRegistration(),
    ])).rewrite(source: ambiguousSource)

    #expect(ambiguous.source == ambiguousSource)
    #expect(ambiguousCounter.value == 0)
    #expect(ambiguousElementCounter.value == 0)
    #expect(ambiguous.diagnostics.map(\.code) == ["ambiguous-overload"])

    let unknownCounter = ArrayLiteralAdapterCounter()
    let unknownAdapter = ConstExprRegistration.arrayLiteral(
        result: ArrayLiteralAdapterBag.self,
        element: ArrayLiteralAdapterItem.self
    ) { elements in
        unknownCounter.value += 1
        return ArrayLiteralAdapterBag(built: elements)
    }
    let unknownSource = "let value = describeArrayLiteralBag([\"a\", runtimeItem])\n"
    let unknown = ConstExprRunner(registry: .init(registrations: [
        arrayLiteralItemRegistration(),
        unknownAdapter,
        describeArrayLiteralBagRegistration(),
    ])).rewrite(source: unknownSource)

    #expect(unknown.source == unknownSource)
    #expect(unknownCounter.value == 0)
    #expect(unknown.diagnostics.isEmpty)
}

@Test func automaticArrayLiteralLimitIsCheckedBeforeAnyElementEvaluation() {
    let elementCounter = ArrayLiteralAdapterCounter()
    let registry = ConstExprRegistry(registrations: [
        arrayLiteralItemRegistration(counter: elementCounter),
        .arrayLiteral(
            result: ArrayLiteralAdapterBag.self,
            element: ArrayLiteralAdapterItem.self
        ),
        describeArrayLiteralBagRegistration(),
    ])
    let elements = (0..<33).map { "\"item\($0)\"" }.joined(separator: ", ")
    let source = "let value = describeArrayLiteralBag([\(elements)])\n"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(elementCounter.value == 0)
    #expect(result.diagnostics.map(\.code) == ["array-literal-element-limit"])
}

@Test func standardArrayAndSetAdaptersRecurseWithoutRegisteredContainerCode() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "describeSetOfSets",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Set<Set<String>>.self],
            resultType: String.self
        ) { _, arguments in
            let sets = try arguments[0]!.require(Set<Set<String>>.self)
            return ConstExprValue(
                sets.map { $0.sorted().joined(separator: ",") }
                    .sorted()
                    .joined(separator: "|")
            )
        },
        ConstExprRegistration(
            name: "describeArrayOfSets",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Set<String>].self],
            resultType: String.self
        ) { _, arguments in
            let sets = try arguments[0]!.require([Set<String>].self)
            return ConstExprValue(
                sets.map { $0.sorted().joined(separator: ",") }
                    .joined(separator: "|")
            )
        },
    ])
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let nestedSet = describeSetOfSets([["b", "a"], ["c"]])
        let nestedArray = describeArrayOfSets([["z"], ["y", "x"]])
        """)

    #expect(result.source == """
        let nestedSet = "a,b|c"
        let nestedArray = "z|x,y"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func unregisteredExtensionConformanceAndInvalidOwnerMetadataStayOpaque() {
    let counter = ArrayLiteralAdapterCounter()
    let invalid = ConstExprRegistration(
        name: "arrayLiteral",
        kind: .arrayLiteral,
        ownerType: ArrayLiteralExtensionOnlyBag.self,
        resultType: ArrayLiteralAdapterBag.self,
        arrayLiteralElementType: ArrayLiteralAdapterItem.self,
        arrayLiteralElementTypeDescriptor: .inferred(ArrayLiteralAdapterItem.self)
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(ArrayLiteralAdapterBag(built: []))
    }
    #expect(!invalid.isValid)

    let registry = ConstExprRegistry(registrations: [
        invalid,
        ConstExprRegistration(
            name: "describeExtensionOnlyArrayLiteralBag",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ArrayLiteralExtensionOnlyBag.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(ArrayLiteralExtensionOnlyBag.self).values.count
            )
        },
    ])
    let source = "let value = describeExtensionOnlyArrayLiteralBag([])\n"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(result.diagnostics.contains { $0.code == "invalid-registration" })
}
