import ConstExpr
import ConstExprEvaluation
import ConstExprMacroSupport
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import XCTest

@ConstExpr
private enum BranchBuilder {
    static func buildExpression(_ value: String) -> String { "e(\(value))" }
    static func buildPartialBlock(first: String) -> String { "p(\(first))" }
    static func buildPartialBlock(accumulated: String, next: String) -> String { "\(accumulated)+\(next)" }
    static func buildFinalResult(_ value: String) -> String { "f(\(value))" }
    static func buildBlock() -> String { "empty" }
    static func buildEither(first: String) -> String { "L(\(first))" }
    static func buildEither(second: String) -> String { "R(\(second))" }
    static func buildOptional(_ value: String?) -> String { value.map { "O(\($0))" } ?? "none" }
}

@resultBuilder
private enum NativeBranchBuilder {
    static func buildExpression(_ value: String) -> String { BranchBuilder.buildExpression(value) }
    static func buildPartialBlock(first: String) -> String { BranchBuilder.buildPartialBlock(first: first) }
    static func buildPartialBlock(accumulated: String, next: String) -> String {
        BranchBuilder.buildPartialBlock(accumulated: accumulated, next: next)
    }
    static func buildFinalResult(_ value: String) -> String { BranchBuilder.buildFinalResult(value) }
    static func buildBlock() -> String { BranchBuilder.buildBlock() }
    static func buildEither(first: String) -> String { BranchBuilder.buildEither(first: first) }
    static func buildEither(second: String) -> String { BranchBuilder.buildEither(second: second) }
    static func buildOptional(_ value: String?) -> String { BranchBuilder.buildOptional(value) }
}

private func branchRuntime(@NativeBranchBuilder _ body: () -> String) -> String { body() }
private enum UnselectedInvocation: Error { case executed }

final class ConstExprBuilderBranchTests: XCTestCase {
    func testKnownBranchesMatchNativeBuilderHooksAndInjectionTree() throws {
        for choice in 0..<5 {
            let result = try expand("""
            "before"
            if \(choice) == 0 { "zero" }
            else if \(choice) == 1 { "one" }
            else if \(choice) == 2 { "two" }
            else if \(choice) == 3 { "three" }
            else { "four" }
            "after"
            """)
            let expected = branchRuntime {
                "before"
                if choice == 0 { "zero" }
                else if choice == 1 { "one" }
                else if choice == 2 { "two" }
                else if choice == 3 { "three" }
                else { "four" }
                "after"
            }
            XCTAssertEqual(result.value, expected, result.source)
            XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        }
    }

    func testOptionalElseIfChainsMatchNativeBuilder() throws {
        for choice in 0..<4 {
            let result = try expand("""
            if \(choice) == 0 { "zero" }
            else if \(choice) == 1 { "one" }
            else if \(choice) == 2 { "two" }
            """)
            let expected = branchRuntime {
                if choice == 0 { "zero" }
                else if choice == 1 { "one" }
                else if choice == 2 { "two" }
            }
            XCTAssertEqual(result.value, expected, result.source)
            XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        }
    }

    func testBranchLocalsShadowWithoutEscapingTheirScope() throws {
        let result = try expand("""
        let value = "outer"
        let enabled = true
        if enabled {
            let value = "inner"
            if !false { value }
        }
        value
        """)
        let expected = branchRuntime {
            let value = "outer"
            let enabled = true
            if enabled {
                let value = "inner"
                if !false { value }
            }
            value
        }
        XCTAssertEqual(result.value, expected, result.source)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testUnselectedBranchIsNeverInvoked() throws {
        let result = try expand("if true { \"safe\" } else { touch() }")
        XCTAssertEqual(result.value, branchRuntime { if true { "safe" } else { "unused" } })
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testUnknownConditionPreservesLazyRuntimeBuilder() throws {
        let body = "if flag { touch() } else { \"safe\" }"
        let result = try expand(body, strict: false)
        XCTAssertEqual(result.source, "Runtime.encode {\n\(body)\n}")
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let strict = try expand(body)
        XCTAssertEqual(strict.diagnostics.count, 1)
        XCTAssertTrue(strict.diagnostics[0].contains("known Boolean conditions"))
    }

    func testKnownConditionCanStillLeaveRuntimeWork() throws {
        let result = try expand("if true { runtimeValue } else { touch() }; \"tail\"", strict: false)
        XCTAssertTrue(result.source.contains("runtimeValue"), result.source)
        XCTAssertFalse(result.source.contains("touch()"), result.source)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testLoopsPatternsAndDuplicateLocalsAreNotCertified() throws {
        for body in [
            "for value in values { value }",
            "if let value = optional { value }",
            "if true { let value = \"a\"; let value = \"b\"; value }",
        ] {
            XCTAssertEqual(try expand(body).diagnostics.count, 1)
        }
    }

    private func expand(_ body: String, strict: Bool = true) throws -> (value: String?, source: String, diagnostics: [String]) {
        let tree = Parser.parse(source: "#bytes {\n\(body)\n}")
        let macro = try XCTUnwrap(tree.statements.first?.item.as(MacroExpansionExprSyntax.self))
        let context = BasicMacroExpansionContext()
        let registry = #constExprRegistry(BranchBuilder.self).appending(.init(
            name: "touch", kind: .function, resultType: String.self,
            invoke: { _, _ in throw UnselectedInvocation.executed }
        ))
        let result = ConstExprBuilderMacroSupport.expansion(
            of: macro, in: context, registry: registry, builderType: "BranchBuilder",
            runtimeFunction: "Runtime.encode", policy: strict ? .requireConstant : .bestEffort,
            supportsBranches: true
        )
        return (result.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
                result.trimmedDescription, context.diagnostics.map(\.message))
    }
}
