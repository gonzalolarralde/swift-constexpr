import SwiftSyntax
import SwiftParser

struct ConstExprBuilder {
    let builder: (LabeledExprListSyntax) throws -> any ExprSyntaxProtocol
    
    init(_ builder: @escaping (LabeledExprListSyntax) throws -> some ExprSyntaxProtocol) {
        self.builder = builder
    }
    
    func run(with arguments: LabeledExprListSyntax) throws -> ExprSyntax {
        return try .init(self.builder(arguments))
    }
}

protocol ConstExprType {
    static var canonicalName: String { get }
    static func findBuilder(for function: FunctionCallExprSyntax) -> ConstExprBuilder?
    static func chainBuilder(instance: Self, for function: FunctionCallExprSyntax) -> (ConstExprBuilder, String)?
}

struct ConstExprRunner {
    let registry: [any ConstExprType.Type]
    
    init(registry: [any ConstExprType.Type]) {
        self.registry = registry
    }
    
    func run(input: String) -> String {
        class Rewriter: SyntaxRewriter {
            let registry: [any ConstExprType.Type]

            func processFunc(_ node: FunctionCallExprSyntax) -> ConstExprBuilder {
                print("visit \(node)")
                let processed = super.visit(node)
                print("processed \(processed)")

                if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
                    if let base = memberAccess.base?.as(FunctionCallExprSyntax.self) {
                        let base = processFunc(base)
                        
                        return ConstExprBuilder { a in
                            try base.run(with: a)
                        }
                        
                    } else {
                        return ConstExprBuilder { _ in super.visit(node) }
                    }
                } else if let declBaseName = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName,
                   let matchedType = self.registry.first(where: { $0.canonicalName == declBaseName.text })
                {
                    guard
                        let rewrittenFunction = processed.as(FunctionCallExprSyntax.self),
                        let builder = matchedType.findBuilder(for: rewrittenFunction)
                    else { return ConstExprBuilder { _ in processed } }
                    
                    return builder
                } else {
                    return ConstExprBuilder { _ in processed }
                }
            }
            
            override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
                // let result = try? builder.run(with: rewrittenFunction.arguments)
                do {
                    return try processFunc(node).run(with: node.arguments)
                } catch {
                    return super.visit(node)
                }
            }
            
            init(registry: [any ConstExprType.Type]) {
                self.registry = registry
            }
        }
        
        let source = Parser.parse(source: input)
        return Rewriter(registry: registry).rewrite(source).description
    }
}
