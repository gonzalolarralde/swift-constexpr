import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

/// Materializes the remaining straight-line computation after partial rewriting.
/// This is not a general dead-code eliminator: only our generated, initially
/// live builder intermediates can be removed. A user initializer must still run
/// even if constant propagation has made its binding unused.
enum ConstExprBuilderResidual {
    static func expression(
        source: String,
        result: String,
        generatedBindings: Set<String>,
        builderType: String,
        runtimeBuilderType: String,
        builderAlias: String
    ) -> ExprSyntax? {
        let tree = Parser.parse(source: source)
        var live: Set<String> = [result]
        var retained: [CodeBlockItemSyntax] = []
        for item in tree.statements.reversed() {
            guard var variable = item.item.as(VariableDeclSyntax.self) else {
                live.formUnion(references(in: item))
                retained.append(item)
                continue
            }
            if variable.bindings.count == 1,
               let binding = variable.bindings.first,
               let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
               generatedBindings.contains(name), !live.contains(name) {
                // Every generated component was consumed by an eager builder
                // call before rewriting. It can become unused only when that
                // use was folded through the trusted, pure registry.
                continue
            }
            var bindings: [PatternBindingSyntax] = []
            for var binding in variable.bindings.reversed() {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                    let name = identifier.identifier.text
                    if generatedBindings.contains(name),
                       var initializer = binding.initializer,
                       var call = initializer.value.as(FunctionCallExprSyntax.self),
                       var member = call.calledExpression.as(MemberAccessExprSyntax.self),
                       member.base?.trimmedDescription == builderType {
                        // Qualify only injected calls, never a user's expression.
                        // A type alias also prevents an outer value with the
                        // builder's name from capturing these member accesses.
                        member.base = ExprSyntax(stringLiteral: builderAlias)
                        call.calledExpression = ExprSyntax(member)
                        initializer.value = ExprSyntax(call)
                        binding.initializer = initializer
                    }
                    if !live.contains(name) {
                        // Preserve type context, effects, and execution order;
                        // only discard the now-unused name, avoiding a new
                        // unused-binding warning in the expanded closure. For
                        // an unknown/reference type, losing the binding could
                        // change its lifetime, so retain the original builder.
                        guard canDiscardName(of: binding) else { return nil }
                        binding.pattern = PatternSyntax(WildcardPatternSyntax())
                            .with(\.leadingTrivia, binding.pattern.leadingTrivia)
                            .with(\.trailingTrivia, binding.pattern.trailingTrivia)
                    }
                    live.remove(name)
                }
                live.formUnion(references(in: binding))
                bindings.append(binding)
            }
            variable.bindings = PatternBindingListSyntax(bindings.reversed())
            var updated = item
            updated.item = .decl(DeclSyntax(variable))
            retained.append(updated)
        }
        let statements = CodeBlockItemListSyntax(retained.reversed())
        return ExprSyntax(stringLiteral: """
        ({
        typealias \(builderAlias) = \(runtimeBuilderType)
        \(statements.description)
        return \(result)
        })()
        """)
    }

    private static func references(in node: some SyntaxProtocol) -> Set<String> {
        let visitor = ReferenceVisitor(viewMode: .sourceAccurate)
        visitor.walk(node)
        return visitor.names
    }

    private static func canDiscardName(of binding: PatternBindingSyntax) -> Bool {
        if let type = binding.typeAnnotation?.type { return isBuiltinValueType(type) }
        guard let value = binding.initializer?.value else { return false }
        return hasBuiltinValueType(value)
    }

    private static func hasBuiltinValueType(_ expression: ExprSyntax) -> Bool {
        if expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self) || expression.is(StringLiteralExprSyntax.self) {
            return true
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.label == nil {
            return hasBuiltinValueType(element.expression)
        }
        // SwiftParser leaves `as` unfolded in a sequence. Rendered values carry
        // explicit static types; only discard ones without user-defined lifetime
        // behavior. Do not guess an unknown call's return type.
        if let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 3,
           sequence.elements.dropFirst().first?.is(UnresolvedAsExprSyntax.self) == true,
           let type = sequence.elements.last?.as(TypeExprSyntax.self)?.type {
            return isBuiltinValueType(type)
        }
        return false
    }

    private static func isBuiltinValueType(_ type: TypeSyntax) -> Bool {
        if let array = type.as(ArrayTypeSyntax.self) { return isBuiltinValueType(array.element) }
        if let optional = type.as(OptionalTypeSyntax.self) { return isBuiltinValueType(optional.wrappedType) }
        let builtins: Set<String> = [
            "Bool", "String", "Int", "Int8", "Int16", "Int32", "Int64", "Int128",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Float", "Double",
        ]
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return builtins.contains(identifier.name.text)
        }
        if let member = type.as(MemberTypeSyntax.self), member.baseType.trimmedDescription == "Swift",
           member.genericArgumentClause == nil {
            return builtins.contains(member.name.text)
        }
        return false
    }

    private final class ReferenceVisitor: SyntaxVisitor {
        var names: Set<String> = []

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            names.insert(node.baseName.text)
            return .visitChildren
        }

        override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
            names.insert(node.name.text)
            return .visitChildren
        }
    }
}
