import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceRewriterBase {
    func rewriteClosure(_ node: ClosureExprSyntax) -> ExprSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let explicitlyThrows = permitsPropagatingThrows(
            node.signature?.effectSpecifiers?.throwsClause
        )
        if !explicitlyThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !explicitlyThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        let returnType = node.signature?.returnClause?.type.trimmedDescription
        if returnType == nil { requireExplicitLiteralContext += 1 }
        defer {
            if returnType == nil { requireExplicitLiteralContext -= 1 }
        }
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = registerImplicitReturn(in: node.statements, as: returnType)
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        predeclare(in: node.statements)
        if let signature = node.signature,
            let parameterClause = signature.parameterClause
        {
            for parameter in parameterClause.parametersForConstExpr {
                evaluator.scopes.declare(parameter)
            }
        }
        if let captures = node.signature?.capture?.items {
            for capture in captures where capture.name.text != "_" {
                evaluator.scopes.declare(capture.name.text)
            }
        }
        return super.visit(node)
    }
    func permitsPropagatingThrows(_ clause: ThrowsClauseSyntax?) -> Bool {
        guard let clause else { return false }
        return clause.throwsSpecifier.tokenKind == .keyword(.throws)
            && clause.type == nil
    }

    func declare(parameters: FunctionParameterListSyntax) {
        for parameter in parameters {
            let token = parameter.secondName ?? parameter.firstName
            if token.text != "_" {
                evaluator.scopes.declare(token.text)
            }
        }
    }

    func registerImplicitReturn(
        in statements: CodeBlockItemListSyntax,
        as sourceType: String?
    ) -> SyntaxIdentifier? {
        guard let sourceType,
            statements.count == 1,
            let statement = statements.first,
            case .expr(let expression) = statement.item
        else { return nil }
        implicitReturnTypes[expression.id] = sourceType
        return expression.id
    }

    func predeclare(in statements: CodeBlockItemListSyntax) {
        for statement in statements {
            guard case .decl(let declaration) = statement.item else { continue }
            if let variable = declaration.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    for name in boundNames(in: binding.pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            } else if let function = declaration.as(FunctionDeclSyntax.self) {
                evaluator.scopes.declare(function.name.text)
            } else if let nominal = declaredTypeName(declaration) {
                evaluator.scopes.declare(nominal)
            }
        }
    }

    func predeclare(in members: MemberBlockItemListSyntax) {
        for member in members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    for name in boundNames(in: binding.pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self) {
                evaluator.scopes.declare(function.name.text)
            } else if let nominal = declaredTypeName(member.decl) {
                evaluator.scopes.declare(nominal)
            }
        }
    }

    func boundNames(in pattern: PatternSyntax) -> [String] {
        final class Collector: SyntaxVisitor {
            var names: [String] = []

            init() {
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                if node.identifier.text != "_" {
                    names.append(node.identifier.text)
                }
                return .skipChildren
            }
        }

        let collector = Collector()
        collector.walk(pattern)
        return collector.names
    }

    func declareBindings(in conditions: ConditionElementListSyntax) {
        for element in conditions {
            let pattern: PatternSyntax?
            switch element.condition {
            case .optionalBinding(let binding): pattern = binding.pattern
            case .matchingPattern(let matching): pattern = matching.pattern
            default: pattern = nil
            }
            if let pattern {
                for name in boundNames(in: pattern) {
                    evaluator.scopes.declare(name)
                }
            }
        }
    }

    func containsDeferredSemantics(_ expression: ExprSyntax) -> Bool {
        final class Finder: SyntaxVisitor {
            var found = false

            init() {
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }
        }

        let finder = Finder()
        finder.walk(expression)
        return finder.found
    }

    func declaredTypeName(_ declaration: DeclSyntax) -> String? {
        if let declaration = declaration.as(StructDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ClassDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(EnumDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ActorDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ProtocolDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(TypeAliasDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(AssociatedTypeDeclSyntax.self) { return declaration.name.text }
        return nil
    }

    func declare(genericParameters clause: GenericParameterClauseSyntax?) {
        guard let clause else { return }
        for parameter in clause.parameters where parameter.name.text != "_" {
            evaluator.scopes.declare(parameter.name.text)
        }
    }

    func declare(genericParameters clause: PrimaryAssociatedTypeClauseSyntax?) {
        guard let clause else { return }
        for parameter in clause.primaryAssociatedTypes where parameter.name.text != "_" {
            evaluator.scopes.declare(parameter.name.text)
        }
    }

    func withGenericParameterScope(
        _ clause: GenericParameterClauseSyntax?,
        _ body: () -> DeclSyntax
    ) -> DeclSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: clause)
        return body()
    }

    func withGenericParameterScope(
        _ clause: PrimaryAssociatedTypeClauseSyntax?,
        _ body: () -> DeclSyntax
    ) -> DeclSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: clause)
        return body()
    }
}

private extension ClosureSignatureSyntax.ParameterClause {
    var parametersForConstExpr: [String] {
        switch self {
        case .simpleInput(let parameters):
            return parameters.map(\.name.text).filter { $0 != "_" }
        case .parameterClause(let clause):
            return clause.parameters.compactMap { parameter in
                let token = parameter.secondName ?? parameter.firstName
                return token.text == "_" ? nil : token.text
            }
        }
    }
}
