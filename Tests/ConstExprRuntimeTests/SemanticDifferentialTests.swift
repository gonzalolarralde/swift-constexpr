import Testing
@testable import ConstExpr

private class DifferentialBase {}
private final class DifferentialDerived: DifferentialBase {}
private struct DifferentialSubscriptBox {}
private struct Foo {}

private enum MySwift {
    struct Value {}
}

private final class DifferentialCounter: @unchecked Sendable {
    var factory = 0
    var fallback = 0
    var baseOverload = 0
    var derivedOverload = 0
    var invalid = 0
}

@Test func knownSomeNilCoalescingPreservesItsSwiftJoinWithoutInvokingTheFallback() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialDerived",
            kind: .function,
            resultType: DifferentialDerived?.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(Optional.some(DifferentialDerived()))
        },
        ConstExprRegistration(
            name: "makeDifferentialBase",
            kind: .function,
            resultType: DifferentialBase.self
        ) { _, _ in
            counter.fallback += 1
            return ConstExprValue(DifferentialBase())
        },
        ConstExprRegistration(
            name: "differentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self,
            declarationID: "differential-choice-base"
        ) { _, _ in
            counter.baseOverload += 1
            return ConstExprValue("base")
        },
        ConstExprRegistration(
            name: "differentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialDerived.self],
            resultType: String.self,
            declarationID: "differential-choice-derived"
        ) { _, _ in
            counter.derivedOverload += 1
            return ConstExprValue("derived")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = differentialChoice(makeDifferentialDerived() ?? makeDifferentialBase())"
    )

    #expect(result.source == "let value = \"base\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.fallback == 0)
    #expect(counter.baseOverload == 1)
    #expect(counter.derivedOverload == 0)
}

@Test func ternaryEvaluationPreservesItsSwiftJoinAndBranchLaziness() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeTernaryDerived",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "makeTernaryBase",
            kind: .function,
            resultType: DifferentialBase.self
        ) { _, _ in
            counter.fallback += 1
            return ConstExprValue(DifferentialBase())
        },
        ConstExprRegistration(
            name: "ternaryDifferentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self,
            declarationID: "ternary-differential-choice-base"
        ) { _, _ in
            counter.baseOverload += 1
            return ConstExprValue("base")
        },
        ConstExprRegistration(
            name: "ternaryDifferentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialDerived.self],
            resultType: String.self,
            declarationID: "ternary-differential-choice-derived"
        ) { _, _ in
            counter.derivedOverload += 1
            return ConstExprValue("derived")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let selectedDerived = ternaryDifferentialChoice(
            true ? makeTernaryDerived() : makeTernaryBase()
        )
        let selectedBase = ternaryDifferentialChoice(
            false ? makeTernaryDerived() : makeTernaryBase()
        )
        """)

    #expect(result.source == """
        let selectedDerived = "base"
        let selectedBase = "base"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.fallback == 1)
    #expect(counter.baseOverload == 2)
    #expect(counter.derivedOverload == 0)
}

@Test func explicitlyErasedCollectionBindingsNeverNarrowFromTheirPayloads() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "acceptDifferentialInts",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int].self],
            resultType: String.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("invalidly narrowed")
        }
    )

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let populated: [Any] = [1]
        let empty: [Any] = []
        let populatedResult = acceptDifferentialInts(populated)
        let emptyResult = acceptDifferentialInts(empty)
        """)

    #expect(counter.invalid == 0)
    #expect(result.source.contains("acceptDifferentialInts(([1]) as [Any])"))
    #expect(result.source.contains("acceptDifferentialInts(([]) as [Any])"))
    #expect(!result.source.contains("invalidly narrowed"))
    #expect(result.diagnostics.map(\.code) == [
        "no-matching-overload",
        "no-matching-overload",
    ])
}

private func hiddenContextRegistry(counter: DifferentialCounter) -> ConstExprRegistry {
    ConstExprRegistry(
        ConstExprRegistration(
            name: "differentialByte",
            kind: .function,
            resultType: UInt8.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue(UInt8(1))
        }
    )
}

@Test func implicitClosureResultContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        let folded: () -> UInt8 = { 255 &+ 1 }
        let invoked: () -> UInt8 = { differentialByte() }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func propertyWrapperInitializerContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        @propertyWrapper
        struct DifferentialByteWrapper {
            var wrappedValue: UInt8
        }
        struct DifferentialWrappedValues {
            @DifferentialByteWrapper var folded = 255 &+ 1
            @DifferentialByteWrapper var invoked = differentialByte()
        }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func resultBuilderExpressionContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        @resultBuilder
        enum DifferentialByteBuilder {
            static func buildExpression(_ value: UInt8) -> UInt8 { value }
            static func buildBlock(_ value: UInt8) -> UInt8 { value }
        }
        func buildDifferentialByte(
            @DifferentialByteBuilder _ body: () -> UInt8
        ) -> UInt8 {
            body()
        }
        let folded = buildDifferentialByte { 255 &+ 1 }
        let invoked = buildDifferentialByte { differentialByte() }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func subjectTypedPatternExpressionsRemainOpaque() {
    let source = """
        let byte: UInt8 = 0
        switch byte {
        case 255 &+ 1:
            break
        default:
            break
        }
        if case 255 &+ 1 = byte {
            consume(byte)
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source.contains("case 255 &+ 1:"))
    #expect(result.source.contains("if case 255 &+ 1 = byte"))
    #expect(!result.source.contains("case 256:"))
    #expect(!result.source.contains("if case 256 = byte"))
    #expect(result.diagnostics.isEmpty)
}

@Test func customStringInterpolationArgumentContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = #"""
        struct DifferentialByteString: ExpressibleByStringInterpolation {
            struct StringInterpolation: StringInterpolationProtocol {
                init(literalCapacity: Int, interpolationCount: Int) {}
                mutating func appendLiteral(_ literal: String) {}
                mutating func appendInterpolation(_ value: UInt8) {}
            }
            init(stringLiteral value: String) {}
            init(stringInterpolation: StringInterpolation) {}
        }
        let folded: DifferentialByteString = "\(255 &+ 1)"
        let invoked: DifferentialByteString = "\(differentialByte())"
        """#

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func explicitBindingAndCastUpcastsPreserveAUsableConstantValue() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialConcrete",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "acceptDifferentialBase",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self
        ) { _, arguments in
            counter.baseOverload += 1
            _ = try arguments[0]!.require(DifferentialBase.self)
            return ConstExprValue("base")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let annotated: DifferentialBase = makeDifferentialConcrete()
        let throughBinding = acceptDifferentialBase(annotated)
        let throughCast = acceptDifferentialBase(makeDifferentialConcrete() as DifferentialBase)
        """)

    #expect(result.source == """
        let annotated: DifferentialBase = makeDifferentialConcrete()
        let throughBinding = "base"
        let throughCast = "base"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.baseOverload == 2)
}

@Test func registeredBaseMemberIsAvailableOnAStaticallyDerivedReceiver() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialConcrete",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "inheritedDifferentialValue",
            kind: .instanceMethod,
            ownerType: DifferentialBase.self,
            resultType: String.self
        ) { receiver, _ in
            counter.baseOverload += 1
            _ = try receiver!.require(DifferentialBase.self)
            return ConstExprValue("inherited")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = makeDifferentialConcrete().inheritedDifferentialValue()"
    )

    #expect(result.source == "let value = \"inherited\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.baseOverload == 1)
}

@Test func unqualifiedBuiltinTypeShadowsRemainOpaqueToEvaluation() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "+++",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Int.self, Swift.Int.self],
            resultType: Swift.Int.self,
            precedenceGroup: "AdditionPrecedence"
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue(Swift.Int(999))
        }
    )
    let source = """
        infix operator +++: AdditionPrecedence
        struct Int: ExpressibleByIntegerLiteral {
            typealias IntegerLiteralType = Swift.Int
            let rawValue: Swift.Int
            init(integerLiteral value: Swift.Int) {
                rawValue = value
            }
        }
        func +++ (lhs: Int, rhs: Int) -> Int { lhs }
        func consumeShadow<T>(_ value: T) {}
        let shadowed: Int = 1
        consumeShadow(shadowed +++ 1)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func unqualifiedOptionalAndArrayShadowsRemainOpaqueToEvaluation() {
    let source = """
        struct Optional<Wrapped>: ExpressibleByNilLiteral {
            init(nilLiteral: ()) {}
        }
        struct Array<Element>: ExpressibleByArrayLiteral {
            init(arrayLiteral elements: Element...) {}
        }
        func consumeShadow<T>(_ value: T) {}
        let optional: Optional<Swift.Int> = nil
        let array: Array<Swift.Int> = [1]
        consumeShadow(optional)
        consumeShadow(array)
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func sourceOperatorsOverloadedByResultTypeAreNotBypassedByBuiltins() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "+",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Int.self, Swift.Int.self],
            resultType: Swift.String.self,
            precedenceGroup: "AdditionPrecedence"
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom plus")
        },
        ConstExprRegistration(
            name: "??",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Int?.self, Swift.Int.self],
            resultType: Swift.String.self,
            precedenceGroup: "NilCoalescingPrecedence",
            associativity: .right
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom coalesce")
        },
    ])
    let source = """
        func + (lhs: Swift.Int, rhs: Swift.Int) -> Swift.String {
            "custom plus"
        }
        func ?? (
            lhs: Swift.Int?,
            rhs: @autoclosure () -> Swift.Int
        ) -> Swift.String {
            "custom coalesce"
        }
        func contextualPlusImplicit() -> Swift.String {
            1 + 2
        }
        func contextualPlusExplicit() -> Swift.String {
            return 1 + 2
        }
        func contextualCoalesceImplicit() -> Swift.String {
            (1 as Swift.Int?) ?? 2
        }
        let plus: Swift.String = 1 + 2
        let coalesce: Swift.String = (1 as Swift.Int?) ?? 2
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source.contains("""
        func contextualPlusImplicit() -> Swift.String {
            1 + 2
        }
        """))
    #expect(result.source.contains("""
        func contextualPlusExplicit() -> Swift.String {
            return 1 + 2
        }
        """))
    #expect(result.source.contains("""
        func contextualCoalesceImplicit() -> Swift.String {
        """))
    #expect(result.source.contains("?? 2"))
    #expect(result.source.contains("let plus: Swift.String = 1 + 2"))
    #expect(result.source.contains("let coalesce: Swift.String ="))
    #expect(!result.source.contains("contextualPlusImplicit() -> Swift.String {\n    3"))
    #expect(!result.source.contains("contextualPlusExplicit() -> Swift.String {\n    return 3"))
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func sourceShortCircuitOperatorsOverloadedByResultTypeRemainOpaque() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "&&",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Bool.self, Swift.Bool.self],
            resultType: Swift.String.self,
            precedenceGroup: "LogicalConjunctionPrecedence",
            associativity: .left
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom and")
        },
        ConstExprRegistration(
            name: "||",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Bool.self, Swift.Bool.self],
            resultType: Swift.String.self,
            precedenceGroup: "LogicalDisjunctionPrecedence",
            associativity: .left
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom or")
        },
    ])
    let source = """
        func && (
            lhs: Swift.Bool,
            rhs: @autoclosure () -> Swift.Bool
        ) -> Swift.String {
            "custom and"
        }
        func || (
            lhs: Swift.Bool,
            rhs: @autoclosure () -> Swift.Bool
        ) -> Swift.String {
            "custom or"
        }
        func contextualAnd() -> Swift.String {
            false && true
        }
        func contextualOr() -> Swift.String {
            true || false
        }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func sourceSubscriptsOverloadedByResultTypeAreNotBypassedByBuiltins() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: [Swift.Int].self,
            parameterLabels: [nil],
            parameterTypes: [Swift.Int.self],
            resultType: Swift.String.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom array")
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: [Swift.Int: Swift.Int].self,
            parameterLabels: [nil],
            parameterTypes: [Swift.Int.self],
            resultType: Swift.String.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("custom dictionary")
        },
    ])
    let source = """
        extension Swift.Array {
            subscript(index: Swift.Int) -> Swift.String {
                "custom array"
            }
        }
        extension Swift.Dictionary where Key == Swift.Int, Value == Swift.Int {
            subscript(index: Swift.Int) -> Swift.String {
                "custom dictionary"
            }
        }
        func contextualArraySubscript() -> Swift.String {
            [1][0]
        }
        func contextualDictionarySubscript() -> Swift.String {
            return [1: 2][1]
        }
        let array: Swift.String = [1][0]
        let dictionary: Swift.String = [1: 2][1]
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func registeredSubscriptArgumentsReceiveTheirDeclaredParameterContext() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialSubscriptBox",
            kind: .function,
            resultType: DifferentialSubscriptBox.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialSubscriptBox())
        },
        ConstExprRegistration(
            name: "subscript",
            kind: .subscriptGetter,
            ownerType: DifferentialSubscriptBox.self,
            parameterLabels: [nil],
            parameterTypes: [UInt8.self],
            resultType: String.self
        ) { _, arguments in
            counter.baseOverload += 1
            let index = try arguments[0]!.require(UInt8.self)
            return ConstExprValue(index == 0 ? "zero" : "wrong")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = makeDifferentialSubscriptBox()[255 &+ 1]"
    )

    #expect(result.source == "let value = \"zero\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.baseOverload == 1)
}

@Test func nonIdentifierAssignmentTargetsKeepTheirHiddenRHSContext() {
    let source = """
        struct DifferentialAssignmentBox {
            var byte: UInt8
        }
        var box = DifferentialAssignmentBox(byte: 0)
        box.byte = 255 &+ 1
        box.byte &+= 255 &+ 1
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func computedPropertyAccessorsReceiveTheirDeclaredResultContext() {
    let source = """
        struct DifferentialComputedProperties {
            var implicit: UInt8 {
                255 &+ 1
            }
            var explicit: UInt8 {
                get {
                    return 255 &+ 1
                }
            }
            var read: UInt8 {
                _read {
                    yield 255 &+ 1
                }
            }
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == """
        struct DifferentialComputedProperties {
            var implicit: UInt8 {
                (0) as Swift.UInt8
            }
            var explicit: UInt8 {
                get {
                    return (0) as Swift.UInt8
                }
            }
            var read: UInt8 {
                _read {
                    yield (0) as Swift.UInt8
                }
            }
        }
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func unknownInfixSiblingsDoNotDefaultPolymorphicLiteralOperands() {
    let source = """
        struct DifferentialUnknownOperandBox {
            var byte: UInt8
        }
        var box = DifferentialUnknownOperandBox(byte: 0)
        if 255 &+ 1 == box.byte {
            consume(box)
        }
        if box.byte == 255 &+ 1 {
            consume(box)
        }
        let sum = box.byte + (255 &+ 1)
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func conditionAndLoopPatternsPreserveTheirHiddenTypeContext() {
    let source = """
        func consumePatternByte(_ value: UInt8) {}
        if let byte: UInt8 = Optional(255 &+ 1) {
            consumePatternByte(byte)
        }
        func guardedPatternByte() {
            guard let byte: UInt8 = Optional(255 &+ 1) else {
                return
            }
            consumePatternByte(byte)
        }
        for byte: UInt8 in [255 &+ 1] {
            consumePatternByte(byte)
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func repeatLoopsDoNotExecuteRegisteredCallsDuringRewriting() {
    let counter = DifferentialCounter()
    let source = """
        func consumeRepeatedByte(_ value: UInt8) {}
        repeat {
            consumeRepeatedByte(differentialByte())
        } while false
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func swiftModuleNormalizationDoesNotAlterUserNamespaceSubstrings() {
    let descriptor: ConstExprStaticTypeDescriptor = .optional(
        .leaf(
            type: MySwift.Value.self,
            sourceName: "MySwift.Value",
            isExistential: false,
            isClassBound: false,
            acceptsSourceType: nil
        )
    )
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "makeMySwiftOptional",
            kind: .function,
            resultType: MySwift.Value?.self,
            resultTypeDescriptor: descriptor
        ) { _, _ in
            ConstExprValue(
                Optional<MySwift.Value>.none as Any,
                preservingStaticType: MySwift.Value?.self,
                sourceTypeName: "MySwift.Value?"
            )
        }
    )

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = makeMySwiftOptional()"
    )

    #expect(result.source == "let value = nil as MySwift.Value?")
    #expect(result.diagnostics.isEmpty)
}

@Test func localNominalNamesDoNotSuffixMatchUnrelatedRegisteredTypes() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeShadowFoo",
            kind: .function,
            resultType: Foo.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(Foo())
        },
        ConstExprRegistration(
            name: "acceptShadowFoo",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Foo.self],
            resultType: String.self
        ) { _, _ in
            counter.baseOverload += 1
            return ConstExprValue("unrelated external Foo")
        },
    ])
    let source = """
        struct Foo {}
        let value: Foo = makeShadowFoo()
        let accepted = acceptShadowFoo(value)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 0)
    #expect(counter.baseOverload == 0)
}

@Test func genericParameterNamesThatShadowBuiltinsRemainOpaque() {
    let source = """
        func consumeGenericShadow<T>(_ value: T) {}
        func genericShadow<Int: ExpressibleByIntegerLiteral>(_ type: Int.Type) {
            let value: Int = 1
            consumeGenericShadow(value)
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func associatedTypeNamesThatShadowBuiltinsRemainOpaque() {
    let source = """
        protocol DifferentialAssociatedInteger {
            associatedtype Int: FixedWidthInteger
            func byte() -> Int
        }
        extension DifferentialAssociatedInteger {
            func byte() -> Int {
                255 &+ 1
            }
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func aLocalTypeNamedSwiftPreventsStdlibQualifierNormalization() {
    let source = """
        typealias DifferentialStdlibInt = Swift.Int
        func consumeSwiftShadow<T>(_ value: T) {}
        func useSwiftShadow() {
            enum Swift {
                struct Int: ExpressibleByIntegerLiteral {
                    typealias IntegerLiteralType = DifferentialStdlibInt
                    init(integerLiteral value: DifferentialStdlibInt) {}
                }
            }
            let value: Swift.Int = 1
            consumeSwiftShadow(value)
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}
