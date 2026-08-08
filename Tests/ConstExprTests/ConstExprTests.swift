import SwiftSyntax
import Testing
@testable import ConstExpr

enum ParseError: Error {
    case cantFindExpectedParameter
}

func foo(_ value: Int) -> Int {
    value + 1
}

struct Bar {
    private let value: Int
    
    init(_ value: Int) {
        self.value = value
    }
    
    func build() -> String {
        "Bar \(value)"
    }
}

extension Bar: ConstExprType {
    static let canonicalName = "Bar"
    static func findBuilder(for function: FunctionCallExprSyntax) -> ConstExprBuilder? {
        .init { _ in
            function
//            StringLiteralExprSyntax(
//                openingQuote: .stringQuoteToken(),
//                segments: [],
//                closingQuote: .stringQuoteToken()
//            )
        }
    }
    static func chainBuilder(instance: Bar, for function: FunctionCallExprSyntax) -> (ConstExprBuilder, String)? {
        (.init { _ in function }, "Bar")
    }
}

struct fooRepr: ConstExprType {
    static let canonicalName = "foo"
    static func findBuilder(for function: FunctionCallExprSyntax) -> ConstExprBuilder? {
        .init { arguments in
            guard
                let first = arguments.first,
                let integerLiteral = first.expression.as(IntegerLiteralExprSyntax.self),
                let integer = Int(integerLiteral.literal.text)
            else { throw ParseError.cantFindExpectedParameter }

            return IntegerLiteralExprSyntax(
                leadingTrivia: function.leadingTrivia,
                literal: .integerLiteral("\(foo(integer))"),
                trailingTrivia: function.trailingTrivia
            )
        }
    }
    static func chainBuilder(instance: Self, for function: FunctionCallExprSyntax) -> (ConstExprBuilder, String)? {
        nil
    }
}

@Test func basicExpectations() async throws {
    let source = """
        let result = Bar(foo(foo(5))).build()
        """
    let output = """
        let result = "Bar 7"
        """
    
    #expect(
        ConstExprRunner(registry: [Bar.self, fooRepr.self]).run(input: source) == output
    )
}
