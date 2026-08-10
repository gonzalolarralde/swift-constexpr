import ConstExpr
import Foundation
import ManifestValuesConstExprProvider
import PackageDescriptionConstExprProvider

private enum DriverError: Error, CustomStringConvertible {
    case usage
    case invalidUTF8(String)

    var description: String {
        switch self {
        case .usage:
            "usage: ConstExprConsumerDriver <input> <output>"
        case .invalidUTF8(let path):
            "input is not valid UTF-8: \(path)"
        }
    }
}

private func readSource(at path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard var source = String(data: data, encoding: .utf8) else {
        throw DriverError.invalidUTF8(path)
    }
    let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.starts(with: byteOrderMark), source.first != "\u{FEFF}" {
        source.insert("\u{FEFF}", at: source.startIndex)
    }
    return source
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else { throw DriverError.usage }

    let inputPath = arguments[0]
    let outputPath = arguments[1]
    let registry = packageDescriptionConstExprRegistry
        .appending(contentsOf: manifestValuesConstExprRegistry)
    let result = ConstExprRunner(registry: registry).rewrite(
        source: try readSource(at: inputPath),
        fileName: inputPath
    )

    try result.source.write(
        toFile: outputPath,
        atomically: true,
        encoding: .utf8
    )
    for diagnostic in result.diagnostics {
        writeError(diagnostic.description)
    }
    // Warning-level diagnostics describe conservative fallback: the original
    // expression remains in the staged source for Swift or SwiftPM to resolve.
    // Only registry/source errors make the generated stage unusable.
    if result.hasErrors {
        exit(2)
    }
} catch {
    writeError("error: \(error)")
    exit(1)
}
