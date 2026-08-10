enum ConstExprOperatorResult {
    case value(ConstExprValue)
    case unsupported
    case failure(code: String, message: String)
}

enum ConstExprOperators {
    static func prefix(_ symbol: String, operand: ConstExprValue) -> ConstExprOperatorResult {
        if operand.staticType == Int.self {
            guard let value = try? operand.require(Int.self) else { return .unsupported }
            switch symbol {
            case "+": return .value(ConstExprValue(value))
            case "-":
                let result = Int.zero.subtractingReportingOverflow(value)
                return result.overflow
                    ? overflow(symbol)
                    : .value(ConstExprValue(result.partialValue))
            case "~": return .value(ConstExprValue(~value))
            default: return .unsupported
            }
        }

        if operand.staticType == Double.self {
            guard let value = try? operand.require(Double.self) else { return .unsupported }
            switch symbol {
            case "+": return .value(ConstExprValue(value))
            case "-": return .value(ConstExprValue(-value))
            default: return .unsupported
            }
        }

        if operand.staticType == Float.self {
            guard let value = try? operand.require(Float.self) else { return .unsupported }
            switch symbol {
            case "+": return .value(ConstExprValue(value))
            case "-": return .value(ConstExprValue(-value))
            default: return .unsupported
            }
        }

        if operand.staticType == Bool.self, symbol == "!",
            let value = try? operand.require(Bool.self)
        {
            return .value(ConstExprValue(!value))
        }

        if let result = signedPrefix(symbol, operand, as: Int8.self) { return result }
        if let result = signedPrefix(symbol, operand, as: Int16.self) { return result }
        if let result = signedPrefix(symbol, operand, as: Int32.self) { return result }
        if let result = signedPrefix(symbol, operand, as: Int64.self) { return result }
        if let result = unsignedPrefix(symbol, operand, as: UInt.self) { return result }
        if let result = unsignedPrefix(symbol, operand, as: UInt8.self) { return result }
        if let result = unsignedPrefix(symbol, operand, as: UInt16.self) { return result }
        if let result = unsignedPrefix(symbol, operand, as: UInt32.self) { return result }
        if let result = unsignedPrefix(symbol, operand, as: UInt64.self) { return result }

        return .unsupported
    }

    static func infix(
        _ symbol: String,
        left: ConstExprValue,
        right: ConstExprValue
    ) -> ConstExprOperatorResult {
        if case .array(let lhs) = left.payload,
            case .array(let rhs) = right.payload
        {
            switch symbol {
            case "+":
                guard let typeName = left.explicitTypeName,
                    typeName == right.explicitTypeName
                else { return .unsupported }
                return .value(.array(lhs + rhs, typeName: typeName))
            case "==", "!=":
                guard let typeName = left.explicitTypeName,
                    typeName == right.explicitTypeName
                else { return .unsupported }
                guard let equal = valuesEqual(left, right) else { return .unsupported }
                return .value(ConstExprValue(symbol == "==" ? equal : !equal))
            default:
                return .unsupported
            }
        }

        if case .optional = left.payload, case .optional = right.payload,
            symbol == "==" || symbol == "!="
        {
            guard let equal = valuesEqual(left, right) else { return .unsupported }
            return .value(ConstExprValue(symbol == "==" ? equal : !equal))
        }

        if (symbol == "==" || symbol == "!="),
            (left.payload.isStructural || right.payload.isStructural)
        {
            guard let typeName = left.explicitTypeName,
                typeName == right.explicitTypeName
            else { return .unsupported }
            guard let equal = valuesEqual(left, right) else { return .unsupported }
            return .value(ConstExprValue(symbol == "==" ? equal : !equal))
        }

        if symbol == "<<" || symbol == ">>" {
            if let result = fixedWidthShift(symbol, left, right, as: Int.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: Int8.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: Int16.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: Int32.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: Int64.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: UInt.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: UInt8.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: UInt16.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: UInt32.self) { return result }
            if let result = fixedWidthShift(symbol, left, right, as: UInt64.self) { return result }
        }

        if left.staticType == Int.self, right.staticType == Int.self,
            let lhs = try? left.require(Int.self),
            let rhs = try? right.require(Int.self)
        {
            return integer(symbol, lhs, rhs)
        }

        if let result = fixedWidthInteger(symbol, left, right, as: Int8.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: Int16.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: Int32.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: Int64.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: UInt.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: UInt8.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: UInt16.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: UInt32.self) { return result }
        if let result = fixedWidthInteger(symbol, left, right, as: UInt64.self) { return result }

        if left.staticType == Double.self, right.staticType == Double.self,
            let lhs = try? left.require(Double.self),
            let rhs = try? right.require(Double.self)
        {
            return floating(symbol, lhs, rhs)
        }

        if left.staticType == Float.self, right.staticType == Float.self,
            let lhs = try? left.require(Float.self),
            let rhs = try? right.require(Float.self)
        {
            return floating(symbol, lhs, rhs)
        }

        if left.staticType == Bool.self, right.staticType == Bool.self,
            let lhs = try? left.require(Bool.self),
            let rhs = try? right.require(Bool.self)
        {
            switch symbol {
            case "&&": return .value(ConstExprValue(lhs && rhs))
            case "||": return .value(ConstExprValue(lhs || rhs))
            case "==": return .value(ConstExprValue(lhs == rhs))
            case "!=": return .value(ConstExprValue(lhs != rhs))
            default: return .unsupported
            }
        }

        if left.staticType == String.self, right.staticType == String.self,
            let lhs = try? left.require(String.self),
            let rhs = try? right.require(String.self)
        {
            switch symbol {
            case "+": return .value(ConstExprValue(lhs + rhs))
            case "==": return .value(ConstExprValue(lhs == rhs))
            case "!=": return .value(ConstExprValue(lhs != rhs))
            case "<": return .value(ConstExprValue(lhs < rhs))
            case "<=": return .value(ConstExprValue(lhs <= rhs))
            case ">": return .value(ConstExprValue(lhs > rhs))
            case ">=": return .value(ConstExprValue(lhs >= rhs))
            default: return .unsupported
            }
        }

        if left.staticType == Character.self, right.staticType == Character.self,
            let lhs = try? left.require(Character.self),
            let rhs = try? right.require(Character.self)
        {
            switch symbol {
            case "==": return .value(ConstExprValue(lhs == rhs))
            case "!=": return .value(ConstExprValue(lhs != rhs))
            case "<": return .value(ConstExprValue(lhs < rhs))
            case "<=": return .value(ConstExprValue(lhs <= rhs))
            case ">": return .value(ConstExprValue(lhs > rhs))
            case ">=": return .value(ConstExprValue(lhs >= rhs))
            default: return .unsupported
            }
        }

        return .unsupported
    }

}
