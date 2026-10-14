import ConstExprRegistryGeneration
import Foundation
import Testing

private struct RegistryFileFixture {
    let directory: URL
    let model: URL
    let outputDirectory: URL
    var output: URL { outputDirectory.appendingPathComponent("Registry.generated.swift") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConstExprRegistryFiles-\(UUID().uuidString)")
        model = directory.appendingPathComponent("Sources/Model/Model.swift")
        outputDirectory = directory.appendingPathComponent("Sources/Host")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try writeModel("@ConstExpr public enum Value {}")
    }

    func writeModel(_ text: String) throws {
        try text.write(to: model, atomically: true, encoding: .utf8)
    }

    func request(check: Bool = false, name: String = "Registry", sources: [String]? = nil, output: URL? = nil) -> RegistryGenerationRequest {
        .init(
            packageDirectory: directory.path, outputDirectory: (output ?? outputDirectory).path,
            module: "Model", registryName: name, sameModule: false, check: check,
            sourceFiles: sources ?? [model.path]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test func registryCheckNeverWritesAndUnchangedGenerationKeepsTimestamp() throws {
    let fixture = try RegistryFileFixture()
    defer { fixture.remove() }
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(check: true))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(try RegistryGenerationCommand.run(fixture.request()).hasPrefix("Generated registry:"))
    let original = try String(contentsOf: fixture.output, encoding: .utf8)
    let sentinel = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: fixture.output.path)
    #expect(try RegistryGenerationCommand.run(fixture.request()).hasPrefix("Registry is up to date:"))
    #expect(try RegistryGenerationCommand.run(fixture.request(check: true)).hasPrefix("Registry is up to date:"))
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.output.path)[.modificationDate] as? Date == sentinel)
    try fixture.writeModel("@ConstExpr public enum Changed {}")
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(check: true))
    }
    #expect(try String(contentsOf: fixture.output, encoding: .utf8) == original)
    _ = try RegistryGenerationCommand.run(fixture.request())
    #expect(try String(contentsOf: fixture.output, encoding: .utf8).contains("Model.Changed.self"))
}

@Test func invalidSourceDoesNotReplaceAnExistingRegistry() throws {
    let fixture = try RegistryFileFixture()
    defer { fixture.remove() }
    _ = try RegistryGenerationCommand.run(fixture.request())
    let original = try Data(contentsOf: fixture.output)
    try fixture.writeModel("@ConstExpr public var mutable = 1")
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request())
    }
    #expect(try Data(contentsOf: fixture.output) == original)
}

@Test func generationRefusesHandwrittenAndDifferentlyOwnedFiles() throws {
    let fixture = try RegistryFileFixture()
    defer { fixture.remove() }
    for text in [
        "// Handwritten registry\nenum Registry {}\n",
        RegistryGenerator.generatedHeader + "\n// Module: Other\n// Registry: Registry\n",
    ] {
        try text.write(to: fixture.output, atomically: true, encoding: .utf8)
        #expect(throws: RegistryGenerationError.self) {
            try RegistryGenerationCommand.run(fixture.request())
        }
        #expect(try String(contentsOf: fixture.output, encoding: .utf8) == text)
    }
}

@Test func generationRefusesSymlinksAndPathsOutsideTheSelectedPackage() throws {
    let fixture = try RegistryFileFixture()
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(at: fixture.output, withDestinationURL: fixture.model)
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request())
    }
    #expect(try String(contentsOf: fixture.model, encoding: .utf8) == "@ConstExpr public enum Value {}")
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(output: fixture.directory.deletingLastPathComponent()))
    }
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(name: "../Outside"))
    }
}

@Test func sourceSnapshotHonorsMembershipAndSkipsGeneratedRegistries() throws {
    let fixture = try RegistryFileFixture()
    defer { fixture.remove() }
    let excluded = fixture.model.deletingLastPathComponent().appendingPathComponent("Excluded.swift")
    try "not valid Swift!".write(to: excluded, atomically: true, encoding: .utf8)
    _ = try RegistryGenerationCommand.run(fixture.request())
    #expect(try RegistryGenerationCommand.run(fixture.request(sources: [fixture.model.path, fixture.output.path]))
        .hasPrefix("Registry is up to date:"))
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(sources: [fixture.model.path, excluded.path]))
    }
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerationCommand.run(fixture.request(sources: [fixture.directory.deletingLastPathComponent().appendingPathComponent("Outside.swift").path]))
    }
}
