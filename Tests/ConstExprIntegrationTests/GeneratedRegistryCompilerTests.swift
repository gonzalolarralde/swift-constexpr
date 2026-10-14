import ConstExprRegistryGeneration
import Foundation
import Testing

@Test func discoveredRegistryCompilesAcrossModulesAndEvaluatesSelectedDeclarations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConstExprRegistryCompiler-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = directory.appendingPathComponent("Model.swift")
    let registry = directory.appendingPathComponent("Registry.swift")
    let main = directory.appendingPathComponent("Main.swift")
    try registryCompilerModel.write(to: model, atomically: true, encoding: .utf8)
    let generated = try RegistryGenerator.generate(
        module: "FixtureModel", registryName: "Registry",
        sources: [.init(path: "Model.swift", text: registryCompilerModel)]
    )
    try generated.write(to: registry, atomically: true, encoding: .utf8)
    try registryCompilerMain.write(to: main, atomically: true, encoding: .utf8)
    let build = try activeSwiftPMBuildDirectory()
    let shims = try swiftSyntaxShims(startingAt: build)
    let common = [
        "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
        "-package-name", "RegistryCompilerFixture", "-I", directory.path,
        "-I", build.appendingPathComponent("Modules").path,
        "-Xcc", "-fmodule-map-file=\(shims.appendingPathComponent("module.modulemap").path)",
        "-Xcc", "-I", "-Xcc", shims.path,
        "-load-plugin-executable", "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
    ]
    let object = directory.appendingPathComponent("Model.o")
    let modelResult = try runRegistryFixtureProcess("/usr/bin/xcrun", common + [
        "-module-name", "FixtureModel", "-emit-module", "-emit-module-path",
        directory.appendingPathComponent("FixtureModel.swiftmodule").path,
        "-emit-object", model.path, "-o", object.path,
    ])
    try #require(modelResult.status == 0, Comment(rawValue: modelResult.output))
    let objects = try registryLinkedModules.flatMap { module in
        try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("\(module).build"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path }
    }
    let executable = directory.appendingPathComponent("Fixture")
    let hostResult = try runRegistryFixtureProcess("/usr/bin/xcrun", common + [
        "-module-name", "FixtureHost", registry.path, main.path, object.path,
    ] + objects.map(\.path) + ["-o", executable.path])
    try #require(hostResult.status == 0, Comment(rawValue: hostResult.output + "\n" + generated))
    let result = try runRegistryFixtureProcess(executable.path, [])
    #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test func discoveredInternalRegistryCompilesInTheSourceModule() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConstExprInternalRegistry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = """
    import ConstExpr
    @ConstExpr enum Internal { static func value() -> Int { 7 } }
    @main struct Main {
        static func main() {
            precondition(Registry.value.isValid)
            let result = ConstExprRunner(registry: Registry.value).rewrite(source: "let value = Internal.value()")
            precondition(result.source == "let value = 7", result.source)
        }
    }
    """
    let model = directory.appendingPathComponent("Model.swift")
    let registry = directory.appendingPathComponent("Registry.swift")
    try source.write(to: model, atomically: true, encoding: .utf8)
    try RegistryGenerator.generate(
        module: "FixtureModel", registryName: "Registry", sameModule: true,
        sources: [.init(path: "Model.swift", text: source)]
    ).write(to: registry, atomically: true, encoding: .utf8)
    let build = try activeSwiftPMBuildDirectory()
    let shims = try swiftSyntaxShims(startingAt: build)
    let objects = try registryLinkedModules.flatMap { module in
        try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("\(module).build"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path }
    }
    let executable = directory.appendingPathComponent("Fixture")
    let compilation = try runRegistryFixtureProcess("/usr/bin/xcrun", [
        "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
        "-module-name", "FixtureModel", "-I", build.appendingPathComponent("Modules").path,
        "-Xcc", "-fmodule-map-file=\(shims.appendingPathComponent("module.modulemap").path)",
        "-Xcc", "-I", "-Xcc", shims.path,
        "-load-plugin-executable", "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
        model.path, registry.path,
    ] + objects.map(\.path) + ["-o", executable.path])
    try #require(compilation.status == 0, Comment(rawValue: compilation.output))
    let result = try runRegistryFixtureProcess(executable.path, [])
    #expect(result.status == 0, Comment(rawValue: result.output))
}

private func runRegistryFixtureProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
}

private let registryLinkedModules = [
    "ConstExpr", "SwiftSyntax", "SwiftSyntax509", "SwiftSyntax510", "SwiftSyntax600",
    "SwiftSyntax601", "SwiftSyntax602", "SwiftSyntax603", "SwiftParser", "SwiftParserDiagnostics",
    "SwiftOperators", "SwiftSyntaxBuilder", "SwiftDiagnostics", "SwiftBasicFormat", "_SwiftSyntaxCShims",
]

private let registryCompilerModel = """
internal import ConstExpr
import Foundation

public typealias Count = Int

@ConstExpr(registrationAccess: .package)
public func convert(_ value: Count) -> Int { value + 1 }
@ConstExpr(registrationAccess: .package)
public func convert(_ value: String) -> Int { value.count }
@ConstExpr(registrationAccess: .package)
public func `repeat`(_ value: Int) -> Int { value * 2 }
@ConstExpr(registrationAccess: .package)
public let version = 7
@ConstExpr(registrationAccess: .package)
public func dataSize(_ value: Data) -> Int { value.count }

public struct Direct {
    private let value: Int
    @ConstExpr(registrationAccess: .package)
    public init(value: Int = 4) { self.value = value }
    @ConstExpr(registrationAccess: .package)
    public func adding(_ amount: Count) -> Int { value + amount }
    @ConstExpr(registrationAccess: .package)
    public var doubled: Int { value * 2 }
    @ConstExpr(registrationAccess: .package)
    public static var shared: Int { 8 }
    @ConstExpr(registrationAccess: .package)
    public subscript(index: Int) -> Int { value + index }
}
@ConstExprMembers(registrationAccess: .package)
public extension Direct {
    static func make(_ value: Int) -> Direct { Direct(value: value) }
    @ConstExprIgnored static func unsafe() -> Int { fatalError() }
    static func generic<T>(_ value: T) -> T { value }
}

@ConstExpr(registrationAccess: .package)
public struct Root {
    public let value: Int
    @ConstExpr(registrationAccess: .package)
    public init(_ value: Int) { self.value = value }
    @ConstExpr(registrationAccess: .package)
    public func doubled() -> Int { value * 2 }
    @ConstExpr(registrationAccess: .package)
    public enum Kind { case first, second }
}
@ConstExprMembers(named: "Extra", registrationAccess: .package)
public extension Root {
    static func answer() -> Int { 42 }
    @ConstExpr(registrationAccess: .package)
    static func explicit() -> Int { 43 }
}
"""

private let registryCompilerMain = #"""
import ConstExpr
import FixtureModel

@main struct Main {
    static func main() {
        precondition(Registry.value.isValid)
        precondition(Registry.value.registrations.contains { $0.name == "repeat" })
        precondition(Registry.value.registrations.contains { $0.name == "dataSize" })
        precondition(Registry.value.registrations.filter { $0.ownerType == Root.Kind.self }.count == 2)
        let result = ConstExprRunner(registry: Registry.value).rewrite(source: """
        let int = convert(4)
        let string = convert("abc")
        let global = version
        let added = Direct(value: 5).adding(3)
        let doubled = Direct().doubled
        let indexed = Direct(value: 5)[2]
        let shared = Direct.shared
        let made = Direct.make(8).doubled
        let root = Root(6).doubled()
        let fragment = Root.answer()
        let explicit = Root.explicit()
        let kind = Root.Kind.first
        """)
        precondition(result.diagnostics.isEmpty, String(describing: result.diagnostics))
        for expected in [
            "let int = 5", "let string = 3", "let global = 7",
            "let added = 8", "let doubled = 8", "let indexed = 7", "let shared = 8",
            "let made = 16", "let root = 12", "let fragment = 42", "let explicit = 43",
        ] { precondition(result.source.contains(expected), result.source) }
    }
}
"""#
