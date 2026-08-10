import SwiftSyntax

extension ConstExprSourceEvaluator {
    /// Resolves `T.self` only from an exact, unique registry-backed parameter
    /// context. SwiftSyntax does not provide consumer-module semantic lookup,
    /// so an absent, shadowed, or ambiguous type remains compiler work.
    func evaluateContextualMetatypeLiteral(
        _ member: MemberAccessExprSyntax,
        expectedTypeName: String?
    ) -> ConstExprEvaluation? {
        guard member.declName.baseName.text == "self",
              let base = member.base,
              let sourceBaseName = qualifiedName(of: base),
              !usesShadowedTypeName(sourceBaseName),
              var expectedSourceName = expectedTypeName,
              var parameterType = typeResolver.resolve(
                  sourceName: expectedSourceName
              )?.type
        else { return nil }

        while let wrapped = ConstExprValue.wrappedType(
            ofOptionalType: parameterType
        ) {
            guard let wrappedSourceName = optionalWrappedSourceType(
                expectedSourceName
            ) else { return nil }
            parameterType = wrapped
            expectedSourceName = wrappedSourceName
        }

        guard expectedSourceName.hasSuffix(".Type"),
              let sourceType = typeResolver.resolve(
                  sourceName: sourceBaseName + ".Type"
              )?.type,
              sameType(sourceType, parameterType)
        else { return nil }

        let reflectedMetatype = String(reflecting: parameterType)
        guard reflectedMetatype.hasSuffix(".Type") else { return nil }
        let reflectedBase = String(reflectedMetatype.dropLast(".Type".count))
        guard sourceName(sourceBaseName, matches: reflectedBase),
              let literal = _typeByName(reflectedBase),
              sameType(Swift.type(of: literal), parameterType)
        else { return nil }

        let value = ConstExprValue(
            literal as Any,
            preservingStaticType: parameterType,
            sourceTypeName: expectedSourceName
        )
        return replacement(
            for: value,
            original: ExprSyntax(member),
            fallback: ExprSyntax(member)
        )
    }

    private func sourceName(_ source: String, matches reflected: String) -> Bool {
        if source.contains(".") {
            return reflected == source || reflected.hasSuffix("." + source)
        }
        return reflected.split(separator: ".").last.map(String.init) == source
    }
}
