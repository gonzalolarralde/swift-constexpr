import ConstExprEvaluateExampleMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ConstExprEvaluateMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "evaluate": ConstExprEvaluateExampleMacro.self
    ]

    func testCompanionMacroEvaluatesWithItsLinkedRegistry() {
        assertMacroExpansion(
            """
            let value = #evaluate {
                let input = 41
                return foo(input)
            }
            """,
            expandedSource: """
            let value = 42
            """,
            macros: macros
        )
    }

    func testUnknownCaptureSilentlyExpandsToOriginalExpression() {
        assertMacroExpansion(
            """
            let value = #evaluate { foo(runtimeValue) }
            """,
            expandedSource: """
            let value = foo(runtimeValue)
            """,
            macros: macros
        )
    }

    func testAmbiguousOverloadSilentlyExpandsToOriginalExpression() {
        assertMacroExpansion(
            """
            let value: Int = #evaluate { typedValue() }
            """,
            expandedSource: """
            let value: Int = typedValue()
            """,
            macros: macros
        )
    }

    func testUnrenderableResultSilentlyExpandsToOriginalExpression() {
        assertMacroExpansion(
            """
            let value = #evaluate { Bar(1) }
            """,
            expandedSource: """
            let value = Bar(1)
            """,
            macros: macros
        )
    }
}
