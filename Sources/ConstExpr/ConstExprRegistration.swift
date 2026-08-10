/// The source-level operation represented by a generated or manual adapter.
public enum ConstExprRegistrationKind: String, Sendable, Hashable {
    case function
    case constant
    case initializer
    case instanceMethod
    case staticMethod
    case instanceProperty
    case staticProperty
    case subscriptGetter
    case prefixOperator
    case infixOperator
    case postfixOperator
    /// An explicitly trusted adapter for Swift array-literal syntax. Unlike
    /// ordinary callable registrations, its arguments are a variadic sequence
    /// whose common static type is described by the array-literal metadata.
    case arrayLiteral
}

/// Associativity metadata for manually registered infix operators.
public enum ConstExprOperatorAssociativity: String, Sendable, Hashable {
    case left
    case right
    case none
}

/// Recovers the associated element metatype from an erased standard-library
/// array-literal conformance. Keeping this check in the runtime prevents a
/// malformed manual registration from teaching the evaluator conversions that
/// Swift source does not have.
func constExprArrayLiteralElementType(of type: Any.Type) -> Any.Type? {
    guard let conforming = type as? any ExpressibleByArrayLiteral.Type else {
        return nil
    }
    func open<T: ExpressibleByArrayLiteral>(_ type: T.Type) -> Any.Type {
        T.ArrayLiteralElement.self
    }
    return _openExistential(conforming, do: open)
}

/// A callable declaration that can consume evaluated values and invoke linked
/// Swift code. Its invocation is `@Sendable`, so manually registered callbacks
/// may capture only concurrency-safe state.
public struct ConstExprRegistration: Sendable {
    public typealias Invocation = @Sendable (
        _ receiver: ConstExprValue?,
        _ arguments: [ConstExprValue?]
    ) throws -> ConstExprValue

    public let moduleName: String?
    public let name: String
    public let kind: ConstExprRegistrationKind
    public let ownerType: Any.Type?
    public let ownerName: String?
    public let parameterLabels: [String?]
    public let parameterTypes: [Any.Type]
    public let parameterTypeDescriptors: [ConstExprStaticTypeDescriptor]
    public let defaultedParameters: Set<Int>
    public let resultType: Any.Type
    public let resultTypeDescriptor: ConstExprStaticTypeDescriptor
    /// The associated `ArrayLiteralElement` type for an `.arrayLiteral`
    /// registration. Ordinary callable parameter metadata intentionally stays
    /// empty because an array literal may contain any number of elements.
    public let arrayLiteralElementType: Any.Type?
    public let arrayLiteralElementTypeDescriptor: ConstExprStaticTypeDescriptor?
    /// `nil` means the adapter accepts any number of elements. Macro-generated
    /// protocol-witness trampolines are bounded because Swift has no stable
    /// runtime-array splat for a variadic initializer.
    public let maximumArrayLiteralElementCount: Int?
    /// Whether invoking the represented declaration requires a source-level
    /// `try`. The evaluator never uses this to infer that an unmarked source
    /// call is valid; it only executes throwing registrations while visiting
    /// a `try`, `try?`, or `try!` expression.
    public let isThrowing: Bool
    public let declarationID: String
    public let precedenceGroup: String?
    public let associativity: ConstExprOperatorAssociativity?

    let invocation: Invocation

    public init(
        moduleName: String? = nil,
        name: String,
        kind: ConstExprRegistrationKind,
        ownerType: Any.Type? = nil,
        ownerName: String? = nil,
        parameterLabels: [String?] = [],
        parameterTypes: [Any.Type] = [],
        parameterTypeDescriptors: [ConstExprStaticTypeDescriptor]? = nil,
        defaultedParameters: Set<Int> = [],
        resultType: Any.Type = Any.self,
        resultTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        arrayLiteralElementType: Any.Type? = nil,
        arrayLiteralElementTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        maximumArrayLiteralElementCount: Int? = nil,
        isThrowing: Bool = false,
        precedenceGroup: String? = nil,
        associativity: ConstExprOperatorAssociativity? = nil,
        declarationID: String? = nil,
        invoke: @escaping Invocation
    ) {
        self.moduleName = moduleName
        self.name = name
        self.kind = kind
        self.ownerType = ownerType
        self.ownerName = ownerName ?? ownerType.map(String.init(reflecting:))
        self.parameterLabels = parameterLabels
        self.parameterTypes = parameterTypes
        self.parameterTypeDescriptors = parameterTypeDescriptors
            ?? parameterTypes.map { .inferred($0) }
        self.defaultedParameters = defaultedParameters
        self.resultType = resultType
        self.resultTypeDescriptor = resultTypeDescriptor
            ?? .inferred(resultType)
        self.arrayLiteralElementType = arrayLiteralElementType
        self.arrayLiteralElementTypeDescriptor = arrayLiteralElementTypeDescriptor
            ?? arrayLiteralElementType.map { .inferred($0) }
        self.maximumArrayLiteralElementCount = maximumArrayLiteralElementCount
        self.isThrowing = isThrowing
        self.precedenceGroup = precedenceGroup
        self.associativity = associativity
        self.declarationID = declarationID ?? Self.makeID(
            moduleName: moduleName,
            ownerName: ownerName ?? ownerType.map(String.init(reflecting:)),
            name: name,
            kind: kind,
            labels: parameterLabels,
            parameterTypes: parameterTypes,
            resultType: resultType
        )
        self.invocation = invoke
    }

    public func invoke(
        receiver: ConstExprValue? = nil,
        arguments: [ConstExprValue?] = []
    ) throws -> ConstExprValue {
        let value = try invocation(receiver, arguments)
        return try value.withStaticType(
            resultType,
            descriptor: resultTypeDescriptor
        )
    }

    func invoke(_ receiver: ConstExprValue?, _ arguments: [ConstExprValue]) throws -> ConstExprValue {
        try invoke(receiver: receiver, arguments: arguments.map(Optional.some))
    }

    public var minimumArgumentCount: Int {
        if kind == .arrayLiteral { return 0 }
        return parameterTypes.count
            - defaultedParameters.filter(parameterTypes.indices.contains).count
    }

    public var maximumArgumentCount: Int {
        if kind == .arrayLiteral {
            return maximumArrayLiteralElementCount ?? .max
        }
        return parameterTypes.count
    }

    /// Maps source arguments to declaration parameters while honoring omitted
    /// defaults. Swift argument order remains significant, including when two
    /// parameters use the same external label.
    public func argumentMapping(labels: [String?]) -> [Int?]? {
        guard parameterLabels.count == parameterTypes.count else { return nil }
        guard defaultedParameters.allSatisfy(parameterTypes.indices.contains) else { return nil }
        guard labels.count >= minimumArgumentCount, labels.count <= parameterTypes.count else {
            return nil
        }

        var mapping = Array<Int?>(repeating: nil, count: parameterTypes.count)
        var parameterIndex = 0

        for (argumentIndex, label) in labels.enumerated() {
            while parameterIndex < parameterTypes.count,
                  parameterLabels[parameterIndex] != label
            {
                guard defaultedParameters.contains(parameterIndex) else { return nil }
                parameterIndex += 1
            }
            guard parameterIndex < parameterTypes.count else { return nil }
            mapping[parameterIndex] = argumentIndex
            parameterIndex += 1
        }

        while parameterIndex < parameterTypes.count {
            guard defaultedParameters.contains(parameterIndex) else { return nil }
            parameterIndex += 1
        }
        return mapping
    }

    /// Metadata errors are reported by the registry instead of trapping during
    /// registry construction. This keeps macro-generated registry expressions
    /// nonthrowing and lets command-line runners present actionable diagnostics.
    public var validationDiagnostics: [ConstExprDiagnostic] {
        var diagnostics: [ConstExprDiagnostic] = []

        if name.isEmpty {
            diagnostics.append(metadataError("registration name must not be empty"))
        }
        if parameterLabels.count != parameterTypes.count {
            diagnostics.append(
                metadataError(
                    "parameterLabels has \(parameterLabels.count) elements but parameterTypes has \(parameterTypes.count)"
                )
            )
        }
        if parameterTypeDescriptors.count != parameterTypes.count {
            diagnostics.append(
                metadataError(
                    "parameterTypeDescriptors has \(parameterTypeDescriptors.count) elements but parameterTypes has \(parameterTypes.count)"
                )
            )
        }
        for (index, pair) in zip(parameterTypes, parameterTypeDescriptors).enumerated()
        where !pair.1.matches(type: pair.0) {
            diagnostics.append(
                metadataError(
                    "parameter type descriptor at index \(index) does not match \(String(reflecting: pair.0))"
                )
            )
        }
        if !resultTypeDescriptor.matches(type: resultType) {
            diagnostics.append(
                metadataError(
                    "result type descriptor does not match \(String(reflecting: resultType))"
                )
            )
        }
        if let arrayLiteralElementType,
           arrayLiteralElementTypeDescriptor?.matches(type: arrayLiteralElementType) != true
        {
            diagnostics.append(
                metadataError(
                    "array literal element type descriptor does not match \(String(reflecting: arrayLiteralElementType))"
                )
            )
        }
        let invalidDefaults = defaultedParameters.filter { !parameterTypes.indices.contains($0) }.sorted()
        if !invalidDefaults.isEmpty {
            diagnostics.append(
                metadataError("defaulted parameter indices are out of bounds: \(invalidDefaults)")
            )
        }
        if kind != .arrayLiteral,
           arrayLiteralElementType != nil
                || arrayLiteralElementTypeDescriptor != nil
                || maximumArrayLiteralElementCount != nil
        {
            diagnostics.append(
                metadataError("array literal metadata is valid only for arrayLiteral registrations")
            )
        }

        switch kind {
        case .instanceMethod, .instanceProperty, .subscriptGetter:
            if ownerType == nil {
                diagnostics.append(
                    metadataError("\(kind.rawValue) registration requires an owner type for receiver dispatch")
                )
            }
        case .initializer, .staticMethod, .staticProperty:
            if ownerType == nil, ownerName == nil {
                diagnostics.append(metadataError("\(kind.rawValue) registration requires an owner"))
            }
        case .arrayLiteral:
            validateArrayLiteralMetadata(into: &diagnostics)
        case .function, .constant, .prefixOperator, .infixOperator, .postfixOperator:
            break
        }

        let requiredArity: Int?
        switch kind {
        case .constant, .instanceProperty, .staticProperty:
            requiredArity = 0
        case .prefixOperator, .postfixOperator:
            requiredArity = 1
        case .infixOperator:
            requiredArity = 2
        default:
            requiredArity = nil
        }
        if let requiredArity, parameterTypes.count != requiredArity {
            diagnostics.append(
                metadataError(
                    "\(kind.rawValue) registration requires \(requiredArity) parameter\(requiredArity == 1 ? "" : "s")"
                )
            )
        }
        if requiredArity != nil, !defaultedParameters.isEmpty {
            diagnostics.append(metadataError("\(kind.rawValue) registration cannot have defaulted parameters"))
        }

        switch kind {
        case .prefixOperator, .infixOperator, .postfixOperator:
            if parameterLabels.contains(where: { $0 != nil }) {
                diagnostics.append(
                    metadataError("operator registrations require unlabeled parameters")
                )
            }
        default:
            break
        }

        if kind != .infixOperator, precedenceGroup != nil || associativity != nil {
            diagnostics.append(
                metadataError("precedence and associativity metadata is valid only for infix operators")
            )
        }

        return diagnostics
    }

    private func validateArrayLiteralMetadata(
        into diagnostics: inout [ConstExprDiagnostic]
    ) {
        guard let ownerType else {
            diagnostics.append(metadataError("arrayLiteral registration requires an owner type"))
            return
        }
        guard ObjectIdentifier(ownerType) == ObjectIdentifier(resultType) else {
            diagnostics.append(
                metadataError("arrayLiteral registration owner type must exactly match its result type")
            )
            return
        }
        guard let associatedElementType = constExprArrayLiteralElementType(of: resultType) else {
            diagnostics.append(
                metadataError("arrayLiteral registration result must conform to ExpressibleByArrayLiteral")
            )
            return
        }
        guard let arrayLiteralElementType else {
            diagnostics.append(
                metadataError("arrayLiteral registration requires an element type")
            )
            return
        }
        if ObjectIdentifier(arrayLiteralElementType) != ObjectIdentifier(associatedElementType) {
            diagnostics.append(
                metadataError(
                    "arrayLiteral element type must exactly match the result's ArrayLiteralElement"
                )
            )
        }
        if arrayLiteralElementTypeDescriptor == nil {
            diagnostics.append(
                metadataError("arrayLiteral registration requires an element type descriptor")
            )
        }
        if !parameterLabels.isEmpty || !parameterTypes.isEmpty
            || !parameterTypeDescriptors.isEmpty || !defaultedParameters.isEmpty
        {
            diagnostics.append(
                metadataError("arrayLiteral registration must not use ordinary parameter metadata")
            )
        }
        if isThrowing {
            diagnostics.append(
                metadataError("arrayLiteral registration cannot require source-level try")
            )
        }
        if let maximumArrayLiteralElementCount,
           maximumArrayLiteralElementCount < 0
        {
            diagnostics.append(
                metadataError("arrayLiteral maximum element count must not be negative")
            )
        }
    }

    public var isValid: Bool {
        validationDiagnostics.isEmpty
    }

    private func metadataError(_ message: String) -> ConstExprDiagnostic {
        ConstExprDiagnostic(
            severity: .error,
            code: "invalid-registration",
            message: "invalid const-expression registration '\(declarationID)': \(message)"
        )
    }

    private static func makeID(
        moduleName: String?,
        ownerName: String?,
        name: String,
        kind: ConstExprRegistrationKind,
        labels: [String?],
        parameterTypes: [Any.Type],
        resultType: Any.Type
    ) -> String {
        let qualifiedName = [moduleName, ownerName, name]
            .compactMap { $0 }
            .joined(separator: ".")
        let parameters = zip(labels, parameterTypes).map { label, type in
            "\(label ?? "_"):\(String(reflecting: type))"
        }.joined(separator: ",")
        return "\(kind.rawValue):\(qualifiedName)(\(parameters))->\(String(reflecting: resultType))"
    }
}

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
public struct ConstExprRegistry: Sendable {
    public let registrations: [ConstExprRegistration]

    public init(registrations: [ConstExprRegistration] = []) {
        self.registrations = registrations
    }

    /// Convenience initialization for one or more registrations without an
    /// intermediate array. `ConstExprRegistry()` remains available through the
    /// defaulted array initializer.
    public init(
        _ registration: ConstExprRegistration,
        _ additionalRegistrations: ConstExprRegistration...
    ) {
        self.registrations = [registration] + additionalRegistrations
    }

    public static var empty: Self { Self() }

    public func appending(_ registration: ConstExprRegistration) -> Self {
        Self(registrations: registrations + [registration])
    }

    public func appending(contentsOf registrations: [ConstExprRegistration]) -> Self {
        Self(registrations: self.registrations + registrations)
    }

    public func appending(contentsOf registry: Self) -> Self {
        appending(contentsOf: registry.registrations)
    }

    public func candidates(
        named name: String,
        kind: ConstExprRegistrationKind? = nil,
        ownerType: Any.Type? = nil,
        ownerName: String? = nil
    ) -> [ConstExprRegistration] {
        registrations.filter { registration in
            guard registration.name == name else { return false }
            if let kind, registration.kind != kind { return false }
            if let ownerType {
                guard let candidateType = registration.ownerType,
                      ObjectIdentifier(candidateType) == ObjectIdentifier(ownerType)
                else { return false }
            }
            if let ownerName {
                guard let candidateName = registration.ownerName else { return false }
                if ownerName.contains(".") {
                    guard candidateName == ownerName
                            || candidateName.hasSuffix("." + ownerName)
                    else { return false }
                } else {
                    guard candidateName == ownerName
                            || candidateName.split(separator: ".").last.map(String.init) == ownerName
                    else { return false }
                }
            }
            return true
        }
    }

    public var validationDiagnostics: [ConstExprDiagnostic] {
        let metadata = registrations.flatMap(\.validationDiagnostics)
        let collisions = Dictionary(grouping: registrations, by: \.declarationID)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        let collisionDiagnostics = collisions.map {
            ConstExprDiagnostic(
                severity: .error,
                code: "registry-collision",
                message: "duplicate const-expression registration '\($0)'"
            )
        }
        return metadata + collisionDiagnostics
    }

    public var isValid: Bool {
        !validationDiagnostics.contains { $0.severity == .error }
    }
}
