import ConstExpr
import Testing

private protocol DescriptorCornerP: Sendable {}
private protocol DescriptorCornerQ: Sendable {}
private protocol DescriptorCornerClassP: AnyObject {}
private protocol DescriptorCornerClassQ: AnyObject {}

extension Int: DescriptorCornerP, DescriptorCornerQ {}

private struct DescriptorCornerValue: DescriptorCornerP, DescriptorCornerQ {}

private class DescriptorCornerBase:
    DescriptorCornerP,
    DescriptorCornerQ,
    @unchecked Sendable
{}
private final class DescriptorCornerDerived:
    DescriptorCornerBase,
    @unchecked Sendable
{}

private final class DescriptorCornerClassValue:
    DescriptorCornerClassP,
    DescriptorCornerClassQ
{}

@ConstExpr
private func makeDescriptorCornerBase() -> DescriptorCornerBase {
    DescriptorCornerDerived()
}

@ConstExpr
private func makeDescriptorCornerValueComposition() -> any DescriptorCornerP & DescriptorCornerQ {
    DescriptorCornerValue()
}

@ConstExpr
private func makeDescriptorCornerClassComposition()
    -> any DescriptorCornerClassP & DescriptorCornerClassQ
{
    DescriptorCornerClassValue()
}

@ConstExpr
private func consumeDescriptorCornerComposition(
    _ value: any DescriptorCornerP & DescriptorCornerQ
) -> String {
    _ = value
    return "composition"
}

@ConstExpr
private func classifyDescriptorCornerComposition(_ value: AnyObject) -> String {
    _ = value
    return "anyObject"
}

@ConstExpr
private func classifyDescriptorCornerComposition(_ value: Any) -> String {
    _ = value
    return "any"
}

@ConstExpr
private func makeDescriptorCornerNested()
    -> [[String: (any DescriptorCornerP & DescriptorCornerQ)?]?]
{
    [["value": 12]]
}

@ConstExpr
private func consumeDescriptorCornerNested(
    _ value: [[String: (any DescriptorCornerP & DescriptorCornerQ)?]?]
) -> Int {
    value.count
}

private let descriptorCornerErasedSeed: any DescriptorCornerP & DescriptorCornerQ = 13

@ConstExpr
private let descriptorCornerInferredExistential = descriptorCornerErasedSeed

private let descriptorCornerRegistry = #constExprRegistry(
    makeDescriptorCornerBase,
    makeDescriptorCornerValueComposition,
    makeDescriptorCornerClassComposition,
    consumeDescriptorCornerComposition(_:),
    classifyDescriptorCornerComposition(_:) as (AnyObject) -> String,
    classifyDescriptorCornerComposition(_:) as (Any) -> String,
    makeDescriptorCornerNested,
    consumeDescriptorCornerNested(_:),
    descriptorCornerInferredExistential
)

@Test func generatedCompositionAndNestedDescriptorsDriveRealConversions() throws {
    let inferred = try #require(
        descriptorCornerRegistry.registrations.first {
            $0.name == "descriptorCornerInferredExistential"
        }
    )
    #expect(
        ObjectIdentifier(inferred.resultType)
            == ObjectIdentifier((any DescriptorCornerP & DescriptorCornerQ).self)
    )
    let inferredValue = try inferred.invoke()
    #expect(
        ObjectIdentifier(inferredValue.staticType)
            == ObjectIdentifier((any DescriptorCornerP & DescriptorCornerQ).self)
    )

    let result = ConstExprRunner(registry: descriptorCornerRegistry).rewrite(
        source: """
            let concrete = consumeDescriptorCornerComposition(makeDescriptorCornerBase())
            let valueComposition = classifyDescriptorCornerComposition(makeDescriptorCornerValueComposition())
            let classComposition = classifyDescriptorCornerComposition(makeDescriptorCornerClassComposition())
            let nested = consumeDescriptorCornerNested(makeDescriptorCornerNested())
            let inferred = consumeDescriptorCornerComposition(descriptorCornerInferredExistential)
            """
    )

    #expect(result.source == """
        let concrete = "composition"
        let valueComposition = "any"
        let classComposition = "anyObject"
        let nested = 1
        let inferred = "composition"
        """)
    #expect(result.diagnostics.isEmpty)
}

// These deliberately shadow standard-library container spellings. A syntax-
// only macro cannot prove which declaration an unqualified generic refers to,
// so it emits the conservative structural descriptor and runtime validation
// must reject the mismatch before overload resolution can use it.
private struct Optional<Wrapped> {
    let wrapped: Wrapped
}

private struct Array<Element> {
    let element: Element
}

private struct Dictionary<Key, Value> {
    let key: Key
    let value: Value
}

@ConstExpr
private func shadowedOptionalDescriptor(
    _ value: Optional<Int>
) -> Optional<Int> {
    value
}

@ConstExpr
private func shadowedArrayDescriptor(_ value: Array<Int>) -> Array<Int> {
    value
}

@ConstExpr
private func shadowedDictionaryDescriptor(
    _ value: Dictionary<String, Int>
) -> Dictionary<String, Int> {
    value
}

private let shadowedContainerDescriptorRegistry = #constExprRegistry(
    shadowedOptionalDescriptor(_:),
    shadowedArrayDescriptor(_:),
    shadowedDictionaryDescriptor(_:)
)

@Test func shadowedUnqualifiedContainersAreRejectedBeforeRanking() {
    let diagnostics = shadowedContainerDescriptorRegistry.validationDiagnostics

    #expect(!shadowedContainerDescriptorRegistry.isValid)
    #expect(diagnostics.count == 6)
    #expect(diagnostics.allSatisfy { $0.code == "invalid-registration" })
    #expect(
        diagnostics.filter { $0.message.contains("parameter type descriptor") }.count == 3
    )
    #expect(
        diagnostics.filter { $0.message.contains("result type descriptor") }.count == 3
    )
}
