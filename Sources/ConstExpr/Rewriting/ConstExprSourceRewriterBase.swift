import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

class ConstExprSourceRewriterBase: SyntaxRewriter {
    let evaluator: ConstExprSourceEvaluator
    var suppressBindingPropagation = 0
    var suppressRegisteredCalls = 0
    var expectedReturnTypes: [String?] = []
    var implicitReturnTypes: [SyntaxIdentifier: String] = [:]
    var resultBuilderFunctionNames: Set<String> = []
    var requireExplicitLiteralContext = 0
    var memberVariableContext = 0

    init(evaluator: ConstExprSourceEvaluator) {
        self.evaluator = evaluator
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> Syntax? {
        // Macro arguments may be inspected more than once or encoded into the
        // expansion result; rewriting them without expanding the macro is not
        // semantics-preserving.
        if node.is(MacroExpansionExprSyntax.self) {
            return node
        }
        // Closure bodies need the declaration-aware traversal below.
        if node.is(ClosureExprSyntax.self)
            || node.is(IfExprSyntax.self)
            || node.is(SwitchExprSyntax.self)
        {
            return nil
        }
        guard let expression = node.as(ExprSyntax.self) else { return nil }
        if containsDeferredSemantics(expression) {
            return nil
        }
        let result: ConstExprEvaluation
        if requireExplicitLiteralContext > 0,
           implicitReturnTypes[expression.id] == nil
        {
            result = evaluator.evaluateWithUnknownLiteralContext(
                expression,
                depth: 0,
                allowRegisteredCalls: suppressRegisteredCalls == 0
            )
        } else {
            result = evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: implicitReturnTypes[expression.id]
            )
        }
        return Syntax(result.syntax)
    }

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        final class ResultBuilderCollector: SyntaxVisitor {
            var functionNames: Set<String> = []
            var associatedTypeNames: Set<String> = []
            var extensionMembers: Set<ConstExprSourceExtensionMember> = []

            init() { super.init(viewMode: .sourceAccurate) }

            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if node.signature.parameterClause.parameters.contains(where: {
                    !$0.attributes.isEmpty && $0.type.trimmedDescription.contains("->")
                }) {
                    functionNames.insert(node.name.text)
                }
                return .visitChildren
            }

            override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
                // Extensions of a protocol inherit its associated type names,
                // but SwiftSyntax does not resolve the extended nominal for
                // us. A file-wide conservative shadow prevents treating an
                // associated type named `Int`, for example, as Swift.Int.
                associatedTypeNames.insert(node.name.text)
                return .skipChildren
            }

            override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
                let ownerName = node.extendedType.trimmedDescription
                for item in node.memberBlock.members {
                    let declaration = item.decl
                    if let function = declaration.as(FunctionDeclSyntax.self) {
                        extensionMembers.insert(.init(
                            ownerName: ownerName,
                            memberName: function.name.text
                        ))
                    } else if declaration.is(InitializerDeclSyntax.self) {
                        extensionMembers.insert(.init(ownerName: ownerName, memberName: "init"))
                    } else if declaration.is(SubscriptDeclSyntax.self) {
                        extensionMembers.insert(.init(ownerName: ownerName, memberName: "subscript"))
                    } else if let variable = declaration.as(VariableDeclSyntax.self) {
                        for binding in variable.bindings {
                            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                                extensionMembers.insert(.init(
                                    ownerName: ownerName,
                                    memberName: identifier.identifier.text
                                ))
                            }
                        }
                    } else if let nested = Self.declaredTypeName(declaration) {
                        extensionMembers.insert(.init(
                            ownerName: ownerName,
                            memberName: nested
                        ))
                    }
                }
                return .visitChildren
            }

            private static func declaredTypeName(_ declaration: DeclSyntax) -> String? {
                if let declaration = declaration.as(StructDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ClassDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(EnumDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ActorDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ProtocolDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(TypeAliasDeclSyntax.self) { return declaration.name.text }
                return nil
            }
        }
        let collector = ResultBuilderCollector()
        collector.walk(node)
        resultBuilderFunctionNames = collector.functionNames
        evaluator.fileDeclaredTypeNames.formUnion(collector.associatedTypeNames)
        evaluator.sourceExtensionMembers.formUnion(collector.extensionMembers)
        predeclare(in: node.statements)
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        if node.trailingClosure != nil,
           let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
           resultBuilderFunctionNames.contains(reference.baseName.text)
        {
            // A result builder supplies hidden expression contexts and may
            // transform or evaluate each body expression more than once.
            return ExprSyntax(node)
        }
        return super.visit(node)
    }

    override func visit(_ node: AttributeSyntax) -> AttributeSyntax {
        // Attribute arguments are consumed by the compiler or a macro and may
        // be inspected as syntax rather than evaluated as ordinary Swift.
        node
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> DeclSyntax {
        // Raw-value expressions inherit the enum's raw type, and associated
        // value defaults inherit their parameter types. Until those contexts
        // are modeled explicitly, even rewriting a child literal operator can
        // change the program's static type.
        DeclSyntax(node)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> DeclSyntax {
        // Without evaluating the active compilation conditions, choosing one
        // branch would make binding propagation configuration-dependent.
        for clause in node.clauses {
            switch clause.elements {
            case .statements(let statements): predeclare(in: statements)
            case .decls(let members): predeclare(in: members)
            default: break
            }
        }
        return DeclSyntax(node)
    }

    override func visit(_ node: CodeBlockSyntax) -> CodeBlockSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.statements)
        return super.visit(node)
    }

    override func visit(_ node: MemberBlockSyntax) -> MemberBlockSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.members)
        return super.visit(node)
    }

    override func visit(_ node: MemberBlockItemSyntax) -> MemberBlockItemSyntax {
        guard node.decl.is(VariableDeclSyntax.self) else { return super.visit(node) }
        suppressBindingPropagation += 1
        memberVariableContext += 1
        defer {
            memberVariableContext -= 1
            suppressBindingPropagation -= 1
        }
        return super.visit(node)
    }

    override func visit(_ node: ForStmtSyntax) -> StmtSyntax {
        // The sequence is contextually converted to the annotated/inferred
        // pattern element type. Keep the loop opaque until that conversion and
        // iteration semantics are modeled together.
        StmtSyntax(node)
    }

    override func visit(_ node: RepeatStmtSyntax) -> StmtSyntax {
        // Loop bodies are runtime control flow; executing linked callbacks
        // while merely rewriting their source would be observably incorrect.
        StmtSyntax(node)
    }

    override func visit(_ node: DoStmtSyntax) -> StmtSyntax {
        guard !node.catchClauses.isEmpty else { return super.visit(node) }
        // Replacing the final throwing operation beneath `try` can make this
        // catch unreachable and turn valid source into a compiler error under
        // `-warnings-as-errors`. Nonthrowing registrations remain eligible.
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: CatchClauseSyntax) -> CatchClauseSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        if node.catchItems.isEmpty {
            evaluator.scopes.declare("error")
        } else {
            for item in node.catchItems {
                if let pattern = item.pattern {
                    for name in boundNames(in: pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            }
        }
        return super.visit(node)
    }

    override func visit(_ node: IfExprSyntax) -> ExprSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        declareBindings(in: node.conditions)
        return super.visit(node)
    }

    override func visit(_ node: WhileStmtSyntax) -> StmtSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        declareBindings(in: node.conditions)
        return super.visit(node)
    }

    override func visit(_ node: GuardStmtSyntax) -> StmtSyntax {
        // Successful guard bindings are visible to all following statements in
        // the current lexical scope. Declaring before visiting the initializer
        // is deliberately conservative and prevents unsafe outer substitution.
        declareBindings(in: node.conditions)
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: SwitchExprSyntax) -> ExprSyntax {
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: SwitchCaseSyntax) -> SwitchCaseSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.statements)
        if case .case(let label) = node.label {
            for item in label.caseItems {
                for name in boundNames(in: item.pattern) {
                    evaluator.scopes.declare(name)
                }
            }
        }
        return super.visit(node)
    }

    override func visit(_ node: SwitchCaseItemSyntax) -> SwitchCaseItemSyntax {
        // Expression patterns inherit the switch subject's type. Keep the
        // entire item opaque until that subject-to-pattern context is modeled.
        node
    }

    override func visit(
        _ node: MatchingPatternConditionSyntax
    ) -> MatchingPatternConditionSyntax {
        // Both the pattern expression and initializer participate in one
        // contextual match. Partial substitution can change either side's
        // inferred type.
        node
    }

    override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
        rewriteClosure(node)
    }

}
