import Foundation

/// The command plugin passes a source-file snapshot, not a directory to crawl.
/// This preserves SwiftPM's target membership and excludes/resources decisions.
public struct RegistryGenerationRequest: Codable {
    public let packageDirectory: String
    public let outputDirectory: String
    public let module: String
    public let registryName: String
    public let sameModule: Bool
    public let check: Bool
    public let sourceFiles: [String]

    public init(
        packageDirectory: String, outputDirectory: String,
        module: String, registryName: String, sameModule: Bool,
        check: Bool, sourceFiles: [String]
    ) {
        self.packageDirectory = packageDirectory
        self.outputDirectory = outputDirectory
        self.module = module
        self.registryName = registryName
        self.sameModule = sameModule
        self.check = check
        self.sourceFiles = sourceFiles
    }
}

public enum RegistryGenerationCommand {
    public static func run(_ request: RegistryGenerationRequest) throws -> String {
        guard RegistryGenerator.isIdentifier(request.registryName) else {
            throw RegistryGenerationError.diagnostic("--registry-name must be a simple Swift identifier")
        }
        let files = FileManager.default
        let package = URL(fileURLWithPath: request.packageDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let directory = URL(fileURLWithPath: request.outputDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.path.hasPrefix(package.path + "/") else {
            throw RegistryGenerationError.diagnostic("the output directory must be a target directory inside this package")
        }
        let output = directory.appendingPathComponent(request.registryName + ".generated.swift")
        guard output.standardizedFileURL == output.resolvingSymlinksInPath() else {
            throw RegistryGenerationError.diagnostic("refusing to replace a symbolic-link output: \(output.path)")
        }
        var sources: [RegistryGenerator.Source] = []
        for path in request.sourceFiles {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(package.path + "/"), url.pathExtension == "swift" else {
                throw RegistryGenerationError.diagnostic("source is not a Swift file inside the selected package: \(path)")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.hasPrefix(RegistryGenerator.generatedHeader + "\n") { continue }
            sources.append(.init(path: String(url.path.dropFirst(package.path.count + 1)), text: source))
        }
        guard !sources.isEmpty else {
            throw RegistryGenerationError.diagnostic("the selected module has no non-generated Swift sources")
        }
        let generated = try RegistryGenerator.generate(
            module: request.module, registryName: request.registryName,
            sameModule: request.sameModule, sources: sources
        )
        let existing: String?
        if files.fileExists(atPath: output.path) {
            existing = try String(contentsOf: output, encoding: .utf8)
            let ownership = "\(RegistryGenerator.generatedHeader)\n// Module: \(request.module)\n// Registry: \(request.registryName)\n"
            guard existing?.hasPrefix(ownership) == true else {
                throw RegistryGenerationError.diagnostic("refusing to overwrite a file not owned by this registry generator: \(output.path)")
            }
        } else { existing = nil }
        if existing == generated { return "Registry is up to date: \(output.path)" }
        if request.check {
            throw RegistryGenerationError.diagnostic("registry is missing or stale: \(output.path); rerun generate-constexpr-registry without --check")
        }
        // Never create an unexpected target tree. SwiftPM supplied this existing
        // directory, and only this generator-owned file is replaced atomically.
        try generated.write(to: output, atomically: true, encoding: .utf8)
        return "Generated registry: \(output.path)"
    }
}
