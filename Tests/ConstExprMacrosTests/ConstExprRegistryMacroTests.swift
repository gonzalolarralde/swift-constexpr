import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ConstExprRegistryMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "constExprRegistry": ConstExprRegistryMacro.self,
    ]

    func testEmptyRegistry() {
        assertMacroExpansion(
            "let registry = #constExprRegistry()",
            expandedSource: "let registry = _ConstExprRuntime.Registry(registrations: [])",
            macros: macros
        )
    }

    func testFunctionsConstantsAndTypes() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(foo(_:), answer, Bar.self)
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: _ConstExprRuntime.registrations(fromGeneratedPeer: foo__constExpr(__constExprSelector_1_1__: foo(_:))) + _ConstExprRuntime.registrations(fromGeneratedPeer: answer__constExpr(__constExprSelector_0: answer)) + _ConstExprRuntime.registrations(fromGeneratedPeer: Bar__constExpr.registrations))
            """,
            macros: macros
        )
    }

    func testOverloadCastAndQualifiedNames() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(
                Definitions.parse(_:) as (Int) -> String,
                Definitions.Widget.self
            )
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: _ConstExprRuntime.registrations(fromGeneratedPeer: Definitions.parse__constExpr(__constExprSelector_1_1__: (Definitions.parse(_:) as (Int) -> String))) + _ConstExprRuntime.registrations(fromGeneratedPeer: Definitions.Widget__constExpr.registrations))
            """,
            macros: macros
        )
    }

    func testLabelSelectorsDisambiguateErasedFunctionTypes() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(route(x:), route(y:))
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: _ConstExprRuntime.registrations(fromGeneratedPeer: route__constExpr(__constExprSelector_1_1_x: route(x:))) + _ConstExprRuntime.registrations(fromGeneratedPeer: route__constExpr(__constExprSelector_1_1_y: route(y:))))
            """,
            macros: macros
        )
    }

    func testRawIdentifiersAndParenthesizedTypeEntries() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(`repeat`(_:), ((Definitions.`struct`)).self)
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: _ConstExprRuntime.registrations(fromGeneratedPeer: repeat__constExpr(__constExprSelector_1_1__: `repeat`(_:))) + _ConstExprRuntime.registrations(fromGeneratedPeer: Definitions.struct__constExpr.registrations))
            """,
            macros: macros
        )
    }

    func testRawArgumentLabelsUseSemanticSelectors() {
        assertMacroExpansion(
            "let registry = #constExprRegistry(route(`repeat`:))",
            expandedSource: "let registry = _ConstExprRuntime.Registry(registrations: _ConstExprRuntime.registrations(fromGeneratedPeer: route__constExpr(__constExprSelector_1_6_repeat: route(`repeat`:))))",
            macros: macros
        )
    }

    func testConditionalAndForcedCastsAreRejected() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(foo as? (Int) -> String, foo as! (Int) -> String)
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: [])
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "registry entries must name an @ConstExpr function, global let, or nominal type",
                    line: 1,
                    column: 35
                ),
                DiagnosticSpec(
                    message: "registry entries must name an @ConstExpr function, global let, or nominal type",
                    line: 1,
                    column: 60
                ),
            ],
            macros: macros
        )
    }

    func testInvalidRegistryEntry() {
        assertMacroExpansion(
            """
            let registry = #constExprRegistry(make())
            """,
            expandedSource: """
            let registry = _ConstExprRuntime.Registry(registrations: [])
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "registry entries must name an @ConstExpr function, global let, or nominal type",
                    line: 1,
                    column: 35
                )
            ],
            macros: macros
        )
    }
}
