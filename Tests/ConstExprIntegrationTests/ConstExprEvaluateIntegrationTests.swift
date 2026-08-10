import ConstExprEvaluateExample
import ConstExprExampleDefinitions
import Testing

@Test func companionEvaluateMacroWorksInCompilerTypeChecking() {
    let folded: Int = #evaluate {
        let input = 41
        return foo(input)
    }
    #expect(folded == 42)
}

@Test func companionEvaluateMacroFallsBackToConsumerScope() {
    let runtimeValue = 9
    let evaluated: Int = #evaluate { foo(runtimeValue) }
    #expect(evaluated == 10)
}

@Test func companionEvaluateMacroLeavesContextualOverloadsToTheCompiler() {
    let evaluated: Int = #evaluate { typedValue() }
    #expect(evaluated == 7)
}
