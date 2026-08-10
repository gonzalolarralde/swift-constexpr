import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateRegisteredOperator(
        named name: String,
        kind: ConstExprRegistrationKind,
        values: [ConstExprValue],
        original: ExprSyntax,
        fallback: ExprSyntax,
        allowRegisteredCalls: Bool,
        candidates suppliedCandidates: [ConstExprRegistration]? = nil,
        expectedTypeName: String? = nil
    ) -> ConstExprEvaluation {
        guard allowRegisteredCalls else { return ConstExprEvaluation(syntax: fallback, value: nil) }
        let candidates = suppliedCandidates ?? registeredOperatorCandidates(
            named: name,
            kind: kind,
            expectedTypeName: expectedTypeName
        )
        let labels = Array<String?>(repeating: nil, count: values.count)
        let viable = candidates.compactMap { registration -> ViableCall? in
            guard let match = match(registration, labels: labels, values: values) else { return nil }
            return ViableCall(
                registration: registration,
                arguments: match.arguments,
                conversionRanks: match.conversionRanks,
                argumentTypes: match.argumentTypes,
                argumentDescriptors: match.argumentDescriptors,
                sourceTypes: match.sourceTypes,
                sourceDescriptors: match.sourceDescriptors,
                omittedDefaults: match.omittedDefaults
            )
        }
        let best = nonDominated(viable)
        guard best.count == 1 else {
            if best.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple custom operator overloads",
                    at: original
                )
            }
            return ConstExprEvaluation(syntax: fallback, value: nil)
        }
        do {
            noteThrowingInvocation(best[0].registration)
            let value = try best[0].registration.invoke(arguments: best[0].arguments)
            return replacement(for: value, original: original, fallback: fallback)
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant operator threw: \(error)",
                at: original
            )
            return ConstExprEvaluation(syntax: fallback, value: nil)
        }
    }

    // MARK: Partial rewriting and materialization

    func rewriteUnknownChildren(
        _ expression: ExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        final class ChildRewriter: SyntaxRewriter {
            let evaluator: ConstExprSourceEvaluator
            let depth: Int
            let allowRegisteredCalls: Bool
            var isRoot = true

            init(evaluator: ConstExprSourceEvaluator, depth: Int, allowRegisteredCalls: Bool) {
                self.evaluator = evaluator
                self.depth = depth
                self.allowRegisteredCalls = allowRegisteredCalls
                super.init(viewMode: .sourceAccurate)
            }

            override func visitAny(_ node: Syntax) -> Syntax? {
                if isRoot {
                    isRoot = false
                    return nil
                }
                guard let expression = node.as(ExprSyntax.self) else { return nil }
                return Syntax(
                    evaluator.evaluateWithUnknownLiteralContext(
                        expression,
                        depth: depth + 1,
                        allowRegisteredCalls: allowRegisteredCalls
                    ).syntax
                )
            }
        }

        let rewritten = ChildRewriter(
            evaluator: self,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls
        ).rewrite(expression, detach: true).cast(ExprSyntax.self)
        return ConstExprEvaluation(syntax: rewritten, value: nil)
    }

    func replacement(
        for value: ConstExprValue,
        original: ExprSyntax,
        fallback: ExprSyntax
    ) -> ConstExprEvaluation {
        guard materializesSource else {
            return ConstExprEvaluation(syntax: fallback, value: value)
        }
        guard !containsInternalComment(original) else {
            return ConstExprEvaluation(syntax: fallback, value: value)
        }
        guard var expression = render(value) else {
            // Opaque values intentionally flow through registered member chains
            // even though they cannot be emitted as source at this point.
            return ConstExprEvaluation(syntax: fallback, value: value)
        }
        if needsOperatorEmbeddingParentheses(expression, original: original),
            let parenthesized = parenthesizingCompoundExpression(expression)
        {
            expression = parenthesized
        }
        expression.leadingTrivia = original.leadingTrivia
        expression.trailingTrivia = original.trailingTrivia
        renderedReplacementCount += 1
        return ConstExprEvaluation(syntax: expression, value: value)
    }

    func containsInternalComment(_ expression: ExprSyntax) -> Bool {
        let tokens = Array(expression.tokens(viewMode: .sourceAccurate))
        guard !tokens.isEmpty else { return false }
        for (index, token) in tokens.enumerated() {
            if index > 0, triviaContainsComment(token.leadingTrivia) { return true }
            if index < tokens.count - 1, triviaContainsComment(token.trailingTrivia) { return true }
        }
        return false
    }

    func triviaContainsComment(_ trivia: Trivia) -> Bool {
        trivia.pieces.contains { piece in
            switch piece {
            case .blockComment, .docBlockComment, .docLineComment, .lineComment:
                return true
            default:
                return false
            }
        }
    }

    func render(_ value: ConstExprValue) -> ExprSyntax? {
        if value.isOptional {
            let typeName = sourceTypeName(
                value.explicitTypeName ?? String(reflecting: value.staticType)
            )
            if value.isNil {
                return parseExpression("nil as \(typeName)")
            }
            guard let wrapped = value.wrappedValue,
                let expression = try? wrapped.constExprExpression(
                    contextualizedByOuterType: value.explicitTypeName != nil
                )
            else { return nil }
            return parseExpression("(\(expression.description)) as \(typeName)")
        }
        guard let expression = try? value.constExprExpression(),
            let validated = parseExpression(expression.description)
        else { return nil }
        if isCustomOpaqueValue(value), isCompoundExpression(validated) {
            return parenthesizingCompoundExpression(validated)
        }
        return validated
    }

    func parenthesizingCompoundExpression(_ expression: ExprSyntax) -> ExprSyntax? {
        guard isCompoundExpression(expression) else { return expression }
        guard var parenthesized = parseExpression("(\(expression.trimmedDescription))") else {
            return nil
        }
        parenthesized.leadingTrivia = expression.leadingTrivia
        parenthesized.trailingTrivia = expression.trailingTrivia
        return parenthesized
    }

    func isCompoundExpression(_ expression: ExprSyntax) -> Bool {
        expression.is(InfixOperatorExprSyntax.self)
            || expression.is(SequenceExprSyntax.self)
            || expression.is(TernaryExprSyntax.self)
            || expression.is(AssignmentExprSyntax.self)
            || expression.is(AsExprSyntax.self)
    }

    func needsOperatorEmbeddingParentheses(
        _ rendered: ExprSyntax,
        original: ExprSyntax
    ) -> Bool {
        guard isCompoundExpression(rendered), let parent = original.parent else { return false }
        return parent.is(InfixOperatorExprSyntax.self)
            || parent.is(PrefixOperatorExprSyntax.self)
            || parent.is(PostfixOperatorExprSyntax.self)
    }

    func isCustomOpaqueValue(_ value: ConstExprValue) -> Bool {
        guard case .opaque = value.payload else { return false }
        let type = value.staticType
        return type != Int.self
            && type != Int8.self
            && type != Int16.self
            && type != Int32.self
            && type != Int64.self
            && type != UInt.self
            && type != UInt8.self
            && type != UInt16.self
            && type != UInt32.self
            && type != UInt64.self
            && type != Float.self
            && type != Double.self
            && type != Bool.self
            && type != String.self
            && type != Character.self
    }

    func parseExpression(_ source: String) -> ExprSyntax? {
        let file = Parser.parse(source: "let __constant = \(source)")
        guard !ParseDiagnosticsGenerator.diagnostics(for: file).contains(where: {
            $0.diagMessage.severity == .error
        }),
            file.statements.count == 1,
            let declaration = file.statements.first?.item.as(VariableDeclSyntax.self),
            declaration.bindings.count == 1,
            let expression = declaration.bindings.first?.initializer?.value
        else { return nil }
        return expression.detached
    }

    func safeEmbeddedBase(_ rewritten: ExprSyntax, original: ExprSyntax) -> ExprSyntax {
        guard rewritten.description != original.description,
            !rewritten.is(TupleExprSyntax.self),
            var parenthesized = parseExpression("(\(rewritten.trimmedDescription))")
        else { return rewritten }
        parenthesized.leadingTrivia = rewritten.leadingTrivia
        parenthesized.trailingTrivia = rewritten.trailingTrivia
        return parenthesized
    }

    func sourceTypeName(_ reflectedName: String) -> String {
        let name = reflectedName.hasPrefix("Swift.")
            ? String(reflectedName.dropFirst("Swift.".count))
            : reflectedName
        if let wrapped = genericArguments(in: name, constructor: "Optional"), wrapped.count == 1 {
            return sourceTypeName(wrapped[0]) + "?"
        }
        if let element = genericArguments(in: name, constructor: "Array"), element.count == 1 {
            return "[\(sourceTypeName(element[0]))]"
        }
        if let arguments = genericArguments(in: name, constructor: "Dictionary"), arguments.count == 2 {
            return "[\(sourceTypeName(arguments[0])): \(sourceTypeName(arguments[1]))]"
        }
        return name
    }

    func genericArguments(in name: String, constructor: String) -> [String]? {
        let prefix = constructor + "<"
        guard name.hasPrefix(prefix), name.hasSuffix(">") else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(before: name.endIndex)
        let body = name[start..<end]
        var depth = 0
        var pieceStart = body.startIndex
        var result: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            switch body[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case "," where depth == 0:
                result.append(String(body[pieceStart..<index]))
                pieceStart = body.index(after: index)
            default: break
            }
            index = body.index(after: index)
        }
        result.append(String(body[pieceStart..<body.endIndex]))
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func arrayElementSourceType(_ sourceName: String) -> String? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        guard topLevelColon(in: body) == nil else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setElementSourceType(_ sourceName: String) -> String? {
        let normalized = sourceTypeName(sourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let arguments = genericArguments(in: normalized, constructor: "Set"),
            arguments.count == 1
        else { return nil }
        return arguments[0]
    }

    func dictionarySourceTypes(_ sourceName: String) -> (key: String, value: String)? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        guard let colon = topLevelColon(in: body) else { return nil }
        return (
            String(body[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func tupleSourceTypes(_ sourceName: String) -> [String]? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("("), normalized.hasSuffix(")") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        let components = topLevelComponents(in: body)
        guard components.count >= 2 else { return nil }
        return components.map { component in
            guard let colon = topLevelColon(in: component) else {
                return component.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(component[component.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func topLevelComponents(in source: String) -> [String] {
        var depth = 0
        var start = source.startIndex
        var components: [String] = []
        for index in source.indices {
            switch source[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case "," where depth == 0:
                components.append(String(source[start..<index]))
                start = source.index(after: index)
            default: break
            }
        }
        components.append(String(source[start...]))
        return components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func topLevelColon(in source: String) -> String.Index? {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case ":" where depth == 0: return index
            default: break
            }
        }
        return nil
    }

}
