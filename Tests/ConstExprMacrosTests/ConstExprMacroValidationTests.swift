import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

extension ConstExprMacroTests {
    func testUnsupportedAsyncFunctionDiagnostic() {
        assertMacroExpansion(
            """
            @ConstExpr
            func load() async -> String { "value" }
            """,
            expandedSource: """
            func load() async -> String { "value" }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "async declarations are not supported by @ConstExpr",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testUnsupportedFunctionShapes() {
        assertRejected(
            "@ConstExpr\nfunc identity<T>(_ value: T) -> T { value }",
            expanded: "func identity<T>(_ value: T) -> T { value }",
            message: "generic declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc update(_ value: inout Int) -> Int { value }",
            expanded: "func update(_ value: inout Int) -> Int { value }",
            message: "inout parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc apply(_ body: (Int) -> Int) -> Int { body(1) }",
            expanded: "func apply(_ body: (Int) -> Int) -> Int { body(1) }",
            message: "function-typed parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc lazy(_ value: @autoclosure () -> Int) -> Int { value() }",
            expanded: "func lazy(_ value: @autoclosure () -> Int) -> Int { value() }",
            message: "@autoclosure parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc perform(_ body: () throws -> Int) rethrows -> Int { try body() }",
            expanded: "func perform(_ body: () throws -> Int) rethrows -> Int { try body() }",
            message: "rethrows declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc log(line: Int = #line) -> Int { line }",
            expanded: "func log(line: Int = #line) -> Int { line }",
            message: "caller-location default arguments are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc notify() {}",
            expanded: "func notify() {}",
            message: "@ConstExpr callables must return a value"
        )
        assertRejected(
            "@ConstExpr\nfunc forced(_ value: Int!) -> Int { value }",
            expanded: "func forced(_ value: Int!) -> Int { value }",
            message: "implicitly unwrapped optional parameter types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc borrow(_ value: borrowing String) -> String { value }",
            expanded: "func borrow(_ value: borrowing String) -> String { value }",
            message: "'borrowing' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc consume(_ value: consuming String) -> String { value }",
            expanded: "func consume(_ value: consuming String) -> String { value }",
            message: "'consuming' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc isolatedValue(_ value: isolated Worker) -> Int { 1 }",
            expanded: "func isolatedValue(_ value: isolated Worker) -> Int { 1 }",
            message: "'isolated' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc opaque() -> some Equatable { 1 }",
            expanded: "func opaque() -> some Equatable { 1 }",
            message: "function and opaque result types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc opaqueInput(_ value: some Equatable) -> String { \"value\" }",
            expanded: "func opaqueInput(_ value: some Equatable) -> String { \"value\" }",
            message: "opaque parameter types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc count(_ value: any Collection<Int>) -> Int { value.count }",
            expanded: "func count(_ value: any Collection<Int>) -> Int { value.count }",
            message: "parameterized existential parameter types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nfunc values() -> any Collection<Int> { [1, 2] }",
            expanded: "func values() -> any Collection<Int> { [1, 2] }",
            message: "parameterized existential result types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nlet values: any Collection<Int> = [1, 2]",
            expanded: "let values: any Collection<Int> = [1, 2]",
            message: "global constant 'values' was not registered: parameterized existential value types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nfunc typedThrow() throws(Failure) -> Int { 1 }",
            expanded: "func typedThrow() throws(Failure) -> Int { 1 }",
            message: "typed throws declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc variadic(_ values: Int...) -> Int { values.count }",
            expanded: "func variadic(_ values: Int...) -> Int { values.count }",
            message: "variadic parameters are not supported by @ConstExpr"
        )
    }

    func testGlobalActorAndUnsupportedLexicalContexts() {
        assertMacroExpansion(
            """
            @MainActor
            @ConstExpr
            func isolatedGlobal() -> Int { 1 }
            """,
            expandedSource: """
            @MainActor
            func isolatedGlobal() -> Int { 1 }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "global-actor-isolated declarations such as @MainActor are not supported by synchronous @ConstExpr adapters",
                    line: 2,
                    column: 1
                )
            ],
            macros: macros
        )

        assertMacroExpansion(
            """
            @globalActor actor Isolation {
                static let shared = Isolation()
            }
            @Isolation
            @ConstExpr
            func customIsolatedGlobal() -> Int { 1 }
            """,
            expandedSource: """
            @globalActor actor Isolation {
                static let shared = Isolation()
            }
            @Isolation
            func customIsolatedGlobal() -> Int { 1 }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "declaration attribute @Isolation may impose isolation or semantic transforms that @ConstExpr cannot prove safe; use manual registration",
                    line: 5,
                    column: 1
                )
            ],
            macros: macros
        )

        assertContextRejected(
            """
            protocol Host {
                @ConstExpr
                func value() -> Int
            }
            """,
            expanded: """
            protocol Host {
                func value() -> Int
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead"
        )
        assertContextRejected(
            """
            actor Host {
                @ConstExpr
                func value() -> Int { 1 }
            }
            """,
            expanded: """
            actor Host {
                func value() -> Int { 1 }
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead"
        )
        assertContextRejected(
            """
            func outer() {
                @ConstExpr
                struct Local {}
            }
            """,
            expanded: """
            func outer() {
                struct Local {}
            }
            """,
            message: "@ConstExpr nominal types cannot be local declarations"
        )
        assertContextRejected(
            """
            actor Container {
                @ConstExpr
                struct Nested {}
            }
            """,
            expanded: """
            actor Container {
                struct Nested {}
            }
            """,
            message: "@ConstExpr nominal types are not supported in protocols or actors"
        )
        assertContextRejected(
            """
            struct Container<Value> {}
            extension Container where Value == Int {
                @ConstExpr
                struct Nested {}
            }
            """,
            expanded: """
            struct Container<Value> {}
            extension Container where Value == Int {
                struct Nested {}
            }
            """,
            message: "@ConstExpr nominal types cannot be nested in a constrained or generic extension",
            line: 3
        )
    }

}
