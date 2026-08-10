import SwiftSyntax
import Testing
@testable import ConstExpr

private protocol RunnerPrivateProtocol {}

private struct RunnerPrivateProtocolValue: RunnerPrivateProtocol, ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "RunnerPrivateProtocolValue()"
    }
}

private class RunnerPrivateBase {}

private final class RunnerPrivateDerived: RunnerPrivateBase, ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "RunnerPrivateDerived()"
    }
}

@Test func runnerRendersNonNilPrivateExistentialAndClassOptionals() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeRunnerPrivateExistential",
            kind: .function,
            resultType: ((any RunnerPrivateProtocol)?).self
        ) { _, _ in
            let existential: (any RunnerPrivateProtocol)? = RunnerPrivateProtocolValue()
            return ConstExprValue(
                existential as Any,
                preservingStaticType: ((any RunnerPrivateProtocol)?).self,
                sourceTypeName: "(any RunnerPrivateProtocol)?"
            )
        },
        ConstExprRegistration(
            name: "makeRunnerPrivateUpcast",
            kind: .function,
            resultType: RunnerPrivateBase?.self
        ) { _, _ in
            let upcast: RunnerPrivateBase? = RunnerPrivateDerived()
            return ConstExprValue(
                upcast as Any,
                preservingStaticType: RunnerPrivateBase?.self,
                sourceTypeName: "RunnerPrivateBase?"
            )
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let existential = makeRunnerPrivateExistential()
        let upcast = makeRunnerPrivateUpcast()
        """)

    #expect(result.source == """
        let existential = (RunnerPrivateProtocolValue()) as (any RunnerPrivateProtocol)?
        let upcast = (RunnerPrivateDerived()) as RunnerPrivateBase?
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func runnerRejectsInvalidExplicitSourceTypeNamesWithoutEmittingRecoveredSyntax() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeInvalidRunnerPrivateUpcast",
            kind: .function,
            resultType: RunnerPrivateBase.self
        ) { _, _ in
            return ConstExprValue(
                RunnerPrivateDerived() as Any,
                preservingStaticType: RunnerPrivateBase.self,
                sourceTypeName: "not a type @"
            )
        },
        ConstExprRegistration(
            name: "makeInvalidRunnerPrivateOptional",
            kind: .function,
            resultType: RunnerPrivateBase?.self
        ) { _, _ in
            let upcast: RunnerPrivateBase? = RunnerPrivateDerived()
            return ConstExprValue(
                upcast as Any,
                preservingStaticType: RunnerPrivateBase?.self,
                sourceTypeName: "not a type @"
            )
        },
    ])
    let source = """
        let upcast = makeInvalidRunnerPrivateUpcast()
        let optional = makeInvalidRunnerPrivateOptional()
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}
