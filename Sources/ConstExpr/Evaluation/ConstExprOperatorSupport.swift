extension ConstExprOperators {
    static func valuesEqual(_ left: ConstExprValue, _ right: ConstExprValue) -> Bool? {
        guard
            hasSameEqualityShape(
                left.staticTypeDescriptor,
                right.staticTypeDescriptor
            ),
            supportsBuiltInEquality(left.staticTypeDescriptor),
            supportsBuiltInEquality(right.staticTypeDescriptor)
        else { return nil }
        switch (left.payload, right.payload) {
        case (.optional(let lhs), .optional(let rhs)):
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.some(let lhs), .some(let rhs)): return valuesEqual(lhs, rhs)
            default: return false
            }

        case (.array(let lhs), .array(let rhs)):
            guard lhs.count == rhs.count else { return false }
            var answer = true
            for (leftElement, rightElement) in zip(lhs, rhs) {
                guard let equal = valuesEqual(leftElement, rightElement) else { return nil }
                answer = answer && equal
            }
            return answer

        case (.tuple(let lhs), .tuple(let rhs)):
            guard lhs.count == rhs.count else { return false }
            var answer = true
            for (leftElement, rightElement) in zip(lhs, rhs) {
                guard leftElement.label == rightElement.label else { return false }
                guard let equal = valuesEqual(
                    leftElement.value,
                    rightElement.value
                ) else { return nil }
                answer = answer && equal
            }
            return answer

        case (.dictionary(let lhs), .dictionary(let rhs)):
            guard lhs.count == rhs.count else { return false }
            var unmatched = rhs
            for entry in lhs {
                var match: Int?
                var encounteredUnknown = false
                for index in unmatched.indices {
                    guard let keysEqual = valuesEqual(entry.0, unmatched[index].0) else {
                        encounteredUnknown = true
                        continue
                    }
                    guard keysEqual else { continue }
                    guard let entryValuesEqual = valuesEqual(entry.1, unmatched[index].1) else {
                        encounteredUnknown = true
                        continue
                    }
                    if entryValuesEqual {
                        match = index
                        break
                    }
                }
                guard let index = match else {
                    return encounteredUnknown ? nil : false
                }
                unmatched.remove(at: index)
            }
            return true

        default:
            break
        }

        guard ObjectIdentifier(left.staticType) == ObjectIdentifier(right.staticType) else {
            return false
        }
        if left.staticType == Int.self {
            return (try? left.require(Int.self)) == (try? right.require(Int.self))
        }
        if left.staticType == Double.self {
            return (try? left.require(Double.self)) == (try? right.require(Double.self))
        }
        if left.staticType == Float.self {
            return (try? left.require(Float.self)) == (try? right.require(Float.self))
        }
        if left.staticType == Bool.self {
            return (try? left.require(Bool.self)) == (try? right.require(Bool.self))
        }
        if left.staticType == String.self {
            return (try? left.require(String.self)) == (try? right.require(String.self))
        }
        if left.staticType == Character.self {
            return (try? left.require(Character.self)) == (try? right.require(Character.self))
        }
        if left.staticType == Int8.self { return (try? left.require(Int8.self)) == (try? right.require(Int8.self)) }
        if left.staticType == Int16.self { return (try? left.require(Int16.self)) == (try? right.require(Int16.self)) }
        if left.staticType == Int32.self { return (try? left.require(Int32.self)) == (try? right.require(Int32.self)) }
        if left.staticType == Int64.self { return (try? left.require(Int64.self)) == (try? right.require(Int64.self)) }
        if left.staticType == UInt.self { return (try? left.require(UInt.self)) == (try? right.require(UInt.self)) }
        if left.staticType == UInt8.self { return (try? left.require(UInt8.self)) == (try? right.require(UInt8.self)) }
        if left.staticType == UInt16.self { return (try? left.require(UInt16.self)) == (try? right.require(UInt16.self)) }
        if left.staticType == UInt32.self { return (try? left.require(UInt32.self)) == (try? right.require(UInt32.self)) }
        if left.staticType == UInt64.self { return (try? left.require(UInt64.self)) == (try? right.require(UInt64.self)) }
        return nil
    }

    /// Swift's built-in structural equality overloads compare one concrete
    /// static type. Equal-looking runtime payloads are not enough: for example,
    /// `nil as Int?` and `nil as String?` cannot be compared in Swift source.
    static func hasSameEqualityShape(
        _ left: ConstExprStaticTypeDescriptor,
        _ right: ConstExprStaticTypeDescriptor
    ) -> Bool {
        switch (left, right) {
        case let (.leaf(leftType, _, _, _, _), .leaf(rightType, _, _, _, _)):
            return ObjectIdentifier(leftType) == ObjectIdentifier(rightType)
        case let (.optional(left), .optional(right)),
             let (.array(left), .array(right)):
            return hasSameEqualityShape(left, right)
        case let (
            .dictionary(leftKey, leftValue),
            .dictionary(rightKey, rightValue)
        ):
            return hasSameEqualityShape(leftKey, rightKey)
                && hasSameEqualityShape(leftValue, rightValue)
        case let (.tuple(left), .tuple(right)):
            return left.count == right.count
                && zip(left, right).allSatisfy {
                    hasSameEqualityShape($0.0, $0.1)
                }
        default:
            return false
        }
    }

    /// Runtime payloads do not prove that their erased source-static type
    /// satisfies Swift's conditional `Equatable` conformances. In particular,
    /// empty `[Any]`/`[Key: Any]` values and `nil as Any?` have no child value
    /// from which an unsupported constraint could otherwise be discovered.
    static func supportsBuiltInEquality(
        _ descriptor: ConstExprStaticTypeDescriptor
    ) -> Bool {
        switch descriptor {
        case .leaf(let type, _, _, _, _):
            return type == Bool.self
                || type == String.self
                || type == Character.self
                || type == Int.self
                || type == Int8.self
                || type == Int16.self
                || type == Int32.self
                || type == Int64.self
                || type == UInt.self
                || type == UInt8.self
                || type == UInt16.self
                || type == UInt32.self
                || type == UInt64.self
                || type == Float.self
                || type == Double.self
        case .optional(let wrapped), .array(let wrapped), .set(let wrapped):
            return supportsBuiltInEquality(wrapped)
        case .dictionary(let key, let value):
            return supportsBuiltInEquality(key) && supportsBuiltInEquality(value)
        case .tuple(let elements):
            return elements.allSatisfy(supportsBuiltInEquality)
        }
    }

    static func signedPrefix<T: FixedWidthInteger & SignedInteger>(
        _ symbol: String,
        _ operand: ConstExprValue,
        as type: T.Type
    ) -> ConstExprOperatorResult? {
        guard operand.staticType == type, let value = try? operand.require(type) else { return nil }
        switch symbol {
        case "+": return .value(ConstExprValue(value))
        case "-":
            let result = T.zero.subtractingReportingOverflow(value)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "~": return .value(ConstExprValue(~value))
        default: return .unsupported
        }
    }

    static func unsignedPrefix<T: FixedWidthInteger & UnsignedInteger>(
        _ symbol: String,
        _ operand: ConstExprValue,
        as type: T.Type
    ) -> ConstExprOperatorResult? {
        guard operand.staticType == type, let value = try? operand.require(type) else { return nil }
        switch symbol {
        case "+": return .value(ConstExprValue(value))
        case "~": return .value(ConstExprValue(~value))
        default: return .unsupported
        }
    }

    static func fixedWidthInteger<T: FixedWidthInteger>(
        _ symbol: String,
        _ left: ConstExprValue,
        _ right: ConstExprValue,
        as type: T.Type
    ) -> ConstExprOperatorResult? {
        guard left.staticType == type, right.staticType == type,
            let lhs = try? left.require(type),
            let rhs = try? right.require(type)
        else { return nil }

        switch symbol {
        case "+":
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "-":
            let result = lhs.subtractingReportingOverflow(rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "*":
            let result = lhs.multipliedReportingOverflow(by: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "/":
            guard rhs != 0 else { return divisionByZero(symbol) }
            let result = lhs.dividedReportingOverflow(by: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "%":
            guard rhs != 0 else { return divisionByZero(symbol) }
            let result = lhs.remainderReportingOverflow(dividingBy: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "&+": return .value(ConstExprValue(lhs &+ rhs))
        case "&-": return .value(ConstExprValue(lhs &- rhs))
        case "&*": return .value(ConstExprValue(lhs &* rhs))
        case "&": return .value(ConstExprValue(lhs & rhs))
        case "|": return .value(ConstExprValue(lhs | rhs))
        case "^": return .value(ConstExprValue(lhs ^ rhs))
        case "<<": return .value(ConstExprValue(lhs << rhs))
        case ">>": return .value(ConstExprValue(lhs >> rhs))
        case "==": return .value(ConstExprValue(lhs == rhs))
        case "!=": return .value(ConstExprValue(lhs != rhs))
        case "<": return .value(ConstExprValue(lhs < rhs))
        case "<=": return .value(ConstExprValue(lhs <= rhs))
        case ">": return .value(ConstExprValue(lhs > rhs))
        case ">=": return .value(ConstExprValue(lhs >= rhs))
        default: return .unsupported
        }
    }

    static func fixedWidthShift<T: FixedWidthInteger>(
        _ symbol: String,
        _ left: ConstExprValue,
        _ right: ConstExprValue,
        as type: T.Type
    ) -> ConstExprOperatorResult? {
        guard left.staticType == type,
            let lhs = try? left.require(type),
            let count = normalizedShiftCount(right, cappedAt: T.bitWidth)
        else { return nil }

        switch (symbol, count.isNegative) {
        case ("<<", false), (">>", true):
            return .value(ConstExprValue(lhs << count.magnitude))
        case (">>", false), ("<<", true):
            return .value(ConstExprValue(lhs >> count.magnitude))
        default:
            return .unsupported
        }
    }

    static func normalizedShiftCount(
        _ value: ConstExprValue,
        cappedAt cap: Int
    ) -> (isNegative: Bool, magnitude: Int)? {
        if let count = signedShiftCount(value, as: Int.self, cappedAt: cap) { return count }
        if let count = signedShiftCount(value, as: Int8.self, cappedAt: cap) { return count }
        if let count = signedShiftCount(value, as: Int16.self, cappedAt: cap) { return count }
        if let count = signedShiftCount(value, as: Int32.self, cappedAt: cap) { return count }
        if let count = signedShiftCount(value, as: Int64.self, cappedAt: cap) { return count }
        if let count = unsignedShiftCount(value, as: UInt.self, cappedAt: cap) { return count }
        if let count = unsignedShiftCount(value, as: UInt8.self, cappedAt: cap) { return count }
        if let count = unsignedShiftCount(value, as: UInt16.self, cappedAt: cap) { return count }
        if let count = unsignedShiftCount(value, as: UInt32.self, cappedAt: cap) { return count }
        if let count = unsignedShiftCount(value, as: UInt64.self, cappedAt: cap) { return count }
        return nil
    }

    static func signedShiftCount<T: FixedWidthInteger & SignedInteger>(
        _ value: ConstExprValue,
        as type: T.Type,
        cappedAt cap: Int
    ) -> (isNegative: Bool, magnitude: Int)? {
        guard value.staticType == type, let raw = try? value.require(type) else { return nil }
        let positiveCap = T(cap)
        if raw >= positiveCap { return (false, cap) }
        if raw <= -positiveCap { return (true, cap) }
        if raw < 0 { return (true, Int(-raw)) }
        return (false, Int(raw))
    }

    static func unsignedShiftCount<T: FixedWidthInteger & UnsignedInteger>(
        _ value: ConstExprValue,
        as type: T.Type,
        cappedAt cap: Int
    ) -> (isNegative: Bool, magnitude: Int)? {
        guard value.staticType == type, let raw = try? value.require(type) else { return nil }
        if raw >= T(cap) { return (false, cap) }
        return (false, Int(raw))
    }

    static func integer(_ symbol: String, _ lhs: Int, _ rhs: Int) -> ConstExprOperatorResult {
        switch symbol {
        case "+":
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "-":
            let result = lhs.subtractingReportingOverflow(rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "*":
            let result = lhs.multipliedReportingOverflow(by: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "/":
            guard rhs != 0 else { return divisionByZero(symbol) }
            let result = lhs.dividedReportingOverflow(by: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "%":
            guard rhs != 0 else { return divisionByZero(symbol) }
            let result = lhs.remainderReportingOverflow(dividingBy: rhs)
            return result.overflow ? overflow(symbol) : .value(ConstExprValue(result.partialValue))
        case "&+": return .value(ConstExprValue(lhs &+ rhs))
        case "&-": return .value(ConstExprValue(lhs &- rhs))
        case "&*": return .value(ConstExprValue(lhs &* rhs))
        case "&": return .value(ConstExprValue(lhs & rhs))
        case "|": return .value(ConstExprValue(lhs | rhs))
        case "^": return .value(ConstExprValue(lhs ^ rhs))
        case "<<": return .value(ConstExprValue(lhs << rhs))
        case ">>": return .value(ConstExprValue(lhs >> rhs))
        case "==": return .value(ConstExprValue(lhs == rhs))
        case "!=": return .value(ConstExprValue(lhs != rhs))
        case "<": return .value(ConstExprValue(lhs < rhs))
        case "<=": return .value(ConstExprValue(lhs <= rhs))
        case ">": return .value(ConstExprValue(lhs > rhs))
        case ">=": return .value(ConstExprValue(lhs >= rhs))
        default: return .unsupported
        }
    }

    static func floating<T: BinaryFloatingPoint>(
        _ symbol: String,
        _ lhs: T,
        _ rhs: T
    ) -> ConstExprOperatorResult {
        switch symbol {
        case "+": return .value(ConstExprValue(lhs + rhs))
        case "-": return .value(ConstExprValue(lhs - rhs))
        case "*": return .value(ConstExprValue(lhs * rhs))
        case "/": return .value(ConstExprValue(lhs / rhs))
        case "==": return .value(ConstExprValue(lhs == rhs))
        case "!=": return .value(ConstExprValue(lhs != rhs))
        case "<": return .value(ConstExprValue(lhs < rhs))
        case "<=": return .value(ConstExprValue(lhs <= rhs))
        case ">": return .value(ConstExprValue(lhs > rhs))
        case ">=": return .value(ConstExprValue(lhs >= rhs))
        default: return .unsupported
        }
    }

    static func overflow(_ symbol: String) -> ConstExprOperatorResult {
        .failure(code: "integer-overflow", message: "integer overflow while evaluating '\(symbol)'")
    }

    static func divisionByZero(_ symbol: String) -> ConstExprOperatorResult {
        .failure(code: "division-by-zero", message: "division by zero while evaluating '\(symbol)'")
    }
}


extension ConstExprValue.Payload {
    var isStructural: Bool {
        switch self {
        case .optional, .array, .dictionary, .tuple: return true
        case .opaque: return false
        }
    }
}
