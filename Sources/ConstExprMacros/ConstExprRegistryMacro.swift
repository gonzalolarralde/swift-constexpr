import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ConstExprRegistryMacro: ExpressionMacro {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        if macro.arguments.first?.label?.constExprIdentifier == "for" {
            return typedRegistryExpansion(of: macro, in: context)
        }
        var pieces: [String] = []
        for argument in macro.arguments {
            guard let piece = registrationExpression(for: argument.expression) else {
                ConstExprMacroDiagnostic.error(
                    "registry entries must name an @ConstExpr function, global let, or nominal type",
                    id: "invalid-registry-entry",
                    at: argument.expression,
                    in: context
                )
                continue
            }
            pieces.append(
                "_ConstExprRuntime.registrations(fromGeneratedPeer: \(piece))"
            )
        }

        let registrations: String
        if pieces.count > ConstExprRegistrationChunkSyntax.limit {
            registrations = ConstExprRegistrationChunkSyntax
                .boundedConcatenation(pieces)
        } else {
            registrations = pieces.isEmpty ? "[]" : pieces.joined(separator: " + ")
        }
        return ExprSyntax(
            stringLiteral: "_ConstExprRuntime.Registry(registrations: \(registrations))"
        )
    }

    private static func typedRegistryExpansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) -> ExprSyntax {
        guard let rootArgument = macro.arguments.first,
              let root = metatypeBase(rootArgument.expression),
              let rootProvider = providerReference(for: rootArgument.expression)
        else {
            ConstExprMacroDiagnostic.error(
                "for: must name an @ConstExpr nominal type",
                id: "invalid-registry-root",
                at: macro,
                in: context
            )
            return ExprSyntax(
                stringLiteral: "_ConstExprRuntime.Registry(registrations: [])"
            )
        }

        var pieces = [
            "_ConstExprRuntime.registrations(for: \(root).self, from: \(rootProvider).self)"
        ]
        if let extensionsArgument = macro.arguments.first(where: {
            $0.label?.constExprIdentifier == "extensions"
        }) {
            guard let array = extensionsArgument.expression.as(ArrayExprSyntax.self) else {
                ConstExprMacroDiagnostic.error(
                    "extensions: must be an array of named extension provider types",
                    id: "invalid-registry-extensions",
                    at: extensionsArgument.expression,
                    in: context
                )
                return ExprSyntax(
                    stringLiteral: "_ConstExprRuntime.Registry(registrations: [])"
                )
            }
            for element in array.elements {
                guard let name = extensionProviderName(element.expression) else {
                    ConstExprMacroDiagnostic.error(
                        "extension entries must be non-interpolated identifier strings such as \"Networking\"",
                        id: "invalid-registry-extension",
                        at: element.expression,
                        in: context
                    )
                    continue
                }
                pieces.append(
                    "_ConstExprRuntime.registrations(fromGeneratedPeer: \(root).__constExprRegistration_\(name)(\(rootProvider).self))"
                )
            }
        }

        let registrations = pieces.count > ConstExprRegistrationChunkSyntax.limit
            ? ConstExprRegistrationChunkSyntax.boundedConcatenation(pieces)
            : pieces.joined(separator: " + ")
        return ExprSyntax(
            stringLiteral: "_ConstExprRuntime.Registry(registrations: \(registrations))"
        )
    }

    private static func metatypeBase(_ expression: ExprSyntax) -> String? {
        let expression = unwrapParentheses(expression)
        guard let metatype = expression.as(MemberAccessExprSyntax.self),
              metatype.declName.baseName.tokenKind == .keyword(.`self`),
              let base = metatype.base
        else { return nil }
        return base.constExprSource
    }

    private static func extensionProviderName(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else { return nil }
        let name = segment.content.text
        return ConstExprMacro.isSimpleIdentifier(name) ? name : nil
    }

    private static func registrationExpression(for expression: ExprSyntax) -> String? {
        let expression = unwrapParentheses(expression)

        // Directly attached member peers for declarations that do not have a
        // source-level function reference (notably subscripts) can be selected
        // by calling their generated helper explicitly. The call is consumed
        // by this macro and becomes the registration-array expression.
        if let call = expression.as(FunctionCallExprSyntax.self),
           isGeneratedProviderCall(call.calledExpression)
        {
            return call.constExprSource
        }

        if let property = directPropertyRegistrationExpression(for: expression) {
            return property
        }

        if let provider = providerReference(for: expression) {
            return "\(provider).registrations"
        }

        if let cast = expression.as(AsExprSyntax.self) {
            guard cast.questionOrExclamationMark == nil else { return nil }
            if let provider = providerReference(for: unwrapParentheses(cast.expression)) {
                return "\(provider).registrations"
            }
            guard let helper = helperReference(for: unwrapParentheses(cast.expression)) else {
                return nil
            }
            return "\(helper.path)(\(helper.selector): (\(cast.constExprSource)))"
        }

        guard let helper = helperReference(for: expression) else {
            return nil
        }
        return "\(helper.path)(\(helper.selector): \(expression.constExprSource))"
    }

    private static func directPropertyRegistrationExpression(
        for expression: ExprSyntax
    ) -> String? {
        let source = expression.constExprSource
        guard source.first == "\\",
              let separator = source.lastIndex(of: ".")
        else {
            return nil
        }
        let ownerStart = source.index(after: source.startIndex)
        let owner = source[ownerStart..<separator]
        let memberStart = source.index(after: separator)
        let member = source[memberStart...]
        guard !owner.isEmpty, !member.isEmpty else { return nil }
        let selector = ConstExprSyntaxSupport.selectorLabel(for: [String]())
        return "\(owner).\(member)__constExpr(\(selector): \(source))"
    }

    private static func isGeneratedProviderCall(_ expression: ExprSyntax) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.constExprIdentifier.hasSuffix("__constExpr")
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.constExprIdentifier.hasSuffix("__constExpr")
        }
        return false
    }

    private struct HelperReference {
        let path: String
        let selector: String
    }

    private static func helperReference(for expression: ExprSyntax) -> HelperReference? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return HelperReference(
                path: ConstExprSyntaxSupport.synthesizedName(
                    for: reference.baseName,
                    suffix: "__constExpr"
                ),
                selector: selector(for: reference)
            )
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
           let base = member.base
        {
            return HelperReference(
                path: "\(base.constExprSource).\(ConstExprSyntaxSupport.synthesizedName(for: member.declName.baseName, suffix: "__constExpr"))",
                selector: selector(for: member.declName)
            )
        }
        return nil
    }

    private static func selector(for reference: DeclReferenceExprSyntax) -> String {
        let labels = reference.argumentNames?.arguments.map { $0.name.constExprIdentifier } ?? []
        return ConstExprSyntaxSupport.selectorLabel(for: labels)
    }

    private static func providerReference(for expression: ExprSyntax) -> String? {
        let expression = unwrapParentheses(expression)
        guard let metatype = expression.as(MemberAccessExprSyntax.self),
              metatype.declName.baseName.tokenKind == .keyword(.`self`),
              let base = metatype.base
        else {
            return nil
        }
        return suffixedReference(for: unwrapParentheses(base))
    }

    private static func suffixedReference(for expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return ConstExprSyntaxSupport.synthesizedName(
                for: reference.baseName,
                suffix: "__constExpr"
            )
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
           let base = member.base
        {
            return "\(base.constExprSource).\(ConstExprSyntaxSupport.synthesizedName(for: member.declName.baseName, suffix: "__constExpr"))"
        }
        return nil
    }

    private static func unwrapParentheses(_ expression: ExprSyntax) -> ExprSyntax {
        guard let tuple = expression.as(TupleExprSyntax.self),
              tuple.elements.count == 1,
              let first = tuple.elements.first,
              first.label == nil
        else {
            return expression
        }
        return unwrapParentheses(first.expression)
    }
}
