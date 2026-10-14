import ConstExpr
import ConstExprEvaluation
import ConstExprMacroSupport
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import XCTest

// Different result type and nontrivial hooks: the support layer must call the
// supplied builder, not hard-code concatenation or PacketKit behavior.
@ConstExpr
private enum TextBuilder {
    static func buildExpression(_ text: String) -> String { "<" + text + ">" }
    static func buildPartialBlock(first: String) -> String { "first:" + first }
    static func buildPartialBlock(accumulated: String, next: String) -> String { accumulated + "|" + next }
    static func buildFinalResult(_ text: String) -> String { "[" + text + "]" }
    static func buildBlock() -> String { "empty" }
}

@ConstExpr
private enum OpaqueBuilder {
    static func buildExpression(_ value: Int) -> Int { value }
    static func buildPartialBlock(first: Int) -> Int { first }
    static func buildFinalResult(_ value: Int) -> OpaqueValue { OpaqueValue(value: value) }
}

private struct OpaqueValue { let value: Int }

final class ConstExprBuilderMacroSupportTests: XCTestCase {
    private let registry = #constExprRegistry(TextBuilder.self, OpaqueBuilder.self)

    func testRegisteredHooksAndInterleavedBindings() throws {
        let result = try expand("""
        #constBytes {
            "a"
            let next = "b"
            next
            "c"
        }
        """)
        XCTAssertEqual(result.expression, #""[first:<a>|<b>|<c>]""#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testEmptyBodyCallsEmptyBlockAndFinalResult() throws {
        let result = try expand("#constBytes {}")
        XCTAssertEqual(result.expression, #""[empty]""#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testParenthesizedClosure() throws {
        let result = try expand(#"#constBytes({ "a" })"#)
        XCTAssertEqual(result.expression, #""[first:<a>]""#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testConstantsBeforeAndAfterUnknownInputArePartiallyEvaluated() throws {
        let result = try expand(#"#bytes { "a"; runtimeValue; "c" }"#)
        XCTAssertTrue(result.expression.contains(#"accumulated: "first:<a>""#), result.expression)
        XCTAssertTrue(result.expression.contains(#"next: "<c>""#), result.expression)
        XCTAssertTrue(result.expression.contains(".buildExpression(runtimeValue)"))
        XCTAssertEqual(result.expression.components(separatedBy: ".buildExpression(").count - 1, 1)
        XCTAssertFalse(result.expression.contains("Runtime.encode"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testPartialEvaluationPreservesUserInitializersEvenWhenUnused() throws {
        let result = try expand(#"#bytes { let ignored: String = makeText(); "a"; runtimeValue }"#)
        XCTAssertTrue(result.expression.contains("let _: String = makeText()"), result.expression)
        XCTAssertEqual(result.expression.components(separatedBy: "makeText()").count - 1, 1)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testUnknownUnusedBindingKeepsItsOriginalLifetime() throws {
        let result = try expand(#"#bytes { let object = makeObject(); "a"; runtimeValue }"#)
        XCTAssertEqual(result.expression, #"Runtime.encode { let object = makeObject(); "a"; runtimeValue }"#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testPropagatedLocalBindingsDoNotIntroduceUnusedBindingWarnings() throws {
        let result = try expand(#"#bytes { let text: String = "a"; runtimeValue; text }"#)
        XCTAssertTrue(result.expression.contains(#"let _: String = "a""#), result.expression)
        XCTAssertTrue(result.expression.contains(#"next: "<a>""#), result.expression)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testStrictMixedBodyStillRejectsResidualWork() throws {
        let result = try expand(#"#constBytes { "a"; runtimeValue; "c" }"#)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.expression, #"Runtime.encode { "a"; runtimeValue; "c" }"#)
    }

    func testUnknownInputInStrictModeIsAnError() throws {
        let result = try expand("#constBytes { runtimeValue }")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].hasPrefix("#constBytes could not produce a compile-time constant:"))
    }

    func testUnresolvedUnusedBindingCannotBeCertified() throws {
        let result = try expand(#"#constBytes { let unused = runtimeValue; "a" }"#)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.expression.contains("let unused = runtimeValue"))
    }

    func testUnsupportedBodiesKeepTheirOriginalSwiftSemantics() throws {
        let bodies = [
            #"{ var x = "a"; x }"#,
            #"{ if flag { "a" } else { "b" } }"#,
            #"{ for x in values { x } }"#,
            #"{ return "a" }"#,
            #"{ () -> String in "a" }"#,
            #"{ try TextBuilder.buildExpression("a") }"#,
            #"{ let x = try? makeText(); "a" }"#,
            #"{ await makeText() }"#,
            #"{ let TextBuilder = something; (1 + 2) as Int }"#,
            #"{ let `TextBuilder` = something; (1 + 2) as Int }"#,
        ]
        for body in bodies {
            let result = try expand("#bytes \(body)")
            XCTAssertEqual(result.expression, "Runtime.encode \(body)")
            XCTAssertTrue(result.diagnostics.isEmpty)
            let strict = try expand("#constBytes \(body)")
            XCTAssertEqual(strict.diagnostics, [
                "#constBytes could not produce a compile-time constant: only synchronous, nonthrowing straight-line expressions and immutable local bindings are supported"
            ])
        }
    }

    func testPreparedOpaqueValueCanBeConsumedBeforeRendering() throws {
        let tree = Parser.parse(source: "#bytes { 7 }")
        let macro = try XCTUnwrap(tree.statements.first?.item.as(MacroExpansionExprSyntax.self))
        let prepared = ConstExprBuilderMacroSupport.prepare(
            of: macro, in: BasicMacroExpansionContext(), registry: registry,
            builderType: "OpaqueBuilder", runtimeFunction: "Runtime.encode"
        )
        let value = try XCTUnwrap(prepared.constantValue).require(OpaqueValue.self)
        XCTAssertEqual(value.value, 7)
    }

    func testDefaultPolicyAllowsFallback() throws {
        let result = try expand("#bytes { runtimeValue }")
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.expression, "Runtime.encode { runtimeValue }")
    }

    func testUnrenderableResultIsRejectedWhenRequired() throws {
        let result = try expand("#constBytes { 7 }", builder: "OpaqueBuilder")
        XCTAssertEqual(result.diagnostics, [
            "#constBytes could not produce a compile-time constant: the result cannot be represented as Swift source"
        ])
    }

    func testMissingClosureIsDiagnosed() throws {
        let result = try expand("#bytes()")
        XCTAssertEqual(result.diagnostics, ["#bytes requires a closure"])
    }

    private func expand(
        _ source: String,
        builder: String = "TextBuilder"
    ) throws -> (expression: String, diagnostics: [String]) {
        let tree = Parser.parse(source: source)
        let expression = try XCTUnwrap(tree.statements.first?.item.as(MacroExpansionExprSyntax.self))
        let context = BasicMacroExpansionContext()
        let result = ConstExprBuilderMacroSupport.expansion(
            of: expression, in: context, registry: registry,
            builderType: builder, runtimeFunction: "Runtime.encode",
            policy: expression.macroName.text == "constBytes" ? .requireConstant : .bestEffort
        )
        return (result.trimmedDescription, context.diagnostics.map(\.message))
    }
}
