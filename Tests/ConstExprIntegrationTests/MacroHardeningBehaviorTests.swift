import ConstExpr
import Foundation
import Testing

@Test func hardenedMacroPeersCompileAndRegisterAllSupportedShapes() {
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "macroHygieneFixture"
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "existentialFixture"
            && registration.parameterTypes.first == (any MacroExistentialFixture).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "replacing"
            && registration.resultType == MacroNominalFixture.self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "makeOptionalRenderableExistentialFixture"
            && registration.resultType == ((any CustomStringConvertible)?).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "makeRenderableExistentialArrayFixture"
            && registration.resultType == ([any CustomStringConvertible]).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "routed" && registration.parameterLabels == ["repeat"]
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "repeat"
            && registration.ownerType == `struct`.self
    })
    let arrayLiteralRegistration = macroHardeningRegistry.registrations.first { registration in
        registration.kind == .arrayLiteral
            && registration.resultType == MacroArrayLiteralFixture.self
    }
    #expect(arrayLiteralRegistration?.arrayLiteralElementType == Int.self)
    #expect(arrayLiteralRegistration?.maximumArrayLiteralElementCount == 32)
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.ownerType == AvailableMacroFixture.self
    })
}
@Test func generatedArrayLiteralRegistrationCompilesAndEvaluatesNestedMembers() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let total: Int = ([1, 2, 3] as MacroArrayLiteralFixture).sum()"
    )

    #expect(result.source == "let total: Int = 6")
    #expect(result.diagnostics.isEmpty)
}

@Test func customGlobalActorAttributesAreRejectedBeforePeerEmission() throws {
    let compilation = try compileCustomGlobalActorFixture()

    #expect(compilation.0 != 0)
    #expect(
        compilation.1.contains(
            "declaration attribute @Isolation may impose isolation or semantic transforms that @ConstExpr cannot prove safe; use manual registration"
        )
    )
    #expect(!compilation.1.contains("call to global actor-isolated"))
}

@Test func shadowedArrayLiteralProtocolUsesNonconformingProbeOverload() throws {
    let compilation = try compileShadowedArrayLiteralProtocolFixture()

    #expect(compilation.0 == 0)
    #expect(compilation.1.isEmpty)
}


@Test func generatedExistentialResultsFlowIntoExistentialParameters() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let value = existentialFixture(makeExistentialFixture())"
    )

    #expect(result.source == "let value = \"existential\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedClassBoundExistentialResultsSelectAnyObjectOnlyWhenValid() throws {
    let classFactory = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "makeClassMarkerFixture"
        }
    )
    let valueFactory = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "makeValueMarkerFixture"
        }
    )
    #expect(try classFactory.invoke().isStaticallyAnyObject)
    #expect(try !valueFactory.invoke().isStaticallyAnyObject)

    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let classBound = classifyMarkerFixture(makeClassMarkerFixture())
            let unconstrained = classifyMarkerFixture(makeValueMarkerFixture())
            """
    )

    #expect(result.source == """
        let classBound = "anyObject"
        let unconstrained = "any"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedRecursiveExistentialDescriptorsPreserveStaticConversions() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let classOptional = classifyOptionalMarkerFixture(makeOptionalClassMarkerFixture())
            let valueOptional = classifyOptionalMarkerFixture(makeOptionalValueMarkerFixture())
            let classArray = classifyMarkerArrayFixture(makeClassMarkerArrayFixture())
            let valueArray = classifyMarkerArrayFixture(makeValueMarkerArrayFixture())
            let protocolBase = consumeValueMarkerFixture(makeBaseMarkerFixture())
            """
    )

    #expect(result.source == """
        let classOptional = "optionalAnyObject"
        let valueOptional = "optionalAny"
        let classArray = "arrayAnyObject"
        let valueArray = "arrayAny"
        let protocolBase = "protocol"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedNonclassProtocolAndAnyObjectAmbiguityNeverExecutes() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let value = ambiguousMarkerFixture(makeBaseMarkerFixture())"
    )

    #expect(result.source == "let value = ambiguousMarkerFixture(makeBaseMarkerFixture())")
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
    #expect(macroDescriptorInvocationCounter.value == 0)
}

@Test func generatedDescriptorsRecurseThroughGenericAndSugarContainers() throws {
    let registration = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "recursiveDescriptorFixture"
        }
    )

    func shape(_ descriptor: _ConstExprRuntime.StaticTypeDescriptor) -> String {
        switch descriptor {
        case .leaf(_, let sourceName, let existential, let classBound, let accepts):
            return "leaf(\(sourceName ?? "nil"),\(existential),\(classBound),\(accepts != nil))"
        case .optional(let wrapped):
            return "optional(\(shape(wrapped)))"
        case .array(let element):
            return "array(\(shape(element)))"
        case .set(let element):
            return "set(\(shape(element)))"
        case .dictionary(let key, let value):
            return "dictionary(\(shape(key)),\(shape(value)))"
        case .tuple(let elements):
            return "tuple(\(elements.map(shape).joined(separator: ",")))"
        }
    }

    #expect(registration.parameterTypeDescriptors.map(shape) == [
        "optional(leaf(any MacroValueMarker,true,false,true))",
        "array(leaf(any MacroValueMarker,true,false,true))",
        "dictionary(leaf(String,false,false,false),leaf(any MacroValueMarker,true,false,true))",
        "tuple(leaf(any MacroValueMarker,true,false,true),array(leaf(any MacroClassMarker,true,true,true)))",
    ])
    #expect(
        shape(registration.resultTypeDescriptor)
            == "dictionary(leaf(String,false,false,false),optional(leaf(any MacroValueMarker,true,false,true)))"
    )
}

@Test func generatedErasedResultsMaterializeWithoutChangingTheirStaticTypes() throws {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let anyValue = makeAnyFixture()
            let optionalAny = makeOptionalAnyFixture()
            let existential = makeRenderableExistentialFixture()
            let optionalExistential = makeOptionalRenderableExistentialFixture()
            let existentialArray = makeRenderableExistentialArrayFixture()
            """
    )

    #expect(result.source == """
        let anyValue = ((7) as Any)
        let optionalAny = ((nil as Swift.Optional<Swift.Int>) as Any)
        let existential = ((8) as any CustomStringConvertible)
        let optionalExistential = (9) as (any CustomStringConvertible)?
        let existentialArray = ([10, "eleven"]) as [any CustomStringConvertible]
        """)
    #expect(result.diagnostics.isEmpty)

    let typecheck = try typecheckRewrittenFixture(result.source + """

        func classifyAny(_ value: Int) -> Int { value }
        func classifyAny(_ value: Any) -> String { "any" }
        func classifyExistential(_ value: Int) -> Int { value }
        func classifyExistential(_ value: any CustomStringConvertible) -> String { "existential" }
        func classifyOptionalExistential(_ value: Int?) -> Int { value ?? 0 }
        func classifyOptionalExistential(_ value: (any CustomStringConvertible)?) -> String { "optional existential" }
        func classifyExistentialArray(_ value: [Int]) -> Int { value.count }
        func classifyExistentialArray(_ value: [any CustomStringConvertible]) -> String { "existential array" }
        let anyProof: String = classifyAny(anyValue)
        let optionalAnyProof: String = classifyAny(optionalAny)
        let existentialProof: String = classifyExistential(existential)
        let optionalExistentialProof: String = classifyOptionalExistential(optionalExistential)
        let existentialArrayProof: String = classifyExistentialArray(existentialArray)
        """)
    #expect(typecheck.0 == 0)
    #expect(typecheck.1.isEmpty)
}
