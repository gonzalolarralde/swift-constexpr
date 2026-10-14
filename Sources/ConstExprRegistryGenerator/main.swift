import ConstExprRegistryGeneration
import Foundation

do {
    guard CommandLine.arguments.count == 2 else {
        throw RegistryGenerationError.diagnostic("use swift package generate-constexpr-registry --module <target> --output-target <target> [--registry-name <name>] [--check]")
    }
    let request = try JSONDecoder().decode(
        RegistryGenerationRequest.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    )
    print(try RegistryGenerationCommand.run(request))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
