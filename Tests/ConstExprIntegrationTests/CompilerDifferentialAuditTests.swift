import ConstExpr
import Foundation
import Testing

private final class CompilerDifferentialCounter: @unchecked Sendable {
    var value = 0
}

private enum CompilerDifferentialFailure: Error {
    case expected
}

private func compilerDifferentialTypecheck(
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

private func compilerDifferentialRun(
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
