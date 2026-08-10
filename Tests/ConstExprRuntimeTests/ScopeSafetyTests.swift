import Testing
@testable import ConstExpr

private let scopeRegistry = ConstExprRegistry(registrations: [
    ConstExprRegistration(
        name: "increment",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(Int.self) + 1)
    },
])

private func rewriteScopes(_ source: String) -> ConstExprRewriteResult {
    ConstExprRunner(registry: scopeRegistry).rewrite(source: source)
}

@Test func nestedBlocksShadowAndRestoreImmutableConstants() {
    let result = rewriteScopes("""
        let value = 1
        do {
            let value = 2
            unknown(value)
        }
        unknown(value)
        """)

    #expect(result.source == """
        let value = 1
        do {
            let value = 2
            unknown(2)
        }
        unknown(1)
        """)
}

@Test func functionAndClosureParametersShadowOuterConstants() {
    let result = rewriteScopes("""
        let value = 1
        func consume(value: Int) {
            unknown(value)
        }
        let closure = { value in unknown(value) }
        unknown(value)
        """)

    #expect(result.source == """
        let value = 1
        func consume(value: Int) {
            unknown(value)
        }
        let closure = { value in unknown(value) }
        unknown(1)
        """)
}

@Test func mutableInitializersFoldButMutableReferencesNeverPropagate() {
    let result = rewriteScopes("""
        var value = increment(1)
        let result = value + 1
        """)

    #expect(result.source == """
        var value = 2
        let result = value + 1
        """)
}

@Test func nominalStoredPropertiesDoNotLeakIntoLexicalScope() {
    let result = rewriteScopes("""
        let value = 1
        struct Container {
            let value = 2
            func read() -> Int { value }
        }
        unknown(value)
        """)

    #expect(result.source == """
        let value = 1
        struct Container {
            let value = 2
            func read() -> Int { value }
        }
        unknown(1)
        """)
}

@Test func loopCatchAndCaptureBindingsConservativelyShadowOuterConstants() {
    let result = rewriteScopes("""
        let item = 7
        for item in values {
            unknown(item)
        }
        do {
            work()
        } catch let item {
            unknown(item)
        }
        let closure = { [item = make()] in unknown(item) }
        unknown(item)
        """)

    #expect(result.source == """
        let item = 7
        for item in values {
            unknown(item)
        }
        do {
            work()
        } catch let item {
            unknown(item)
        }
        let closure = { [item = make()] in unknown(item) }
        unknown(7)
        """)
}

@Test func unsupportedDestructuringStillShadowsEveryIntroducedName() {
    let result = rewriteScopes("""
        let left = 10
        let right = 20
        do {
            let (left, right) = pair()
            unknown(left, right)
        }
        unknown(left, right)
        """)

    #expect(result.source == """
        let left = 10
        let right = 20
        do {
            let (left, right) = pair()
            unknown(left, right)
        }
        unknown(10, 20)
        """)
}
