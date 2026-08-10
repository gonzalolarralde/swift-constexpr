import Foundation
import Testing

private struct CLIRunResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum CLISmokeTestError: Error {
    case executableNotFound(startingAt: String)
}

private final class CLISmokeBundleToken: NSObject {}

private func exampleCLIExecutable() throws -> URL {
    let testBundle = Bundle(for: CLISmokeBundleToken.self).bundleURL
        .resolvingSymlinksInPath()
    var directory = testBundle.deletingLastPathComponent()

    while directory.path != "/" {
        let candidate = directory.appendingPathComponent("swift-constexpr-example")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        directory.deleteLastPathComponent()
    }
    throw CLISmokeTestError.executableNotFound(startingAt: testBundle.path)
}

private func runExampleCLI(
    arguments: [String] = [],
    standardInput: String = "",
    currentDirectory: URL? = nil
) throws -> CLIRunResult {
    let executable = try exampleCLIExecutable()

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    try process.run()
    input.fileHandleForWriting.write(Data(standardInput.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    return CLIRunResult(
        status: process.terminationStatus,
        standardOutput: String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        standardError: String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

@Test func exampleCLIRewritesFilesAndAcceptsAnOptionLookingInputPath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprCLI-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("-Input.swift")
    let output = directory.appendingPathComponent("Rewritten.swift")
    try "let result = Foo().bar.blah()\n".write(
        to: input,
        atomically: true,
        encoding: .utf8
    )

    let result = try runExampleCLI(
        arguments: [
            "--output", output.lastPathComponent,
            "--", input.lastPathComponent,
        ],
        currentDirectory: directory
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.isEmpty)
    #expect(try String(contentsOf: output, encoding: .utf8) == "let result = \"5\"\n")
}

@Test func exampleCLIRewritesStandardInput() throws {
    let result = try runExampleCLI(
        arguments: ["-"],
        standardInput: "let result = foo(1)\n"
    )

    #expect(result.status == 0)
    #expect(result.standardOutput == "let result = 2\n")
    #expect(result.standardError.isEmpty)
}

@Test func exampleCLIPreservesUTF8BOMAndCRLFForStreamsAndFiles() throws {
    let source = "\u{FEFF}let result = foo(1)\r\n"
    let expected = "\u{FEFF}let result = 2\r\n"

    let streamed = try runExampleCLI(arguments: ["-"], standardInput: source)
    #expect(streamed.status == 0)
    #expect(Array(streamed.standardOutput.utf8) == Array(expected.utf8))
    #expect(streamed.standardError.isEmpty)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprCLI-Encoding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Input.swift")
    let output = directory.appendingPathComponent("Output.swift")
    try Data(source.utf8).write(to: input)

    let file = try runExampleCLI(
        arguments: ["--output", output.path, input.path]
    )
    #expect(file.status == 0)
    #expect(file.standardOutput.isEmpty)
    #expect(file.standardError.isEmpty)
    #expect(try Data(contentsOf: output) == Data(expected.utf8))
}

@Test func exampleCLIFailsOnDiagnosticsOnlyWhenRequested() throws {
    let source = "let result = 1 / 0\n"
    let ordinary = try runExampleCLI(standardInput: source)
    let strict = try runExampleCLI(
        arguments: ["--fail-on-diagnostics"],
        standardInput: source
    )

    #expect(ordinary.status == 0)
    #expect(strict.status == 2)
    #expect(ordinary.standardOutput == source)
    #expect(strict.standardOutput == source)
    #expect(ordinary.standardError.contains("division-by-zero"))
    #expect(strict.standardError.contains("division-by-zero"))
}

@Test func exampleCLIReportsUsageErrorsAndSupportsExplicitStdout() throws {
    let invalid = try runExampleCLI(arguments: ["--not-an-option"])
    let stdout = try runExampleCLI(
        arguments: ["--output", "-", "-"],
        standardInput: "let result = exampleAnswer\n"
    )

    #expect(invalid.status == 64)
    #expect(invalid.standardOutput.isEmpty)
    #expect(invalid.standardError.contains("unknown option"))
    #expect(invalid.standardError.contains("Usage:"))
    #expect(stdout.status == 0)
    #expect(stdout.standardOutput == "let result = 42\n")
    #expect(stdout.standardError.isEmpty)
}

@Test func exampleCLIUsesDistinctInputAndOutputFailureStatuses() throws {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let missingInput = missingDirectory.appendingPathComponent("Input.swift")
    let impossibleOutput = missingDirectory.appendingPathComponent("Output.swift")

    let inputFailure = try runExampleCLI(arguments: [missingInput.path])
    let outputFailure = try runExampleCLI(
        arguments: ["--output", impossibleOutput.path],
        standardInput: "let value = 1\n"
    )

    #expect(inputFailure.status == 66)
    #expect(inputFailure.standardOutput.isEmpty)
    #expect(inputFailure.standardError.contains("could not read"))
    #expect(!inputFailure.standardError.contains("Usage:"))

    #expect(outputFailure.status == 74)
    #expect(outputFailure.standardOutput.isEmpty)
    #expect(outputFailure.standardError.contains("could not write"))
    #expect(!outputFailure.standardError.contains("Usage:"))
}
