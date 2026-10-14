#if !hasFeature(Embedded)
package extension ConstExprValue {
    func raw<T>(as type: T.Type) -> T? {
        guard hasRawValue, let rawValue else { return nil }
        return rawValue as? T
    }

    func convertedScalar<T>(to type: T.Type) -> T? {
        if let exact = raw(as: T.self) { return exact }
        guard let converted = literalConverted(to: T.self) else { return nil }
        return converted.raw(as: T.self)
    }

    func requireScalar<T>(_ type: T.Type) throws -> T {
        if let value: T = convertedScalar(to: type) {
            return value
        }
        throw ConstExprValueError.typeMismatch(
            expected: String(reflecting: T.self),
            actual: typeName
        )
    }

    var optionalPayload: ConstExprValue?? {
        guard case .optional(let value) = payload else { return nil }
        return .some(value)
    }

    var arrayPayload: [ConstExprValue]? {
        guard case .array(let values) = payload else { return nil }
        return values
    }

    var dictionaryPayload: [(ConstExprValue, ConstExprValue)]? {
        guard case .dictionary(let entries) = payload else { return nil }
        return entries
    }
}
#endif
