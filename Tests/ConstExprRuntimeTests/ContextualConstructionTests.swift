import Testing
@testable import ConstExpr

private final class ContextualConstructionCounter: @unchecked Sendable {
    var value = 0
}

private struct ContextualInitBox {
    let value: Int
}

private struct ContextualOverloadedBox {
    let description: String
}

private struct ContextualAmbiguousBox {}

private struct ContextualStaticValue {
    let description: String
}

private struct ContextualUnrelatedOwner {}

private struct ContextualUnrelatedProduct {
    let description: String
}

private struct RegisteredStringLiteral: ExpressibleByStringLiteral {
    let value: String

    init(stringLiteral value: String) {
        self.value = value
    }
}

private struct RegisteredIntegerLiteral: ExpressibleByIntegerLiteral {
    let value: Int

    init(integerLiteral value: Int) {
        self.value = value
    }
}

private struct RegisteredFloatLiteral: ExpressibleByFloatLiteral {
    let value: Double

    init(floatLiteral value: Double) {
        self.value = value
    }
}

private struct RegisteredBooleanLiteral: ExpressibleByBooleanLiteral {
    let value: Bool

    init(booleanLiteral value: Bool) {
        self.value = value
    }
}

private struct UnregisteredStringLiteral: ExpressibleByStringLiteral {
    let value: String

    init(stringLiteral value: String) {
        self.value = value
    }
}

private struct ExtensionOnlyStringLiteral {
    let value: String
}

extension ExtensionOnlyStringLiteral: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.init(value: value)
    }
}

private func contextualInitRegistry(
    ambiguousCounter: ContextualConstructionCounter? = nil
) -> ConstExprRegistry {
    ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "ContextualInitBox",
            kind: .initializer,
            ownerType: ContextualInitBox.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: ContextualInitBox.self
        ) { _, arguments in
            ConstExprValue(ContextualInitBox(value: try arguments[0]!.require(Int.self)))
        },
        ConstExprRegistration(
            name: "describeContextualInitBox",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ContextualInitBox.self],
            resultType: String.self
        ) { _, arguments in
            let box = try arguments[0]!.require(ContextualInitBox.self)
            return ConstExprValue("box:\(box.value)")
        },
        ConstExprRegistration(
            name: "sumContextualInitBoxes",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[ContextualInitBox].self],
            resultType: Int.self
        ) { _, arguments in
            let boxes = try arguments[0]!.require([ContextualInitBox].self)
            return ConstExprValue(boxes.reduce(0) { $0 + $1.value })
        },
        ConstExprRegistration(
            name: "ContextualOverloadedBox",
            kind: .initializer,
            ownerType: ContextualOverloadedBox.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: ContextualOverloadedBox.self,
            declarationID: "contextual-overload-int"
        ) { _, arguments in
            ConstExprValue(ContextualOverloadedBox(
                description: "integer:\(try arguments[0]!.require(Int.self))"
            ))
        },
        ConstExprRegistration(
            name: "ContextualOverloadedBox",
            kind: .initializer,
            ownerType: ContextualOverloadedBox.self,
            parameterLabels: [nil],
            parameterTypes: [String.self],
            resultType: ContextualOverloadedBox.self,
            declarationID: "contextual-overload-string"
        ) { _, arguments in
            ConstExprValue(ContextualOverloadedBox(
                description: "string:\(try arguments[0]!.require(String.self))"
            ))
        },
        ConstExprRegistration(
            name: "describeContextualOverloadedBox",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ContextualOverloadedBox.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(ContextualOverloadedBox.self).description
            )
        },
        ConstExprRegistration(
            name: "ContextualAmbiguousBox",
            kind: .initializer,
            ownerType: ContextualAmbiguousBox.self,
            parameterLabels: [nil],
            parameterTypes: [Int8.self],
            resultType: ContextualAmbiguousBox.self,
            declarationID: "contextual-ambiguous-int8"
        ) { _, arguments in
            ambiguousCounter?.value += 1
            _ = try arguments[0]!.require(Int8.self)
            return ConstExprValue(ContextualAmbiguousBox())
        },
        ConstExprRegistration(
            name: "ContextualAmbiguousBox",
            kind: .initializer,
            ownerType: ContextualAmbiguousBox.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: ContextualAmbiguousBox.self,
            declarationID: "contextual-ambiguous-uint8"
        ) { _, arguments in
            ambiguousCounter?.value += 1
            _ = try arguments[0]!.require(UInt8.self)
            return ConstExprValue(ContextualAmbiguousBox())
        },
        ConstExprRegistration(
            name: "describeContextualAmbiguousBox",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ContextualAmbiguousBox.self],
            resultType: String.self
        ) { _, _ in ConstExprValue("ambiguous") },
    ])
}

@Test func contextualInitUsesBindingArrayAndParameterExpectedTypes() {
    let result = ConstExprRunner(registry: contextualInitRegistry()).rewrite(source: """
        let bound: ContextualInitBox = .init(1)
        let bindingResult = describeContextualInitBox(bound)
        let arrayResult = sumContextualInitBoxes([.init(2), .init(3)])
        let parameterResult = describeContextualInitBox(.init(4))
        """)

    #expect(result.source == """
        let bound: ContextualInitBox = .init(1)
        let bindingResult = "box:1"
        let arrayResult = 5
        let parameterResult = "box:4"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func contextualInitRanksUniqueOverloadsAndPreservesAmbiguity() {
    let counter = ContextualConstructionCounter()
    let result = ConstExprRunner(
        registry: contextualInitRegistry(ambiguousCounter: counter)
    ).rewrite(source: """
        let integer = describeContextualOverloadedBox(.init(7))
        let string = describeContextualOverloadedBox(.init("value"))
        let ambiguous = describeContextualAmbiguousBox(.init(1))
        """)

    #expect(result.source == """
        let integer = "integer:7"
        let string = "string:value"
        let ambiguous = describeContextualAmbiguousBox(.init(1))
        """)
    #expect(counter.value == 0)
    #expect(result.diagnostics.contains { $0.code == "ambiguous-overload" })
}

@Test func contextualStaticFactoriesAndPropertiesRequireTheContextualOwner() {
    let unrelatedCounter = ContextualConstructionCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "make",
            kind: .staticMethod,
            ownerType: ContextualStaticValue.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: ContextualStaticValue.self
        ) { _, arguments in
            ConstExprValue(ContextualStaticValue(
                description: "made:\(try arguments[0]!.require(Int.self))"
            ))
        },
        ConstExprRegistration(
            name: "standard",
            kind: .staticProperty,
            ownerType: ContextualStaticValue.self,
            resultType: ContextualStaticValue.self
        ) { _, _ in
            ConstExprValue(ContextualStaticValue(description: "standard"))
        },
        ConstExprRegistration(
            name: "describeContextualStaticValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ContextualStaticValue.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(ContextualStaticValue.self).description
            )
        },
        ConstExprRegistration(
            name: "make",
            kind: .staticMethod,
            ownerType: ContextualUnrelatedOwner.self,
            resultType: ContextualUnrelatedProduct.self
        ) { _, _ in
            unrelatedCounter.value += 1
            return ConstExprValue(ContextualUnrelatedProduct(description: "wrong owner"))
        },
        ConstExprRegistration(
            name: "describeContextualUnrelatedProduct",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ContextualUnrelatedProduct.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(ContextualUnrelatedProduct.self).description
            )
        },
    ])
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let method = describeContextualStaticValue(.make(9))
        let property = describeContextualStaticValue(.standard)
        let unrelated: ContextualUnrelatedProduct = .make()
        let unrelatedDescription = describeContextualUnrelatedProduct(unrelated)
        """)

    #expect(result.source == """
        let method = "made:9"
        let property = "standard"
        let unrelated: ContextualUnrelatedProduct = .make()
        let unrelatedDescription = describeContextualUnrelatedProduct(unrelated)
        """)
    #expect(unrelatedCounter.value == 0)
}

private let registeredLiteralRegistry = ConstExprRegistry(registrations: [
    ConstExprRegistration(
        name: "RegisteredStringLiteral",
        kind: .initializer,
        ownerType: RegisteredStringLiteral.self,
        parameterLabels: ["stringLiteral"],
        parameterTypes: [String.self],
        resultType: RegisteredStringLiteral.self
    ) { _, arguments in
        ConstExprValue(RegisteredStringLiteral(
            stringLiteral: try arguments[0]!.require(String.self)
        ))
    },
    ConstExprRegistration(
        name: "RegisteredIntegerLiteral",
        kind: .initializer,
        ownerType: RegisteredIntegerLiteral.self,
        parameterLabels: ["integerLiteral"],
        parameterTypes: [Int.self],
        resultType: RegisteredIntegerLiteral.self
    ) { _, arguments in
        ConstExprValue(RegisteredIntegerLiteral(
            integerLiteral: try arguments[0]!.require(Int.self)
        ))
    },
    ConstExprRegistration(
        name: "RegisteredFloatLiteral",
        kind: .initializer,
        ownerType: RegisteredFloatLiteral.self,
        parameterLabels: ["floatLiteral"],
        parameterTypes: [Double.self],
        resultType: RegisteredFloatLiteral.self
    ) { _, arguments in
        ConstExprValue(RegisteredFloatLiteral(
            floatLiteral: try arguments[0]!.require(Double.self)
        ))
    },
    ConstExprRegistration(
        name: "RegisteredBooleanLiteral",
        kind: .initializer,
        ownerType: RegisteredBooleanLiteral.self,
        parameterLabels: ["booleanLiteral"],
        parameterTypes: [Bool.self],
        resultType: RegisteredBooleanLiteral.self
    ) { _, arguments in
        ConstExprValue(RegisteredBooleanLiteral(
            booleanLiteral: try arguments[0]!.require(Bool.self)
        ))
    },
    ConstExprRegistration(
        name: "describeRegisteredStringLiteral",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [RegisteredStringLiteral.self],
        resultType: String.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(RegisteredStringLiteral.self).value)
    },
    ConstExprRegistration(
        name: "describeRegisteredIntegerLiteral",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [RegisteredIntegerLiteral.self],
        resultType: Int.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(RegisteredIntegerLiteral.self).value)
    },
    ConstExprRegistration(
        name: "describeRegisteredFloatLiteral",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [RegisteredFloatLiteral.self],
        resultType: Double.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(RegisteredFloatLiteral.self).value)
    },
    ConstExprRegistration(
        name: "describeRegisteredBooleanLiteral",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [RegisteredBooleanLiteral.self],
        resultType: Bool.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(RegisteredBooleanLiteral.self).value)
    },
    ConstExprRegistration(
        name: "describeNestedRegisteredStrings",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [[[RegisteredStringLiteral]].self],
        resultType: String.self
    ) { _, arguments in
        let groups = try arguments[0]!.require([[RegisteredStringLiteral]].self)
        return ConstExprValue(groups.map { group in
            group.map(\.value).joined(separator: ",")
        }.joined(separator: "|"))
    },
])

@Test func registeredLiteralConformersFlowThroughCallsAndNestedArrays() {
    let result = ConstExprRunner(registry: registeredLiteralRegistry).rewrite(source: """
        let string = describeRegisteredStringLiteral("hello")
        let integer = describeRegisteredIntegerLiteral(42)
        let float = describeRegisteredFloatLiteral(1.25)
        let boolean = describeRegisteredBooleanLiteral(true)
        let nested = describeNestedRegisteredStrings([["a"], ["b", "c"]])
        """)

    #expect(result.source == """
        let string = "hello"
        let integer = 42
        let float = 1.25
        let boolean = true
        let nested = "a|b,c"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func unregisteredAndExtensionOnlyLiteralConformancesRemainCompilerWork() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "describeUnregisteredStringLiteral",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [UnregisteredStringLiteral.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(UnregisteredStringLiteral.self).value
            )
        },
        ConstExprRegistration(
            name: "describeExtensionOnlyStringLiteral",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [ExtensionOnlyStringLiteral.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(ExtensionOnlyStringLiteral.self).value
            )
        },
    ])
    let source = """
        let unregistered = describeUnregisteredStringLiteral("library")
        let extensionOnly = describeExtensionOnlyStringLiteral("dependency")
        """
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
}

@Test func scalarLiteralConversionRequiresTheInitializerOwnerToBeTheTarget() {
    let counter = ContextualConstructionCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "RegisteredStringLiteral",
            kind: .initializer,
            ownerType: ContextualUnrelatedOwner.self,
            parameterLabels: ["stringLiteral"],
            parameterTypes: [String.self],
            resultType: RegisteredStringLiteral.self,
            declarationID: "wrong-owner-string-literal"
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(RegisteredStringLiteral(
                stringLiteral: try arguments[0]!.require(String.self)
            ))
        },
        ConstExprRegistration(
            name: "describeRegisteredStringLiteral",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [RegisteredStringLiteral.self],
            resultType: String.self
        ) { _, arguments in
            ConstExprValue(
                try arguments[0]!.require(RegisteredStringLiteral.self).value
            )
        },
    ])
    let source = "let value = describeRegisteredStringLiteral(\"library\")\n"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(result.diagnostics.map(\.code) == ["no-matching-overload"])
}
