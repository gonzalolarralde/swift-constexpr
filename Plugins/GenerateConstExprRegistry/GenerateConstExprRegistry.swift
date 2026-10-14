import Foundation
import PackagePlugin

@main
struct GenerateConstExprRegistry: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var options = ArgumentExtractor(arguments)
        if options.extractFlag(named: "help") > 0 {
            print("""
            Generate a target's ConstExpr registry without building or executing that target.
            Usage: swift package generate-constexpr-registry --module <target> --output-target <target>
                   [--registry-name <name>] [--check]
            --check fails for missing/stale output and never writes package files.
            Output: <output-target directory>/<registry-name>.generated.swift
            The default registry name is <source module>GeneratedRegistry.
            """)
            return
        }
        let modules = options.extractOption(named: "module")
        let outputs = options.extractOption(named: "output-target")
        let names = options.extractOption(named: "registry-name")
        let check = options.extractFlag(named: "check") > 0
        guard modules.count == 1, outputs.count == 1, names.count <= 1,
              options.remainingArguments.isEmpty else {
            throw Failure("specify exactly one --module and --output-target; optional flags are --registry-name and --check")
        }
        let targets = context.package.targets.compactMap { $0 as? SwiftSourceModuleTarget }
        let matches = targets.filter { $0.name == modules[0] || $0.moduleName == modules[0] }
        guard matches.count == 1, let source = matches.first else {
            throw Failure("--module must select one Swift source target in this package: \(modules[0])")
        }
        guard let output = targets.first(where: { $0.name == outputs[0] }) else {
            throw Failure("--output-target must name a Swift source target in this package: \(outputs[0])")
        }
        if source.id != output.id && !output.dependencies.contains(where: {
            if case .target(let target) = $0 { return target.id == source.id }
            return false
        }) {
            throw Failure("\(output.name) must directly depend on \(source.name); the generator does not modify Package.swift")
        }
        guard source.pluginGeneratedSources.isEmpty else {
            throw Failure("the selected target has build-generated sources; use a manually composed registry until those providers have an explicit source-discovery workflow")
        }
        let registryName = names.first ?? source.moduleName + "GeneratedRegistry"
        let request: [String: Any] = [
            "packageDirectory": context.package.directoryURL.path,
            "outputDirectory": output.directoryURL.path,
            "module": source.moduleName,
            "registryName": registryName,
            "sameModule": source.id == output.id,
            "check": check,
            "sourceFiles": source.sourceFiles(withSuffix: "swift").map { $0.url.path }.sorted(),
        ]
        let requestURL = context.pluginWorkDirectoryURL.appendingPathComponent("registry-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: requestURL) }
        let tool = try context.tool(named: "ConstExprRegistryGenerator")
        let process = Process()
        process.executableURL = tool.url
        process.arguments = [requestURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure("registry generation failed; see the diagnostics above")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
