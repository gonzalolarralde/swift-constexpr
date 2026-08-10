import ConstExpr
import Foundation
import Testing

@Test func tryQuestionMarkMayFoldInsideAnInferredNonthrowingClosure() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialHandledThrow",
            kind: .function,
            resultType: String.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue("success")
        }
    )
    let source = """
        let closure = { try? compilerDifferentialHandledThrow() }
        print(closure() as Any)
        """
    let support = """
        func compilerDifferentialHandledThrow() throws -> String {
            "success"
        }
        """

    let original = try compilerDifferentialRun(support: support, source: source)
    let result = ConstExprRunner(registry: registry).rewrite(source: source)
    let rewritten = try compilerDifferentialRun(
        support: support,
        source: result.source
    )

    #expect(original.status == 0)
    #expect(original.error.isEmpty)
    #expect(result.source == """
        let closure = { ("success") as String? }
        print(closure() as Any)
        """)
    #expect(counter.value == 1)
    #expect(rewritten.status == 0)
    #expect(rewritten.output == original.output)
    #expect(rewritten.error.isEmpty)
}

@Test func locallyHandledTryRemainsFoldableAcrossDeclarationContexts() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialLocallyHandledThrow",
            kind: .function,
            resultType: Int.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(7)
        }
    )
    let source = """
        struct CompilerDifferentialHandledEffects {
            let value: Int?
            init() {
                value = try? compilerDifferentialLocallyHandledThrow()
            }
            var shorthand: Int? {
                try? compilerDifferentialLocallyHandledThrow()
            }
            var explicit: Int? {
                get {
                    try? compilerDifferentialLocallyHandledThrow()
                }
            }
        }
        func compilerDifferentialHandledDefault(
            _ value: Int? = try? compilerDifferentialLocallyHandledThrow()
        ) throws -> Int? {
            value
        }
        """
    let support = """
        func compilerDifferentialLocallyHandledThrow() throws -> Int {
            7
        }
        """

    let originalTypecheck = try compilerDifferentialTypecheck(
        support: support,
        source: source
    )
    let result = ConstExprRunner(registry: registry).rewrite(source: source)
    let rewrittenTypecheck = try compilerDifferentialTypecheck(
        support: support,
        source: result.source
    )

    #expect(originalTypecheck.status == 0)
    #expect(originalTypecheck.error.isEmpty)
    #expect(result.source == """
        struct CompilerDifferentialHandledEffects {
            let value: Int?
            init() {
                value = ((7) as Int?)
            }
            var shorthand: Int? {
                (7) as Int?
            }
            var explicit: Int? {
                get {
                    (7) as Int?
                }
            }
        }
        func compilerDifferentialHandledDefault(
            _ value: Int? = (7) as Int?
        ) throws -> Int? {
            value
        }
        """)
    #expect(counter.value == 4)
    #expect(rewrittenTypecheck.status == 0)
    #expect(rewrittenTypecheck.error.isEmpty)
}

@Test func throwingCallsDoNotRepairIncompatibleDeclarationEffectContexts() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialDeclarationThrow",
            kind: .function,
            resultType: Int.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(7)
        }
    )
    let support = """
        func compilerDifferentialDeclarationThrow() throws -> Int { 7 }
        """
    let sources = [
        """
        struct CompilerDifferentialInitializer {
            init() { _ = try compilerDifferentialDeclarationThrow() }
        }
        """,
        """
        func compilerDifferentialDefault(
            _ value: Int = try compilerDifferentialDeclarationThrow()
        ) throws {}
        """,
        """
        struct CompilerDifferentialGetter {
            var value: Int { try compilerDifferentialDeclarationThrow() }
        }
        """,
        """
        struct CompilerDifferentialExplicitGetter {
            var value: Int {
                get { try compilerDifferentialDeclarationThrow() }
            }
        }
        """,
        """
        enum CompilerDifferentialTypedError: Error { case expected }
        func compilerDifferentialTypedThrow() throws(CompilerDifferentialTypedError) -> Int {
            try compilerDifferentialDeclarationThrow()
        }
        """,
    ]

    for source in sources {
        let original = try compilerDifferentialTypecheck(
            support: support,
            source: source
        )
        let result = ConstExprRunner(registry: registry).rewrite(source: source)
        let rewritten = try compilerDifferentialTypecheck(
            support: support,
            source: result.source
        )

        #expect(original.status != 0)
        #expect(result.source == source)
        #expect(rewritten.status != 0)
    }
    #expect(counter.value == 0)
}

@Test func redundantTryDiagnosticsRemainVisibleAfterChildFolding() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialNonthrowing",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let support = """
        func compilerDifferentialNonthrowing(_ value: Int) -> Int { value + 1 }
        """
    let source = """
        let plain = try compilerDifferentialNonthrowing(1)
        let optional = try? compilerDifferentialNonthrowing(2)
        let forced = try! compilerDifferentialNonthrowing(3)
        """

    let original = try compilerDifferentialTypecheck(support: support, source: source)
    let result = ConstExprRunner(registry: registry).rewrite(source: source)
    let rewritten = try compilerDifferentialTypecheck(
        support: support,
        source: result.source
    )

    #expect(original.status != 0)
    #expect(result.source == """
        let plain = try 2
        let optional = try? 3
        let forced = try! 4
        """)
    #expect(counter.value == 3)
    #expect(rewritten.status != 0)
}
