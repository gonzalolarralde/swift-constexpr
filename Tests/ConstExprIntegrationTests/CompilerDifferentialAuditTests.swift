import ConstExpr
import Foundation
import Testing

final class CompilerDifferentialCounter: @unchecked Sendable {
    var value = 0
}

enum CompilerDifferentialFailure: Error {
    case expected
}

func compilerDifferentialTypecheck(
    support: String,
    source: String
) throws -> (status: Int32, error: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprCompilerDifferential-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("main.swift")
    try "\(support)\n\(source)\n".write(
        to: input,
        atomically: true,
        encoding: .utf8
    )

    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors", input.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

func compilerDifferentialRun(
    support: String,
    source: String
) throws -> (status: Int32, output: String, error: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprCompilerRun-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("main.swift")
    let executable = directory.appendingPathComponent("Program")
    try "\(support)\n\(source)\n".write(
        to: input,
        atomically: true,
        encoding: .utf8
    )

    let compiler = Process()
    let compilerError = Pipe()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = [
        "swiftc", "-warnings-as-errors", input.path, "-o", executable.path,
    ]
    compiler.standardOutput = Pipe()
    compiler.standardError = compilerError
    try compiler.run()
    compiler.waitUntilExit()
    let compileError = String(
        decoding: compilerError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    guard compiler.terminationStatus == 0 else {
        return (compiler.terminationStatus, "", compileError)
    }

    let program = Process()
    let output = Pipe()
    let error = Pipe()
    program.executableURL = executable
    program.standardOutput = output
    program.standardError = error
    try program.run()
    program.waitUntilExit()
    return (
        program.terminationStatus,
        String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

@Test func throwingRegistrationsRemainOpaqueInsideCatchBearingDoStatements() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialThrowing",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Bool.self],
            resultType: Int.self,
            isThrowing: true
        ) { _, arguments in
            counter.value += 1
            guard try arguments[0]!.require(Bool.self) else {
                throw CompilerDifferentialFailure.expected
            }
            return ConstExprValue(7)
        }
    )
    let source = """
        do {
            print(try compilerDifferentialThrowing(true))
        } catch {
            print("unexpected")
        }
        do {
            print(try compilerDifferentialThrowing(false))
        } catch {
            print("expected")
        }
        """
    let support = """
        enum CompilerDifferentialFailure: Error {
            case expected
        }
        func compilerDifferentialThrowing(_ succeeds: Bool) throws -> Int {
            guard succeeds else { throw CompilerDifferentialFailure.expected }
            return 7
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
    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(rewrittenTypecheck.status == 0)
    #expect(rewrittenTypecheck.error.isEmpty)
}

@Test func foldingDoesNotRemoveAnInferredClosuresThrowingEffect() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialThrowingClosureValue",
            kind: .function,
            resultType: String.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue("success")
        }
    )
    let source = """
        let closure = { try compilerDifferentialThrowingClosureValue() }
        print(classifyCompilerDifferentialClosure(closure))
        """
    let support = """
        enum CompilerDifferentialFailure: Error {
            case expected
        }
        func compilerDifferentialThrowingClosureValue() throws -> String {
            "success"
        }
        func classifyCompilerDifferentialClosure(
            _ body: () -> String
        ) -> String {
            "nonthrowing"
        }
        func classifyCompilerDifferentialClosure(
            _ body: () throws -> String
        ) -> String {
            "throwing"
        }
        """

    let original = try compilerDifferentialRun(support: support, source: source)
    let result = ConstExprRunner(registry: registry).rewrite(source: source)
    let rewritten = try compilerDifferentialRun(
        support: support,
        source: result.source
    )

    #expect(original.status == 0)
    #expect(original.output == "throwing\n")
    #expect(original.error.isEmpty)
    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(rewritten.status == 0)
    #expect(rewritten.output == original.output)
    #expect(rewritten.error.isEmpty)
}

@Test func anExplicitThrowingClosureMayStillFoldARegisteredCall() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialExplicitThrowingValue",
            kind: .function,
            resultType: String.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue("success")
        }
    )
    let source = """
        let closure = { () throws -> String in
            try compilerDifferentialExplicitThrowingValue()
        }
        print(try closure())
        """
    let support = """
        func compilerDifferentialExplicitThrowingValue() throws -> String {
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
    #expect(original.output == "success\n")
    #expect(original.error.isEmpty)
    #expect(result.source == """
        let closure = { () throws -> String in
            "success"
        }
        print(try closure())
        """)
    #expect(counter.value == 1)
    #expect(rewritten.status == 0)
    #expect(rewritten.output == original.output)
    #expect(rewritten.error.isEmpty)
}

@Test func foldingDoesNotRepairAnUnhandledThrowInANonthrowingFunction() throws {
    let counter = CompilerDifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compilerDifferentialUnhandledThrow",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Bool.self],
            resultType: Int.self,
            isThrowing: true
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(7)
        }
    )
    let source = """
        func compilerDifferentialNonthrowingFunction() -> Int {
            try compilerDifferentialUnhandledThrow(true)
        }
        """
    let support = """
        func compilerDifferentialUnhandledThrow(_ succeeds: Bool) throws -> Int {
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

    #expect(originalTypecheck.status != 0)
    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(rewrittenTypecheck.status != 0)
}
