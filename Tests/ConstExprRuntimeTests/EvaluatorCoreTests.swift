import Testing
@testable import ConstExpr

private final class EvaluatorInvocationCounter: @unchecked Sendable {
    var value = 0
}

private func evaluatorTestRegistry(counter: EvaluatorInvocationCounter? = nil) -> ConstExprRegistry {
    struct Bar {
        let value: Int
    }
    struct Foo {
        let bar: Bar
    }

    return ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "foo",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter?.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        },
        ConstExprRegistration(
            name: "Bar",
            kind: .initializer,
            ownerType: Bar.self,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Bar.self
        ) { _, arguments in
            ConstExprValue(Bar(value: try arguments[0]!.require(Int.self)))
        },
        ConstExprRegistration(
            name: "build",
            kind: .instanceMethod,
            ownerType: Bar.self,
            resultType: String.self
        ) { receiver, _ in
            let bar = try receiver!.require(Bar.self)
            return ConstExprValue("Bar \(bar.value)")
        },
        ConstExprRegistration(
            name: "Foo",
            kind: .initializer,
            ownerType: Foo.self,
            resultType: Foo.self
        ) { _, _ in
            ConstExprValue(Foo(bar: Bar(value: 5)))
        },
        ConstExprRegistration(
            name: "bar",
            kind: .instanceProperty,
            ownerType: Foo.self,
            resultType: Bar.self
        ) { receiver, _ in
            ConstExprValue(try receiver!.require(Foo.self).bar)
        },
        ConstExprRegistration(
            name: "exampleAnswer",
            kind: .constant,
            resultType: Int.self
        ) { _, _ in
            ConstExprValue(42)
        },
        ConstExprRegistration(
            name: "total",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int].self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require([Int].self).reduce(0, +))
        },
    ])
}

@Test func evaluatorFoldsNestedRegisteredCallsAndOpaqueChains() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let result = runner.rewrite(source: "let result = Bar(foo(foo(5))).build()")

    #expect(result.source == "let result = \"Bar 7\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorCarriesOpaqueValuesThroughProperties() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let result = runner.rewrite(source: "let result = Foo().bar.build()")

    #expect(result.source == "let result = \"Bar 5\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorResolvesRegisteredConstantsAndCollectionArguments() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let result = runner.rewrite(source: """
        let values = [1, foo(1), 3]
        let answer = exampleAnswer + total(values)
        """)

    #expect(result.source == """
        let values = [1, 2, 3]
        let answer = 48
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPropagatesImmutableBindingsAndFoldsOperators() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let result = runner.rewrite(source: """
        let x = foo(1)
        let y = x * 3 + 1
        unknown(y)
        """)

    #expect(result.source == """
        let x = 2
        let y = 7
        unknown(7)
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorDoesNotPropagateMutableBindingsOrShadowedFunctions() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let result = runner.rewrite(source: """
        var x = foo(1)
        let a = x + 2
        func foo(_ value: Int) -> Int { value }
        let b = foo(3)
        """)

    #expect(result.source == """
        var x = foo(1)
        let a = x + 2
        func foo(_ value: Int) -> Int { value }
        let b = foo(3)
        """)
}

@Test func evaluatorExecutesEachRegisteredCallOnce() {
    let counter = EvaluatorInvocationCounter()

    let result = ConstExprRunner(registry: evaluatorTestRegistry(counter: counter))
        .rewrite(source: "let result = foo(foo(1))")

    #expect(result.source == "let result = 3")
    #expect(counter.value == 2)
}

@Test func evaluatorDiagnosesArithmeticFailuresAndPreservesSource() {
    let runner = ConstExprRunner(registry: .empty)
    let result = runner.rewrite(source: "let result = 4 / 0", fileName: "Input.swift")

    #expect(result.source == "let result = 4 / 0")
    #expect(result.diagnostics.map(\.code) == ["division-by-zero"])
    #expect(result.diagnostics.first?.fileName == "Input.swift")
}

@Test func evaluatorHonorsPrecedenceAndLazyBranches() {
    let counter = EvaluatorInvocationCounter()
    let runner = ConstExprRunner(registry: evaluatorTestRegistry(counter: counter))
    let result = runner.rewrite(source: """
        let precedence = 2 + 3 * 4
        let lazyAnd = false && foo(1) == 2
        let ternary = true ? 7 : foo(9)
        let unselectedTrap = true ? 7 : 1 / 0
        """)

    #expect(result.source == """
        let precedence = 14
        let lazyAnd = false
        let ternary = 7
        let unselectedTrap = 7
        """)
    #expect(counter.value == 0)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPreservesInternalCommentsAndIsIdempotent() {
    let runner = ConstExprRunner(registry: evaluatorTestRegistry())
    let first = runner.rewrite(source: "let value = foo(/* keep */ 1)")
    let second = runner.rewrite(source: first.source)

    #expect(first.source == "let value = foo(/* keep */ 1)")
    #expect(second.source == first.source)
}
