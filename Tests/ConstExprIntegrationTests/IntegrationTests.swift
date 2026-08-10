import ConstExpr
import ConstExprExampleDefinitions
import ConstExprExampleRegistry
import Testing

private func rewrite(_ source: String) -> ConstExprRewriteResult {
    ConstExprRunner(registry: exampleConstExprRegistry).rewrite(
        source: source,
        fileName: "Integration.swift"
    )
}

@Test func originalNestedCallAndTypeChain() {
    let result = rewrite("""
        let result = Bar(foo(foo(5))).build()
        """)

    #expect(result.source == """
        let result = "Bar 7"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func opaquePropertyChainOnlyMaterializesTheTerminalValue() {
    let result = rewrite("""
        let result = Foo().bar.blah()
        """)

    #expect(result.source == """
        let result = "5"
        """)
}

@Test func immutableReferencesAndOperatorPrecedencePropagate() {
    let result = rewrite("""
        let base = 1 + 2 * 3
        let result = foo(base)
        """)

    #expect(result.source == """
        let base = 7
        let result = 8
        """)
}

@Test func unknownOuterCallStillReceivesFoldedChildren() {
    let result = rewrite("""
        let result = unknown(foo(1))
        """)

    #expect(result.source == """
        let result = unknown(2)
        """)
}

@Test func nonTrailingDefaultsAreInvokedBySwift() {
    let result = rewrite("""
        let result = describe(number: 3)
        """)

    #expect(result.source == """
        let result = "value: 3"
        """)
}

@Test func overloadsResolveFromConstantArgumentTypes() {
    let result = rewrite("""
        let integer = transform(2)
        let string = transform("two")
        """)

    #expect(result.source == """
        let integer = "int:2"
        let string = "string:two"
        """)
}

@Test func collectionArgumentsDecodeRecursively() {
    let result = rewrite("""
        let values = [1, 2, 3]
        let result = total(values)
        """)

    #expect(result.source == """
        let values = [1, 2, 3]
        let result = 6
        """)
}

@Test func registeredGlobalConstantsCanBeSubstituted() {
    let result = rewrite("""
        let result = exampleAnswer + 1
        """)

    #expect(result.source == """
        let result = 43
        """)
}

@Test func generatedEnumCaseAdaptersCarryAssociatedValuesThroughMethods() {
    let result = rewrite("""
        let result = ExampleStatus.code(7).message()
        """)

    #expect(result.source == """
        let result = "code:7"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedClassAndSubscriptAdaptersPreserveTerminalTypes() {
    let result = rewrite("""
        let uppercased = ExampleBox("hello").uppercased()
        let character = ExampleBox("hello")[1]
        """)

    #expect(result.source == """
        let uppercased = "HELLO"
        let character = ("e") as Swift.Character
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func opaqueValuesRemainAvailableAcrossImmutableBindings() {
    let result = rewrite("""
        let box = ExampleBox("hello")
        let result = box.uppercased()
        """)

    #expect(result.source == """
        let box = ExampleBox("hello")
        let result = "HELLO"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func failableInitializersAndOptionalChainsPreserveOptionalResultTypes() {
    let result = rewrite("""
        let present = FailableValue(3)?.rendered()
        let absent = FailableValue(-1)?.rendered()
        """)

    #expect(result.source == """
        let present = ("value:3") as String?
        let absent = nil as String?
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func labelOnlyFreeFunctionOverloadsCompileAndResolveThroughGeneratedSelectors() {
    let result = rewrite("""
        let x = route(x: 1)
        let y = route(y: 2)
        """)

    #expect(result.source == """
        let x = "x:1"
        let y = "y:2"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func dictionaryLiteralsDecodeThroughGeneratedAdapters() {
    let result = rewrite("""
        let values = ["b": 2, "a": 1]
        let result = dictionarySummary(values)
        """)

    #expect(result.source == """
        let values = ["b": 2, "a": 1]
        let result = "a=1,b=2"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedResultsRenderWithoutChangingTheirStaticSwiftTypes() {
    let result = rewrite("""
        let integer = int64Value()
        let floating = floatValue()
        let character = characterValue()
        let some = optionalValue(true)
        let none = optionalValue(false)
        """)

    #expect(result.source == """
        let integer = (5) as Swift.Int64
        let floating = (1.5) as Swift.Float
        let character = ("x") as Swift.Character
        let some = (5) as Int?
        let none = nil as Int?
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func explicitBindingAnnotationsDriveLiteralConversionAndReturnOverloads() {
    let result = rewrite("""
        let integer: Int64 = 1
        let floating: Float = 1.25
        let character: Character = "z"
        let integerResult = acceptsInt64(integer)
        let floatResult = acceptsFloat(floating)
        let characterResult = acceptsCharacter(character)
        let selected: String = typedValue()
        """)

    #expect(result.source == """
        let integer: Int64 = (1) as Swift.Int64
        let floating: Float = (1.25) as Swift.Float
        let character: Character = ("z") as Swift.Character
        let integerResult = "int64:1"
        let floatResult = "float:1.25"
        let characterResult = "character:z"
        let selected: String = "seven"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func throwingGeneratedAdaptersReportFailuresAndFoldSuccesses() {
    let result = rewrite("""
        let success = try throwingValue(true)
        let failure = try throwingValue(false)
        """)

    #expect(result.source == """
        let success = "success"
        let failure = try throwingValue(false)
        """)
    #expect(result.diagnostics.map(\.code) == ["evaluation-threw"])
}

@Test func generatedStaticMembersCanParticipateInLongerOpaqueChains() {
    let result = rewrite("""
        let answer = Foo.answer + 1
        let leaf = Foo.makeLeaf().blah()
        """)

    #expect(result.source == """
        let answer = 43
        let leaf = "5"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func partialMemberRewritesParenthesizeGrammarSensitiveConstantBases() {
    let result = rewrite("""
        let negative = foo(-2).description
        let integer = int64Value().description
        let character = characterValue().description
        """)

    #expect(result.source == """
        let negative = (-1).description
        let integer = ((5) as Swift.Int64).description
        let character = (("x") as Swift.Character).description
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func qualifiedStaticOwnerMatchingDoesNotUseAnUnrelatedBasename() {
    let result = rewrite("""
        let unrelated = Bogus.Foo.answer
        let actual = ConstExprExampleDefinitions.Foo.answer
        """)

    #expect(result.source == """
        let unrelated = Bogus.Foo.answer
        let actual = 42
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func publicProvidersDoNotExportLessVisibleMembersAcrossModules() {
    #expect(exampleConstExprRegistry.registrations.contains { registration in
        registration.ownerType == Bar.self && registration.name == "build"
    })
    #expect(!exampleConstExprRegistry.registrations.contains { registration in
        registration.ownerType == Bar.self
            && registration.name == "internalVisibilityFixture"
    })
    #expect(!exampleConstExprRegistry.registrations.contains { registration in
        registration.ownerType == Bar.self
            && registration.name == "spiVisibilityFixture"
    })
}
