import Foundation

public extension ConstExprRegistration {
    /// Creates an explicitly trusted, unbounded-by-default adapter for array
    /// literal syntax. The generic constraints prove that `Element` is the
    /// result type's real standard-library `ArrayLiteralElement` associated
    /// type. The builder receives already decoded elements in source order.
    static func arrayLiteral<Result, Element>(
        moduleName: String? = nil,
        result: Result.Type = Result.self,
        element: Element.Type = Element.self,
        elementTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        resultTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        maximumElementCount: Int? = nil,
        declarationID: String? = nil,
        build: @escaping @Sendable ([Element]) throws -> Result
    ) -> Self
    where Result: ExpressibleByArrayLiteral & SendableMetatype,
          Element: SendableMetatype,
          Result.ArrayLiteralElement == Element {
        Self(
            moduleName: moduleName,
            name: "arrayLiteral",
            kind: .arrayLiteral,
            ownerType: Result.self,
            parameterLabels: [],
            parameterTypes: [],
            parameterTypeDescriptors: [],
            defaultedParameters: [],
            resultType: Result.self,
            resultTypeDescriptor: resultTypeDescriptor,
            arrayLiteralElementType: Element.self,
            arrayLiteralElementTypeDescriptor: elementTypeDescriptor,
            maximumArrayLiteralElementCount: maximumElementCount,
            declarationID: declarationID
        ) { receiver, arguments in
            guard receiver == nil else {
                throw ConstExprValueError.malformedCollection(
                    "array literal adapter received an unexpected receiver"
                )
            }
            if let maximumElementCount,
               arguments.count > maximumElementCount
            {
                throw ConstExprValueError.malformedCollection(
                    "array literal adapter supports at most \(maximumElementCount) elements; found \(arguments.count)"
                )
            }
            let elements = try arguments.enumerated().map { index, argument in
                guard let argument else {
                    throw ConstExprValueError.malformedCollection(
                        "array literal adapter is missing element \(index)"
                    )
                }
                return try argument.require(Element.self)
            }
            return ConstExprValue(try build(elements))
        }
    }

    /// Creates the bounded adapter used by `@ConstExpr` for a real variadic
    /// `ExpressibleByArrayLiteral` witness. Swift does not provide a stable way
    /// to splat a runtime array into that witness, so the trampoline spells the
    /// supported arities explicitly. Standard `Array` and `Set` use separate
    /// unlimited adapters in the evaluator.
    static func arrayLiteral<Result, Element>(
        moduleName: String? = nil,
        result: Result.Type = Result.self,
        element: Element.Type = Element.self,
        elementTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        resultTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        maximumElementCount: Int = 32,
        declarationID: String? = nil
    ) -> Self
    where Result: ExpressibleByArrayLiteral & SendableMetatype,
          Element: SendableMetatype,
          Result.ArrayLiteralElement == Element {
        let effectiveMaximum = min(maximumElementCount, 32)
        return Self.arrayLiteral(
            moduleName: moduleName,
            result: result,
            element: element,
            elementTypeDescriptor: elementTypeDescriptor,
            resultTypeDescriptor: resultTypeDescriptor,
            maximumElementCount: effectiveMaximum,
            declarationID: declarationID
        ) { elements in
            switch elements.count {
            case 0:
                let witness = Result.init(arrayLiteral:)
                return witness()
            case 1: return Result(arrayLiteral: elements[0])
            case 2: return Result(arrayLiteral: elements[0], elements[1])
            case 3: return Result(arrayLiteral: elements[0], elements[1], elements[2])
            case 4: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3])
            case 5: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4])
            case 6: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5])
            case 7: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6])
            case 8: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7])
            case 9: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8])
            case 10: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9])
            case 11: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10])
            case 12: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11])
            case 13: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12])
            case 14: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13])
            case 15: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14])
            case 16: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15])
            case 17: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16])
            case 18: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17])
            case 19: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18])
            case 20: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19])
            case 21: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20])
            case 22: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21])
            case 23: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22])
            case 24: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23])
            case 25: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24])
            case 26: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25])
            case 27: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26])
            case 28: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26], elements[27])
            case 29: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26], elements[27], elements[28])
            case 30: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26], elements[27], elements[28], elements[29])
            case 31: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26], elements[27], elements[28], elements[29], elements[30])
            case 32: return Result(arrayLiteral: elements[0], elements[1], elements[2], elements[3], elements[4], elements[5], elements[6], elements[7], elements[8], elements[9], elements[10], elements[11], elements[12], elements[13], elements[14], elements[15], elements[16], elements[17], elements[18], elements[19], elements[20], elements[21], elements[22], elements[23], elements[24], elements[25], elements[26], elements[27], elements[28], elements[29], elements[30], elements[31])
            default:
                throw ConstExprValueError.malformedCollection(
                    "automatic array literal adapter supports at most 32 elements"
                )
            }
        }
    }

    static func prefixOperator<A, R>(
        _ symbol: String,
        operand: A.Type = A.self,
        result: R.Type = R.self,
        isThrowing: Bool = false,
        evaluate: @escaping @Sendable (A) throws -> R
    ) -> Self {
        Self(
            name: symbol,
            kind: .prefixOperator,
            parameterLabels: [nil],
            parameterTypes: [A.self],
            resultType: R.self,
            isThrowing: isThrowing
        ) { _, arguments in
            guard arguments.count == 1, let argument = arguments[0] else {
                throw ConstExprValueError.malformedCollection("prefix operator '\(symbol)' expected one operand")
            }
            return ConstExprValue(try evaluate(argument.require(A.self)))
        }
    }

    static func infixOperator<L, R, Output>(
        _ symbol: String,
        left: L.Type = L.self,
        right: R.Type = R.self,
        result: Output.Type = Output.self,
        precedenceGroup: String? = nil,
        associativity: ConstExprOperatorAssociativity? = nil,
        isThrowing: Bool = false,
        evaluate: @escaping @Sendable (L, R) throws -> Output
    ) -> Self {
        Self(
            name: symbol,
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [L.self, R.self],
            resultType: Output.self,
            isThrowing: isThrowing,
            precedenceGroup: precedenceGroup,
            associativity: associativity
        ) { _, arguments in
            guard arguments.count == 2, let lhs = arguments[0], let rhs = arguments[1] else {
                throw ConstExprValueError.malformedCollection("infix operator '\(symbol)' expected two operands")
            }
            return ConstExprValue(try evaluate(lhs.require(L.self), rhs.require(R.self)))
        }
    }

    static func postfixOperator<A, R>(
        _ symbol: String,
        operand: A.Type = A.self,
        result: R.Type = R.self,
        isThrowing: Bool = false,
        evaluate: @escaping @Sendable (A) throws -> R
    ) -> Self {
        Self(
            name: symbol,
            kind: .postfixOperator,
            parameterLabels: [nil],
            parameterTypes: [A.self],
            resultType: R.self,
            isThrowing: isThrowing
        ) { _, arguments in
            guard arguments.count == 1, let argument = arguments[0] else {
                throw ConstExprValueError.malformedCollection("postfix operator '\(symbol)' expected one operand")
            }
            return ConstExprValue(try evaluate(argument.require(A.self)))
        }
    }
}

/// An immutable collection of generated and manual registrations.
