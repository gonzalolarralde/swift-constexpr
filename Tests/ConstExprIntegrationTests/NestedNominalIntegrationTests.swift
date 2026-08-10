import ConstExpr
import Testing

private struct ConstExprNestedContainer {
    @ConstExpr
    struct Value {
        let rawValue: Int

        init(_ rawValue: Int) {
            self.rawValue = rawValue
        }

        func doubled() -> Int {
            rawValue * 2
        }
    }
}

private let nestedNominalRegistry = #constExprRegistry(
    ConstExprNestedContainer.Value.self
)

@Test func nestedNongenericNominalPeersCompileRegisterAndEvaluate() {
    let result = ConstExprRunner(registry: nestedNominalRegistry).rewrite(
        source: "let value = ConstExprNestedContainer.Value(3).doubled()"
    )

    #expect(result.source == "let value = 6")
    #expect(result.diagnostics.isEmpty)
}
