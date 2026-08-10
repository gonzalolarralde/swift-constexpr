import Testing
@testable import ConstExpr

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
