import Testing
@testable import ConstExpr

protocol DescriptorValueProtocol {}
protocol DescriptorClassProtocol: AnyObject {}

class DescriptorBase: DescriptorValueProtocol {}
final class DescriptorDerived: DescriptorBase {}
final class DescriptorBoth: DescriptorValueProtocol, DescriptorClassProtocol {}

class DescriptorUnrelatedBase {}
final class DescriptorDynamicConformer: DescriptorUnrelatedBase, DescriptorValueProtocol {}

let descriptorValueExistential: ConstExprStaticTypeDescriptor = .leaf(
    type: (any DescriptorValueProtocol).self,
    sourceName: "any DescriptorValueProtocol",
    isExistential: true,
    isClassBound: false,
    acceptsSourceType: { $0 is any DescriptorValueProtocol.Type }
)

let descriptorClassExistential: ConstExprStaticTypeDescriptor = .leaf(
    type: (any DescriptorClassProtocol).self,
    sourceName: "any DescriptorClassProtocol",
    isExistential: true,
    isClassBound: true,
    acceptsSourceType: { $0 is any DescriptorClassProtocol.Type }
)

func descriptorLeaf(
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
