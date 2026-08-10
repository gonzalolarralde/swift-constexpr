import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

final class ConstExprSourceRewriter: ConstExprSourceRewriterBase {
    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.signature.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        declare(genericParameters: node.genericParameterClause)
        let returnType = node.signature.returnClause?.type.trimmedDescription
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = node.body.flatMap {
            registerImplicitReturn(in: $0.statements, as: returnType)
        }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        declare(parameters: node.signature.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.signature.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        declare(genericParameters: node.genericParameterClause)
        expectedReturnTypes.append(nil)
        defer { expectedReturnTypes.removeLast() }
        declare(parameters: node.signature.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: node.genericParameterClause)
        let returnType = node.returnClause.type.trimmedDescription
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = node.accessorBlock?.accessors
            .as(CodeBlockItemListSyntax.self)
            .flatMap { registerImplicitReturn(in: $0, as: returnType) }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        declare(parameters: node.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ActorDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        // Protocol primary associated types use the generic-parameter-clause
        // syntax and shadow ordinary nominal names in member declarations.
        return withGenericParameterScope(node.primaryAssociatedTypeClause) { super.visit(node) }
    }

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return super.visit(node)
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: AccessorDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        if let name = node.parameters?.name.text, name != "_" {
            evaluator.scopes.declare(name)
        } else {
            switch node.accessorSpecifier.text {
            case "set", "willSet": evaluator.scopes.declare("newValue")
            case "didSet": evaluator.scopes.declare("oldValue")
            default: break
            }
        }
        let implicitID: SyntaxIdentifier?
        if node.accessorSpecifier.text == "get", let body = node.body {
            implicitID = registerImplicitReturn(
                in: body.statements,
                as: expectedReturnTypes.last.flatMap { $0 }
            )
        } else {
            implicitID = nil
        }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        return super.visit(node)
    }

    override func visit(_ node: ReturnStmtSyntax) -> StmtSyntax {
        guard let expression = node.expression else { return super.visit(node) }
        var rewritten = node
        if containsDeferredSemantics(expression) {
            rewritten.expression = rewrite(expression, detach: true).cast(ExprSyntax.self)
        } else if requireExplicitLiteralContext > 0,
                  expectedReturnTypes.last.flatMap({ $0 }) == nil
        {
            // An implicit closure result is contextually typed by its caller.
            // That context is unavailable for an unregistered outer call, so
            // an explicit `return` must be as conservative as a single-
            // expression closure body.
            rewritten.expression = evaluator.evaluateWithUnknownLiteralContext(
                expression,
                depth: 0,
                allowRegisteredCalls: suppressRegisteredCalls == 0
            ).syntax
        } else {
            rewritten.expression = evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: expectedReturnTypes.last.flatMap { $0 }
            ).syntax
        }
        return StmtSyntax(rewritten)
    }

    override func visit(_ node: YieldStmtSyntax) -> StmtSyntax {
        guard case .single(let expression) = node.yieldedExpressions else {
            return super.visit(node)
        }
        var rewritten = node
        rewritten.yieldedExpressions = .single(
            evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: expectedReturnTypes.last.flatMap { $0 }
            ).syntax
        )
        return StmtSyntax(rewritten)
    }

    override func visit(_ node: FunctionParameterSyntax) -> FunctionParameterSyntax {
        guard let defaultValue = node.defaultValue else { return node }
        // A default argument cannot propagate an error even when its enclosing
        // declaration is `throws`; only `try?` and `try!` handle one locally.
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        var rewritten = node
        var rewrittenDefault = defaultValue
        if containsDeferredSemantics(defaultValue.value) {
            rewrittenDefault.value = rewrite(
                defaultValue.value,
                detach: true
            ).cast(ExprSyntax.self)
        } else {
            rewrittenDefault.value = evaluator.evaluate(
                defaultValue.value,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: node.type.trimmedDescription
            ).syntax
        }
        rewritten.defaultValue = rewrittenDefault
        return rewritten
    }

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        var rewritten = node
        var bindings: [PatternBindingSyntax] = []
        let isImmutable = node.bindingSpecifier.tokenKind == .keyword(.let)

        for binding in node.bindings {
            var rewrittenBinding = binding
            var evaluatedValue: ConstExprValue?
            if let initializer = binding.initializer {
                let suppressPropagatingThrow = memberVariableContext > 0
                if suppressPropagatingThrow {
                    evaluator.suppressThrowingRegistrations += 1
                }
                var rewrittenInitializer = initializer
                let annotation = binding.typeAnnotation?.type.trimmedDescription
                let isImplicitClosureWithOuterContext = annotation != nil
                    && initializer.value.is(ClosureExprSyntax.self)
                let isContextualStringInterpolation = annotation.map {
                    let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name != "String" && name != "Swift.String"
                } == true && initializer.value.as(StringLiteralExprSyntax.self).map {
                    $0.segments.contains { segment in
                        if case .expressionSegment = segment { return true }
                        return false
                    }
                } == true
                if !node.attributes.isEmpty
                    || isImplicitClosureWithOuterContext
                    || isContextualStringInterpolation
                {
                    // Property wrappers, an outer closure type, and custom
                    // interpolation overloads all add compiler-provided
                    // contexts unavailable from the initializer syntax alone.
                    rewrittenInitializer = initializer
                } else if containsDeferredSemantics(initializer.value) {
                    rewrittenInitializer.value = rewrite(
                        initializer.value,
                        detach: true
                    ).cast(ExprSyntax.self)
                } else {
                    let result = evaluator.evaluate(
                        initializer.value,
                        allowRegisteredCalls: suppressRegisteredCalls == 0,
                        expectedTypeName: binding.typeAnnotation?.type.trimmedDescription
                    )
                    rewrittenInitializer.value = result.syntax
                    evaluatedValue = result.value
                }
                rewrittenBinding.initializer = rewrittenInitializer
                if suppressPropagatingThrow {
                    evaluator.suppressThrowingRegistrations -= 1
                }
            }
            let annotation = binding.typeAnnotation?.type.trimmedDescription
            if let annotation, let currentValue = evaluatedValue {
                evaluatedValue = evaluator.staticallyConverted(
                    currentValue,
                    toSourceType: annotation
                )
            }
            if let annotation, let accessorBlock = binding.accessorBlock {
                expectedReturnTypes.append(annotation)
                let implicitID: SyntaxIdentifier?
                let hasShorthandGetter: Bool
                if case .getter(let statements) = accessorBlock.accessors {
                    hasShorthandGetter = true
                    implicitID = registerImplicitReturn(in: statements, as: annotation)
                } else {
                    hasShorthandGetter = false
                    implicitID = nil
                }
                if hasShorthandGetter {
                    evaluator.suppressThrowingRegistrations += 1
                }
                rewrittenBinding.accessorBlock = rewrite(
                    accessorBlock,
                    detach: true
                ).cast(AccessorBlockSyntax.self)
                if hasShorthandGetter {
                    evaluator.suppressThrowingRegistrations -= 1
                }
                if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
                expectedReturnTypes.removeLast()
            }
            let annotationIsConfirmed = annotation == nil || evaluatedValue.map {
                evaluator.value($0, matchesSourceType: annotation!)
            } == true
            if annotation != nil, !annotationIsConfirmed {
                // Rewriting even a child can select the wrong default literal
                // type under an alias or other unresolved source type.
                rewrittenBinding.initializer = binding.initializer
                evaluatedValue = nil
            }

            let names = boundNames(in: binding.pattern)
            if names.count == 1,
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            {
                if let annotation {
                    evaluator.scopes.setSourceType(annotation, for: identifier)
                }
                if suppressBindingPropagation == 0,
                    isImmutable,
                    annotationIsConfirmed,
                    let evaluatedValue
                {
                    evaluator.scopes.assignConstant(
                        evaluator.erasingLiteralProvenance(evaluatedValue),
                        to: identifier
                    )
                } else {
                    evaluator.scopes.declare(identifier)
                }
            } else {
                for name in names {
                    evaluator.scopes.declare(name)
                }
            }
            bindings.append(rewrittenBinding)
        }
        rewritten.bindings = PatternBindingListSyntax(bindings)
        return DeclSyntax(rewritten)
    }
}
