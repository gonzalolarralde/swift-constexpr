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
    public let defaultArgumentCount: Int
    public let minimumArgumentCount: Int
    public let maximumArgumentCount: Int
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
    public let availability: [ConstExprAvailability]
    public let isDisfavoredOverload: Bool
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
        availability: [ConstExprAvailability] = [],
        isDisfavoredOverload: Bool = false,
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
        self.defaultArgumentCount = defaultedParameters.filter(parameterTypes.indices.contains).count
        self.minimumArgumentCount = kind == .arrayLiteral
            ? 0
            : parameterTypes.count - self.defaultArgumentCount
        self.maximumArgumentCount = kind == .arrayLiteral
            ? (maximumArrayLiteralElementCount ?? .max)
            : parameterTypes.count
        self.resultType = resultType
        self.resultTypeDescriptor = resultTypeDescriptor
            ?? .inferred(resultType)
        self.arrayLiteralElementType = arrayLiteralElementType
        self.arrayLiteralElementTypeDescriptor = arrayLiteralElementTypeDescriptor
            ?? arrayLiteralElementType.map { .inferred($0) }
        self.maximumArrayLiteralElementCount = maximumArrayLiteralElementCount
        self.isThrowing = isThrowing
        self.availability = availability
        self.isDisfavoredOverload = isDisfavoredOverload
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
