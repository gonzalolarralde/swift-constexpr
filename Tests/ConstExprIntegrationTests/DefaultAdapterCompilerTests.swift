import Foundation
import Testing

private let defaultAdapterLinkedModules = [
    "ConstExpr",
    "SwiftSyntax",
    "SwiftSyntax509",
    "SwiftSyntax510",
    "SwiftSyntax600",
    "SwiftSyntax601",
    "SwiftSyntax602",
    "SwiftSyntax603",
    "SwiftParser",
    "SwiftParserDiagnostics",
    "SwiftOperators",
    "SwiftSyntaxBuilder",
    "SwiftDiagnostics",
    "SwiftBasicFormat",
    "_SwiftSyntaxCShims",
]

@Test func compilerOmitsUnusableDefaultAdapterAndRegistryNeverInvokesIt() throws {
    let result = try compileAndRunDefaultAdapterFixture()
    #expect(result.compilerStatus == 0, Comment(rawValue: result.compilerError))
    #expect(!result.compilerError.contains("ConstExprRegistration adapter"))
    #expect(result.programStatus == 0, Comment(rawValue: result.programError))
}

private func compileAndRunDefaultAdapterFixture() throws -> (
    compilerStatus: Int32,
    compilerError: String,
    programStatus: Int32,
    programError: String
) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprDefaultAdapter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Fixture.swift")
    let executable = directory.appendingPathComponent("Fixture")
    try defaultAdapterFixtureSource.write(to: input, atomically: true, encoding: .utf8)

    let build = try activeSwiftPMBuildDirectory()
    let shims = try swiftSyntaxShims(startingAt: build)
    let objects = try defaultAdapterLinkedModules.flatMap { module in
        try FileManager.default.contentsOfDirectory(
            at: build.appendingPathComponent("\(module).build"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path }
    }
    let compiler = Process()
    let compilerError = Pipe()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = [
        "swiftc", "-parse-as-library", "-swift-version", "6",
        "-I", build.appendingPathComponent("Modules").path,
        "-Xcc", "-fmodule-map-file=\(shims.appendingPathComponent("module.modulemap").path)",
        "-Xcc", "-I", "-Xcc", shims.path,
        "-load-plugin-executable",
        "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
        input.path,
    ] + objects.map(\.path) + ["-o", executable.path]
    compiler.standardOutput = Pipe()
    compiler.standardError = compilerError
    try compiler.run()
    compiler.waitUntilExit()
    let compilerErrorText = String(
        decoding: compilerError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    guard compiler.terminationStatus == 0 else {
        return (compiler.terminationStatus, compilerErrorText, -1, "not run")
    }

    let program = Process()
    let programError = Pipe()
    program.executableURL = executable
    program.standardOutput = Pipe()
    program.standardError = programError
    try program.run()
    program.waitUntilExit()
    return (
        compiler.terminationStatus,
        compilerErrorText,
        program.terminationStatus,
        String(
            decoding: programError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private let defaultAdapterFixtureSource = """
import ConstExpr

enum Defaults { static let value = 0 }

@ConstExpr
struct TooManyDefaults {
    init(
        a: Int = Defaults.value, b: Int = Defaults.value,
        c: Int = Defaults.value, d: Int = Defaults.value,
        e: Int = Defaults.value, f: Int = Defaults.value,
        g: Int = Defaults.value, h: Int = Defaults.value,
        i: Int = Defaults.value
    ) {
        fatalError("an omitted registration must never invoke this initializer")
    }
}

let registry = #constExprRegistry(TooManyDefaults.self)

@main struct Main {
    static func main() {
        precondition(registry.registrations.isEmpty)
        let source = "let value = TooManyDefaults()"
        let result = ConstExprRunner(registry: registry).rewrite(source: source)
        precondition(result.source == source)
    }
}
"""
