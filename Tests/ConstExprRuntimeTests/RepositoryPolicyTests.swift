import Foundation
import Testing

@Test func handWrittenSwiftFilesStayWithinTheRepositoryLineLimit() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fileManager = FileManager.default
    var violations: [String] = []

    for directoryName in ["Sources", "Tests", "Examples"] {
        let directory = repositoryRoot.appendingPathComponent(directoryName)
        guard let files = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for case let file as URL in files where file.pathExtension == "swift" {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let data = try Data(contentsOf: file)
            let newlineCount = data.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            let lineCount = newlineCount + (data.isEmpty || data.last == 0x0A ? 0 : 1)
            if lineCount > 500 {
                let path = file.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
                violations.append("\(path): \(lineCount) lines")
            }
        }
    }

    violations.sort()
    #expect(
        violations.isEmpty,
        Comment(rawValue: "Swift files exceed 500 lines:\n\(violations.joined(separator: "\n"))")
    )
}
