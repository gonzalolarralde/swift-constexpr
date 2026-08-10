import ConstExpr
import Foundation
import Testing

@ConstExpr
private func makeLabeledTupleStaticTypeFixture() -> (x: Int, y: Int) {
    (x: 3, y: 4)
}

private let labeledTupleStaticTypeRegistry = #constExprRegistry(
    makeLabeledTupleStaticTypeFixture
)

private func typecheckLabeledTupleRewrite(_ source: String) throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprLabeledTuple-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Rewritten.swift")
    try source.write(to: input, atomically: true, encoding: .utf8)

    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors", input.path,
    ]
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let error = String(
        data: standardError.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    return (process.terminationStatus, error)
}

@Test func generatedLabeledTupleResultsRetainLabelsAndProjectConstants() throws {
    let result = ConstExprRunner(registry: labeledTupleStaticTypeRegistry).rewrite(
        source: """
            let tuple = makeLabeledTupleStaticTypeFixture()
            let projection = makeLabeledTupleStaticTypeFixture().x
            """
    )

    #expect(!result.source.contains("makeLabeledTupleStaticTypeFixture"))
    #expect(result.source.contains("let projection = 3"))
    #expect(result.diagnostics.isEmpty)

    let typecheck = try typecheckLabeledTupleRewrite(result.source + """

        let proof: Int = tuple.x + projection
        """)
    #expect(typecheck.0 == 0)
    #expect(typecheck.1.isEmpty)
}
