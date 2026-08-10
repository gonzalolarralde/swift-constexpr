import SwiftSyntax

extension ConstExprSourceEvaluator {
    /// Narrows an outer overload set from the syntax of a contextual
    /// leading-dot argument without executing any registration. This models
    /// the bidirectional constraint needed for shapes such as an overloaded
    /// `package(url:_:)` receiving `.upToNextMajor(from:)`: only parameter
    /// types that own a label-compatible contextual factory remain.
    func narrowingRegistrationsByContextualArgumentShape(
        _ registrations: [ConstExprRegistration],
        labels: [String?],
        arguments: LabeledExprListSyntax
    ) -> [ConstExprRegistration] {
        var narrowed = registrations
        guard narrowed.count > 1 else { return narrowed }

        for (argumentIndex, argument) in arguments.enumerated() {
            guard agreedArgumentType(
                registrations: narrowed,
                labels: labels,
                argumentIndex: argumentIndex
            ) == nil else { continue }

            let parameterTypes = distinctParameterTypes(
                registrations: narrowed,
                labels: labels,
                argumentIndex: argumentIndex
            )
            guard parameterTypes.count > 1 else { continue }
            let compatible = parameterTypes.filter {
                contextualOperation(
                    argument.expression,
                    canProduce: $0
                )
            }
            guard !compatible.isEmpty, compatible.count < parameterTypes.count else {
                continue
            }
            let compatibleIDs = Set(compatible.map(ObjectIdentifier.init))
            let filtered = narrowed.filter { registration in
                guard let mapping = argumentMapping(
                    for: registration,
                    labels: labels
                ),
                    let parameterIndex = mapping.firstIndex(where: {
                        $0 == argumentIndex
                    })
                else { return false }
                return compatibleIDs.contains(ObjectIdentifier(
                    registration.parameterTypes[parameterIndex]
                ))
            }
            if !filtered.isEmpty { narrowed = filtered }
        }
        return narrowed
    }

    private func distinctParameterTypes(
        registrations: [ConstExprRegistration],
        labels: [String?],
        argumentIndex: Int
    ) -> [Any.Type] {
        var identifiers: Set<ObjectIdentifier> = []
        var result: [Any.Type] = []
        for registration in registrations {
            guard let mapping = argumentMapping(for: registration, labels: labels),
                  let parameterIndex = mapping.firstIndex(where: {
                      $0 == argumentIndex
                  })
            else { continue }
            let type = registration.parameterTypes[parameterIndex]
            if identifiers.insert(ObjectIdentifier(type)).inserted {
                result.append(type)
            }
        }
        return result
    }

    private func contextualOperation(
        _ expression: ExprSyntax,
        canProduce expectedType: Any.Type
    ) -> Bool {
        let expectedTypeName = sourceTypeName(String(reflecting: expectedType))
        if let call = expression.as(FunctionCallExprSyntax.self),
           call.trailingClosure == nil,
           call.additionalTrailingClosures.isEmpty,
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base == nil
        {
            let name = member.declName.baseName.text
            let labels = call.arguments.map { argument -> String? in
                guard let label = argument.label?.text, label != "_" else {
                    return nil
                }
                return label
            }
            return contextualRegistrations(
                named: name,
                kinds: name == "init" ? [.initializer] : [.staticMethod],
                expectedTypeName: expectedTypeName
            ).contains {
                argumentMapping(for: $0, labels: labels) != nil
            }
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
           member.base == nil
        {
            return !contextualRegistrations(
                named: member.declName.baseName.text,
                kinds: [.staticProperty],
                expectedTypeName: expectedTypeName
            ).isEmpty
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self),
           let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
           !scopes.isShadowed(binary.operator.text)
        {
            // Operator registrations are metadata-only here. Their callbacks
            // remain untouched until ordinary argument evaluation has selected
            // one unique overload.
            return !registeredOperatorCandidates(
                named: binary.operator.text,
                kind: .infixOperator,
                expectedTypeName: expectedTypeName
            ).isEmpty
        }
        return false
    }
}
