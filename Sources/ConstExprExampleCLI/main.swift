import ConstExpr
import ConstExprExampleRegistry
import Foundation

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case input(String)
    case output(String)

    var exitCode: Int32 {
        switch self {
        case .usage: 64
        case .input: 66
        case .output: 74
        }
    }

    var shouldShowUsage: Bool {
        if case .usage = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .usage(let message), .input(let message), .output(let message):
            message
        }
    }
}

private struct Arguments {
    var inputPath: String?
    var outputPath: String?
    var failOnDiagnostics = false
    var showHelp = false

    static func parse(_ raw: [String]) throws -> Self {
        var result = Self()
        var index = 0
        var parsesOptions = true

        while index < raw.count {
            let argument = raw[index]
            switch (parsesOptions, argument) {
            case (true, "--"):
                parsesOptions = false
            case (true, "-h"), (true, "--help"):
                result.showHelp = true
            case (true, "--fail-on-diagnostics"):
                result.failOnDiagnostics = true
            case (true, "-o"), (true, "--output"):
                index += 1
                guard index < raw.count else {
                    throw CLIError.usage("\(argument) requires a path")
                }
                guard result.outputPath == nil else {
                    throw CLIError.usage("output path was specified more than once")
                }
                let path = raw[index]
                guard path == "-" || !path.hasPrefix("-") else {
                    throw CLIError.usage("\(argument) requires a path")
                }
                result.outputPath = path
            case (_, "-"):
                guard result.inputPath == nil else {
                    throw CLIError.usage("input was specified more than once")
                }
                result.inputPath = argument
            default:
                if parsesOptions, argument.hasPrefix("-") {
                    throw CLIError.usage("unknown option: \(argument)")
                }
                guard result.inputPath == nil else {
                    throw CLIError.usage("input was specified more than once")
                }
                result.inputPath = argument
            }
            index += 1
        }

        return result
    }
}

private let usage = """
Usage: swift-constexpr-example [--output <path>] [--fail-on-diagnostics] [file|-]

Rewrites stdin when file is omitted or is '-'. Rewritten source is written to
stdout unless --output is supplied; '--output -' also means stdout. Use '--'
before an input path that begins with '-'. This executable is linked to the
package's example ConstExpr registry. Input and output are UTF-8.

Exit status: 0 on success, 1 for an unexpected internal failure, 2 when
--fail-on-diagnostics observes any diagnostic, 64 for invalid arguments, 66 for
unreadable input, and 74 for unwritable output.
"""

private func decodeUTF8(_ data: Data, description: String) throws -> String {
    guard var source = String(data: data, encoding: .utf8) else {
        throw CLIError.input("\(description) is not valid UTF-8")
    }

    // Foundation consumes an initial UTF-8 byte-order mark while decoding.
    // Keep it as U+FEFF in the in-memory source so ConstExprRunner can preserve
    // the original encoding marker in rewritten output.
    let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.starts(with: utf8BOM), source.first != "\u{FEFF}" {
        source.insert("\u{FEFF}", at: source.startIndex)
    }
    return source
}

private func readInput(path: String?) throws -> (source: String, fileName: String) {
    guard let path, path != "-" else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let source = try decodeUTF8(data, description: "stdin")
        return (source, "<stdin>")
    }

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return (try decodeUTF8(data, description: "'\(path)'"), path)
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError.input("could not read '\(path)': \(error)")
    }
}

private func write(_ text: String, to path: String?) throws {
    guard let path, path != "-" else {
        FileHandle.standardOutput.write(Data(text.utf8))
        return
    }

    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        throw CLIError.output("could not write '\(path)': \(error)")
    }
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    if arguments.showHelp {
        print(usage)
        exit(0)
    }

    let input = try readInput(path: arguments.inputPath)
    let rewrite = ConstExprRunner(registry: exampleConstExprRegistry).rewrite(
        source: input.source,
        fileName: input.fileName
    )

    try write(rewrite.source, to: arguments.outputPath)
    for diagnostic in rewrite.diagnostics {
        writeError(diagnostic.description)
    }

    if arguments.failOnDiagnostics, !rewrite.diagnostics.isEmpty {
        exit(2)
    }
} catch let error as CLIError {
    writeError("error: \(error)")
    if error.shouldShowUsage {
        writeError(usage)
    }
    exit(error.exitCode)
} catch {
    writeError("error: \(error)")
    exit(1)
}
