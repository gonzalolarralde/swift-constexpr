/// Errors produced by label-keyed manual invocation adapters.
public enum ConstExprInvocationArgumentsError: Error, Sendable, Equatable {
    case metadataCountMismatch(labels: Int, values: Int)
    case duplicateLabel(String)
    case unknownLabel(String)
    case omittedValue(String)
}

/// A checked label view over a registration's source-ordered invocation slots.
/// This is intended for a small number of exceptional manual adapters whose
/// declarations have many defaults. Ordinary generated adapters remain faster
/// and continue to consume positional slots directly.
public struct ConstExprInvocationArguments {
    private let indexes: [String: Int]
    private let values: [ConstExprValue?]

    public init(
        parameterLabels: [String?],
        values: [ConstExprValue?]
    ) throws {
        guard parameterLabels.count == values.count else {
            throw ConstExprInvocationArgumentsError.metadataCountMismatch(
                labels: parameterLabels.count,
                values: values.count
            )
        }
        var indexes: [String: Int] = [:]
        for (index, label) in parameterLabels.enumerated() {
            guard let label else { continue }
            guard indexes.updateValue(index, forKey: label) == nil else {
                throw ConstExprInvocationArgumentsError.duplicateLabel(label)
            }
        }
        self.indexes = indexes
        self.values = values
    }

    public func wasProvided(_ label: String) throws -> Bool {
        guard let index = indexes[label] else {
            throw ConstExprInvocationArgumentsError.unknownLabel(label)
        }
        return values[index] != nil
    }

    public func require<Value>(
        _ label: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        guard let value = try value(for: label) else {
            throw ConstExprInvocationArgumentsError.omittedValue(label)
        }
        return try value.require(type)
    }

    /// Returns `nil` when the source omitted this defaulted slot. To decode an
    /// actual optional parameter, pass its optional metatype as `Value`.
    public func optional<Value>(
        _ label: String,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        try value(for: label).map { try $0.require(type) }
    }

    public func value(for label: String) throws -> ConstExprValue? {
        guard let index = indexes[label] else {
            throw ConstExprInvocationArgumentsError.unknownLabel(label)
        }
        return values[index]
    }
}

public extension ConstExprRegistration {
    typealias LabelKeyedInvocation = @Sendable (
        _ receiver: ConstExprValue?,
        _ arguments: ConstExprInvocationArguments
    ) throws -> ConstExprValue

    /// Creates a registration whose exceptional manual adapter consumes
    /// arguments by checked source label instead of numeric position.
    static func labelKeyed(
        moduleName: String? = nil,
        name: String,
        kind: ConstExprRegistrationKind,
        ownerType: Any.Type? = nil,
        ownerName: String? = nil,
        parameterLabels: [String?],
        parameterTypes: [Any.Type],
        parameterTypeDescriptors: [ConstExprStaticTypeDescriptor]? = nil,
        defaultedParameters: Set<Int> = [],
        resultType: Any.Type = Any.self,
        resultTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        isThrowing: Bool = false,
        availability: [ConstExprAvailability] = [],
        isDisfavoredOverload: Bool = false,
        declarationID: String? = nil,
        invoke: @escaping LabelKeyedInvocation
    ) -> Self {
        Self(
            moduleName: moduleName,
            name: name,
            kind: kind,
            ownerType: ownerType,
            ownerName: ownerName,
            parameterLabels: parameterLabels,
            parameterTypes: parameterTypes,
            parameterTypeDescriptors: parameterTypeDescriptors,
            defaultedParameters: defaultedParameters,
            resultType: resultType,
            resultTypeDescriptor: resultTypeDescriptor,
            isThrowing: isThrowing,
            availability: availability,
            isDisfavoredOverload: isDisfavoredOverload,
            declarationID: declarationID
        ) { receiver, values in
            try invoke(
                receiver,
                ConstExprInvocationArguments(
                    parameterLabels: parameterLabels,
                    values: values
                )
            )
        }
    }
}
