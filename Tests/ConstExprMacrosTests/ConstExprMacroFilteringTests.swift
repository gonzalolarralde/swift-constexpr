import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

extension ConstExprMacroTests {
    func testUnsafeMembersAreFiltered() {
        assertFilteredMember(
            declaration: "lazy var value = 1",
            message: "lazy property was not registered because reading it may mutate the receiver"
        )
        assertFilteredMember(
            declaration: "var value: Int { mutating get { 1 } }",
            message: "mutating or consuming property getter was not registered",
            column: 9
        )
        assertFilteredMember(
            declaration: "@MainActor\n    func value() -> Int { 1 }",
            message: "method 'value' was not registered because @MainActor isolation cannot be called by a synchronous adapter"
        )
        assertFilteredMember(
            declaration: "static subscript(index: Int) -> Int { index }",
            message: "static subscripts are not supported by @ConstExpr"
        )
        assertFilteredMember(
            declaration: "subscript(index: Int) -> Int { get throws { index } }",
            message: "async or throwing subscript accessor was not registered"
        )
        assertFilteredMember(
            declaration: "subscript(index: Int) -> Int { mutating get { index } }",
            message: "mutating or consuming subscript getter was not registered"
        )
        assertFilteredMember(
            declaration: "@Isolation\n    func value() -> Int { 1 }",
            message: "method 'value' was not registered because @Isolation may impose isolation or semantic transforms that a generated adapter cannot prove safe; use manual registration"
        )
        assertFilteredMember(
            declaration: "var values: any Collection<Int> { [1, 2] }",
            message: "property 'values' was not registered: parameterized existential value types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target",
            column: 9
        )

        assertMacroExpansion(
            """
            @ConstExpr
            public struct PublicAPI {
                func hidden() -> Int { 1 }
            }
            """,
            expandedSource: """
            public struct PublicAPI {
                func hidden() -> Int { 1 }
            }

            public enum PublicAPI__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )

        assertMacroExpansion(
            """
            @ConstExpr
            public struct SPIProvider {
                @_spi(Secret)
                public func secret() -> Int { 1 }
            }
            """,
            expandedSource: """
            public struct SPIProvider {
                @_spi(Secret)
                public func secret() -> Int { 1 }
            }

            public enum SPIProvider__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )

        assertFilteredClassMember(
            declaration: "func value() -> Int { 1 }",
            message: "overridable instance method 'value' was not registered; mark the class or member final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "var value: Int { 1 }",
            message: "overridable instance property was not registered; mark the class or property final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "subscript(index: Int) -> Int { index }",
            message: "overridable instance subscript was not registered; mark the class or subscript final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "dynamic func value() -> Int { 1 }",
            message: "dynamic method 'value' was not registered because runtime replacement or dispatch can invoke an unregistered implementation",
            isFinalClass: true
        )
        assertFilteredClassMember(
            declaration: "dynamic static func value() -> Int { 1 }",
            message: "dynamic method 'value' was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
        assertFilteredClassMember(
            declaration: "dynamic var value: Int { 1 }",
            message: "dynamic property was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
        assertFilteredClassMember(
            declaration: "dynamic subscript(index: Int) -> Int { index }",
            message: "dynamic subscript was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
    }

    func testGenericNominalTypeDiagnostic() {
        assertMacroExpansion(
            """
            @ConstExpr
            struct Box<Value> {
                let value: Value
            }
            """,
            expandedSource: """
            struct Box<Value> {
                let value: Value
            }
            """,
            macros: macros
        )
    }

    func testMutableAndMultipleGlobalDiagnostics() {
        assertMacroExpansion(
            """
            @ConstExpr
            var mutable = 1
            @ConstExpr
            let first = 1, second = 2
            """,
            expandedSource: """
            var mutable = 1
            let first = 1, second = 2
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ConstExpr can only register immutable global let bindings",
                    line: 1,
                    column: 1
                ),
                DiagnosticSpec(
                    message: "peer macro can only be applied to a single variable",
                    line: 3,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func assertRejected(_ source: String, expanded: String, message: String) {
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
            macros: macros
        )
    }

    func assertContextRejected(
        _ source: String,
        expanded: String,
        message: String,
        line: Int = 2
    ) {
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [DiagnosticSpec(message: message, line: line, column: 5)],
            macros: macros
        )
    }

    func assertFilteredMember(
        declaration: String,
        message _: String,
        column _: Int = 5
    ) {
        let source = """
        @ConstExpr
        struct Filtered {
            \(declaration)
        }
        """
        let expanded = """
        struct Filtered {
            \(declaration)
        }

        enum Filtered__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            macros: macros
        )
    }

    func assertFilteredClassMember(
        declaration: String,
        message _: String,
        isFinalClass: Bool = false
    ) {
        let classModifier = isFinalClass ? "final " : ""
        let source = """
        @ConstExpr
        \(classModifier)class FilteredClass {
            \(declaration)
        }
        """
        let expanded = """
        \(classModifier)class FilteredClass {
            \(declaration)
        }

        enum FilteredClass__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            macros: macros
        )
    }

    func assertFilteredArrayLiteralWitness(
        declaration: String,
        message _: String
    ) {
        let source = """
        @ConstExpr
        struct FilteredBag: ExpressibleByArrayLiteral {
            \(declaration)
        }
        """
        let expanded = """
        struct FilteredBag: ExpressibleByArrayLiteral {
            \(declaration)
        }

        enum FilteredBag__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            macros: macros
        )
    }
}
