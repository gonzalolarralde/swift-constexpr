import ConstExpr
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
        #bytes(requireConstant: true) {
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
        let result = try expand("#bytes(requireConstant: true) {}")
        XCTAssertEqual(result.expression, #""[empty]""#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testParenthesizedClosure() throws {
        let result = try expand(#"#bytes(requireConstant: true, { "a" })"#)
        XCTAssertEqual(result.expression, #""[first:<a>]""#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testUnknownInputFallsBackAsWholeClosure() throws {
        let result = try expand(#"#bytes { "a"; runtimeValue }"#)
        XCTAssertEqual(result.expression, #"Runtime.encode { "a"; runtimeValue }"#)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testUnknownInputInStrictModeIsAnError() throws {
        let result = try expand("#bytes(requireConstant: true) { runtimeValue }")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].hasPrefix("#bytes could not produce a compile-time constant:"))
    }

    func testUnresolvedUnusedBindingCannotBeCertified() throws {
        let result = try expand(#"#bytes(requireConstant: true) { let unused = runtimeValue; "a" }"#)
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
        ]
        for body in bodies {
            let result = try expand("#bytes \(body)")
            XCTAssertEqual(result.expression, "Runtime.encode \(body)")
            XCTAssertTrue(result.diagnostics.isEmpty)
            let strict = try expand("#bytes(requireConstant: true) \(body)")
            XCTAssertEqual(strict.diagnostics, [
                "#bytes could not produce a compile-time constant: only synchronous, nonthrowing straight-line expressions and immutable local bindings are supported"
            ])
        }
    }

    func testStrictFlagMustBeLiteral() throws {
        let result = try expand(#"#bytes(requireConstant: flag) { "a" }"#)
        XCTAssertEqual(result.diagnostics, ["#bytes requires a literal true or false for 'requireConstant'"])
    }

    func testExplicitFalseAllowsFallback() throws {
        let result = try expand("#bytes(requireConstant: false) { runtimeValue }")
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.expression, "Runtime.encode { runtimeValue }")
    }

    func testUnrenderableResultIsRejectedWhenRequired() throws {
        let result = try expand("#bytes(requireConstant: true) { 7 }", builder: "OpaqueBuilder")
        XCTAssertEqual(result.diagnostics, [
            "#bytes could not produce a compile-time constant: the result cannot be represented as Swift source"
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
            requireConstantArgumentLabel: "requireConstant"
        )
        return (result.trimmedDescription, context.diagnostics.map(\.message))
    }
}
