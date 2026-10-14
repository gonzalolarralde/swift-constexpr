import Foundation
import Testing

private let embeddedCompiler = ProcessInfo.processInfo.environment["CONSTEXPR_EMBEDDED_SWIFTC"]

@Test func sharedAnnotationsStillGenerateHostRegistrations() throws {
    let directory = try embeddedFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Fixture.swift")
    try embeddedAnnotatedSource.write(to: source, atomically: true, encoding: .utf8)
    let build = try activeSwiftPMBuildDirectory()
    let result = try runEmbeddedFixture("/usr/bin/xcrun", [
        "swiftc", "-typecheck", "-parse-as-library", "-warnings-as-errors",
        "-package-name", "EmbeddedCompatibility", "-I", build.appendingPathComponent("Modules").path,
        "-load-plugin-executable", "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
        source.path,
    ])
    #expect(result.status == 0, Comment(rawValue: result.output))
}

@Test(
    .enabled(if: embeddedCompiler != nil, "Set CONSTEXPR_EMBEDDED_SWIFTC to an Embedded-capable swiftc"),
    arguments: ["armv6m-none-none-eabi", "armv7em-none-none-eabi"]
)
func embeddedAnnotationsNeedNoHostLibraries(target: String) throws {
    let compiler = try #require(embeddedCompiler)
    let directory = try embeddedFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let moduleSources = try #require(FileManager.default.enumerator(
        at: root.appendingPathComponent("Sources/ConstExpr"),
        includingPropertiesForKeys: nil
    )).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let build = try activeSwiftPMBuildDirectory()
    let common = [
        "-target", target, "-enable-experimental-feature", "Embedded", "-wmo", "-Osize",
        "-parse-as-library", "-swift-version", "6", "-warnings-as-errors", "-package-name", "EmbeddedCompatibility",
        "-load-plugin-executable", "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
    ]
    // No host module search path: importing Foundation or SwiftSyntax here must fail.
    let module = try runEmbeddedFixture(compiler, common + [
        "-module-name", "ConstExpr", "-emit-module", "-emit-module-path",
        directory.appendingPathComponent("ConstExpr.swiftmodule").path,
        "-emit-object", "-o", directory.appendingPathComponent("ConstExpr.o").path,
    ] + moduleSources.map(\.path))
    try #require(module.status == 0, Comment(rawValue: module.output))

    // Embedded forbids library evolution, so its diagnostic-only textual
    // interface is emitted separately without promoting that expected warning.
    // The real module and consumer compilations above/below remain warning-free.
    let interface = directory.appendingPathComponent("ConstExpr.swiftinterface")
    let surface = try runEmbeddedFixture(compiler, common.filter { $0 != "-warnings-as-errors" } + [
        "-module-name", "ConstExpr", "-emit-module", "-emit-module-path",
        directory.appendingPathComponent("ConstExpr.swiftmodule").path,
        "-emit-module-interface-path", interface.path,
    ] + moduleSources.map(\.path))
    try #require(surface.status == 0, Comment(rawValue: surface.output))
    let publicAPI = try String(contentsOf: interface, encoding: .utf8)
    for forbidden in ["Foundation", "SwiftSyntax", "ConstExprEvaluation", "ConstExprRegistry", "RegistrationProviding"] {
        #expect(!publicAPI.contains(forbidden), "Embedded interface contains \(forbidden)")
    }
    #expect(publicAPI.contains("ConstExprNoOpPeerMacro"))
    #expect(publicAPI.contains("ConstExprNoOpMemberMacro"))

    let fixture = directory.appendingPathComponent("Fixture.swift")
    try embeddedAnnotatedSource.write(to: fixture, atomically: true, encoding: .utf8)
    let sil = directory.appendingPathComponent("Fixture.sil")
    let consumer = try runEmbeddedFixture(compiler, common + [
        "-module-name", "EmbeddedFixture", "-I", directory.path,
        "-emit-sil", "-o", sil.path, fixture.path,
    ])
    try #require(consumer.status == 0, Comment(rawValue: consumer.output))
    let output = try String(contentsOf: sil, encoding: .utf8)
    for forbidden in ["Foundation", "SwiftSyntax", "ConstExprEvaluation", "__constExpr", "RegistrationProviding"] {
        #expect(!output.contains(forbidden), "Embedded output contains \(forbidden)")
    }

    let unavailable = directory.appendingPathComponent("Unavailable.swift")
    try "import ConstExpr\nlet registry = ConstExprRegistry()\n".write(
        to: unavailable, atomically: true, encoding: .utf8
    )
    let rejected = try runEmbeddedFixture(compiler, common + [
        "-typecheck", "-I", directory.path, unavailable.path,
    ])
    #expect(rejected.status != 0)
    #expect(rejected.output.contains("cannot find 'ConstExprRegistry' in scope"))
}

@Test func annotationTargetHasOnlyACompilerPluginDependency() throws {
    let directory = try embeddedFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let package = try runEmbeddedFixture("/usr/bin/xcrun", [
        "swift", "package", "--package-path", root.path,
        "--scratch-path", directory.appendingPathComponent("Build").path, "dump-package",
    ])
    try #require(package.status == 0, Comment(rawValue: package.output))
    let json = try #require(JSONSerialization.jsonObject(with: Data(package.output.utf8)) as? [String: Any])
    let targets = try #require(json["targets"] as? [[String: Any]])
    let target = try #require(targets.first { $0["name"] as? String == "ConstExpr" })
    let dependencies = try #require(target["dependencies"] as? [[String: Any]])
    #expect(dependencies.count == 1)
    let dependency = try #require(dependencies.first?["byName"] as? [Any])
    #expect(dependency.first as? String == "ConstExprMacros")
}

@Test(.enabled(if: embeddedCompiler != nil, "Set CONSTEXPR_EMBEDDED_SWIFTC to exercise its host compiler too"))
func embeddedToolchainCanBuildTheHostValueRuntime() throws {
    let compiler = try #require(embeddedCompiler)
    let directory = try embeddedFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let sources = try #require(FileManager.default.enumerator(
        at: root.appendingPathComponent("Sources/ConstExpr"), includingPropertiesForKeys: nil
    )).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let sdk = try runEmbeddedFixture("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
    try #require(sdk.status == 0, Comment(rawValue: sdk.output))
    let build = try activeSwiftPMBuildDirectory()
    let object = directory.appendingPathComponent("ConstExpr.o")
    let common = [
        "-sdk", sdk.output.trimmingCharacters(in: .whitespacesAndNewlines),
        "-O", "-wmo", "-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
        "-package-name", "EmbeddedCompatibility",
        "-load-plugin-executable", "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
    ]
    // Host compilation must not inherit Embedded. This also catches the
    // snapshot's region-analysis crash for existential metadata getters.
    let module = try runEmbeddedFixture(compiler, common + [
        "-module-name", "ConstExpr", "-emit-module", "-emit-module-path",
        directory.appendingPathComponent("ConstExpr.swiftmodule").path,
        "-emit-object", "-o", object.path,
    ] + sources.map(\.path))
    try #require(module.status == 0, Comment(rawValue: module.output))
    let fixture = directory.appendingPathComponent("Host.swift")
    try """
    import ConstExpr
    @main struct Host {
        static func main() {
            let value = ConstExprValue(Optional<Int>.none)
            precondition(value.isNil && value.optionalWrappedType == Int.self)
            precondition(ConstExprValue([1, 2]).arrayElements?.count == 2)
        }
    }
    """.write(to: fixture, atomically: true, encoding: .utf8)
    let executable = directory.appendingPathComponent("Host")
    let consumer = try runEmbeddedFixture(compiler, common + [
        "-I", directory.path, fixture.path, object.path, "-o", executable.path,
    ])
    try #require(consumer.status == 0, Comment(rawValue: consumer.output))
    let run = try runEmbeddedFixture(executable.path, [])
    #expect(run.status == 0, Comment(rawValue: run.output))
}

private func embeddedFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConstExprEmbedded-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func runEmbeddedFixture(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, text)
}

private let embeddedAnnotatedSource = """
import ConstExpr

@ConstExpr(registrationAccess: .package)
public struct Sample {
    public let number: UInt16
    public init(_ number: UInt16) { self.number = number }
    @ConstExprIgnored public static func ignored() -> Int { 0 }
}
@ConstExprMembers(registrationAccess: .package)
public extension Sample {
    func doubled() -> UInt16 { number &* 2 }
}
@ConstExprMembers(named: "Extras", registrationAccess: .package)
public extension Sample {
    static func constant() -> UInt16 { 42 }
}
@ConstExpr public func encode(_ value: UInt16) -> UInt16 { Sample(value).doubled() }
@_cdecl("probe") public func probe() -> UInt16 { encode(7) &+ Sample.constant() }

#if !hasFeature(Embedded)
let registrations = #constExprRegistry(encode(_:), Sample.self)
let extra = #constExprRegistry(for: Sample.self, extensions: ["Extras"])
#endif
"""
