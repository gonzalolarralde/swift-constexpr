import Testing
@testable import ConstExpr

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
