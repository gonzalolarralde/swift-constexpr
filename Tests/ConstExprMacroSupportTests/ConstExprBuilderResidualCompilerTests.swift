import ConstExpr
import ConstExprEvaluation
import ConstExprMacroSupport
import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import XCTest

// An Int input becomes a String component. Re-entering buildExpression with
// a folded component would not even type-check, and regrouping partial blocks
// would change the parentheses in the result.
@ConstExpr
private enum DistinctBuilder {
    static func buildExpression(_ value: Int) -> String { "e\(value)" }
    static func buildPartialBlock(first: String) -> String { "(\(first))" }
    static func buildPartialBlock(accumulated: String, next: String) -> String { "(\(accumulated)+\(next))" }
    static func buildFinalResult(_ value: String) -> String { "[\(value)]" }
    static func buildBlock() -> String { "empty" }
    static func buildEither(first: String) -> String { "L(\(first))" }
    static func buildEither(second: String) -> String { "R(\(second))" }
    static func buildOptional(_ value: String?) -> String { value.map { "O(\($0))" } ?? "none" }
}

final class ConstExprBuilderResidualCompilerTests: XCTestCase {
    func testResidualMatchesNativeBuilderWithDifferentComponentTypesAndObservableInputs() throws {
        let body = """
        7
        let a = read("binding", 2)
        a
        read("middle", 3)
        let fixed: Int = 11
        fixed
        let choose: Bool = true
        let unused: Int = read("discarded", 99)
        choose ? 13 : unused
        read("last", 5)
        """
        let expanded = try expand(body)
        XCTAssertFalse(expanded.contains("DistinctBuilder.buildExpression(7)"), expanded)
        XCTAssertTrue(expanded.contains("\"e11\""), expanded)
        XCTAssertTrue(expanded.contains("\"e13\""), expanded)
        let program = runtimeSupport + """

        func original() -> String {
            Runtime.encode {
                \(body)
            }
        }
        func residual() -> String { \(expanded) }
        let expected = original()
        let expectedEvents = events
        events = []
        let actual = residual()
        precondition(actual == expected, "builder hooks ran twice or regrouped")
        precondition(events == expectedEvents, "dynamic evaluation order changed")
        precondition(events == ["binding", "middle", "discarded", "last"])
        print(actual)
        """
        let result = try compileAndRun(program)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.error.isEmpty, result.error)
        XCTAssertEqual(result.output, "[((((((e7)+e2)+e3)+e11)+e13)+e5)]\n")
    }

    func testGeneratedNamesDoNotCaptureUserLocalsAndInferredTypesStillCompile() throws {
        let body = """
        let constExprComponent = read("first", 2), constant: Int = 7
        constant
        constExprComponent
        let constExprPartial = read("second", 3)
        constExprPartial
        """
        let expanded = try expand(body)
        let result = try compileAndRun(runtimeSupport + """

        let result = \(expanded)
        precondition(events == ["first", "second"])
        print(result)
        """)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.error.isEmpty, result.error)
        XCTAssertEqual(result.output, "[(((e7)+e2)+e3)]\n")
    }

    func testAnOuterValueCannotShadowTheGeneratedBuilderReference() throws {
        let expanded = try expand("7; dynamic; 11")
        let result = try compileAndRun(runtimeSupport + """

        func example(dynamic: Int) -> String {
            let DistinctBuilder = 42
            precondition(DistinctBuilder == 42)
            return \(expanded)
        }
        print(example(dynamic: 9))
        """)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.error.isEmpty, result.error)
        XCTAssertEqual(result.output, "[(((e7)+e9)+e11)]\n")
    }

    func testKnownBranchResidualPreservesScopesOrderingAndSingleEvaluation() throws {
        let body = """
        let value = read("outer", 7)
        value
        if true {
            let value = read("inner", 3)
            value
            if false { read("unselected", 99) } else { 11 }
        }
        value
        read("last", 5)
        """
        let expanded = try expand(body, supportsBranches: true)
        XCTAssertFalse(expanded.contains("unselected"), expanded)
        let result = try compileAndRun(runtimeSupport + """

        func original() -> String { Runtime.encode { \(body) } }
        func residual() -> String { \(expanded) }
        let expected = original()
        let expectedEvents = events
        events = []
        let actual = residual()
        precondition(actual == expected)
        precondition(events == expectedEvents && events == ["outer", "inner", "last"])
        print("passed")
        """)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertTrue(result.error.isEmpty, result.error)
        XCTAssertEqual(result.output, "passed\n")
    }

    private func expand(_ body: String, supportsBranches: Bool = false) throws -> String {
        let tree = Parser.parse(source: "#bytes {\n\(body)\n}")
        let expression = try XCTUnwrap(tree.statements.first?.item.as(MacroExpansionExprSyntax.self))
        let context = BasicMacroExpansionContext()
        let registry = #constExprRegistry(DistinctBuilder.self)
        let result = ConstExprBuilderMacroSupport.expansion(
            of: expression, in: context, registry: registry,
            builderType: "DistinctBuilder", runtimeFunction: "Runtime.encode",
            supportsBranches: supportsBranches
        )
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        return result.description
    }

    private let runtimeSupport = #"""
    @resultBuilder
    enum DistinctBuilder {
        static func buildExpression(_ value: Int) -> String { "e\(value)" }
        static func buildPartialBlock(first: String) -> String { "(\(first))" }
        static func buildPartialBlock(accumulated: String, next: String) -> String { "(\(accumulated)+\(next))" }
        static func buildFinalResult(_ value: String) -> String { "[\(value)]" }
        static func buildBlock() -> String { "empty" }
        static func buildEither(first: String) -> String { "L(\(first))" }
        static func buildEither(second: String) -> String { "R(\(second))" }
        static func buildOptional(_ value: String?) -> String { value.map { "O(\($0))" } ?? "none" }
    }
    enum Runtime {
        static func encode(@DistinctBuilder _ body: () -> String) -> String { body() }
    }
    var events: [String] = []
    func read(_ event: String, _ value: Int) -> Int {
        events.append(event)
        return value
    }
    """#

    private func compileAndRun(_ source: String) throws -> (status: Int32, output: String, error: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConstExprBuilderResidual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("Program")
        try source.write(to: input, atomically: true, encoding: .utf8)

        let compiler = Process()
        let compilerError = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-warnings-as-errors", input.path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = compilerError
        try compiler.run()
        let diagnostic = String(decoding: compilerError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { return (compiler.terminationStatus, "", diagnostic) }

        let program = Process()
        let output = Pipe()
        let error = Pipe()
        program.executableURL = executable
        program.standardOutput = output
        program.standardError = error
        try program.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let failure = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        program.waitUntilExit()
        return (program.terminationStatus, result, diagnostic + failure)
    }
}
