import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

extension ConstExprSyntaxSupport {
    static func functionType(for callable: ConstExprCallableModel) -> String {
        let parameters = callable.parameters.map(\.type).joined(separator: ", ")
        let throwing = callable.isThrowing ? " throws" : ""
        return "(\(parameters))\(throwing) -> \(callable.resultType)"
    }

    static func requiredDecodeStatements(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> [String] {
        parameters.enumerated().compactMap { index, parameter in
            if let indices, !indices.contains(index) { return nil }
            return """
            guard \(names.arguments).indices.contains(\(index)), let \(names.values[index]) = \(names.arguments)[\(index)] else {
                throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index \(index)")
            }
            let \(names.decodedArguments[index]) = try \(names.values[index]).require((\(parameter.type)).self)
            """
        }
    }

    static func copiedDefaultDecodeStatements(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames
    ) -> [String] {
        parameters.enumerated().map { index, parameter in
            if let defaultExpression = parameter.defaultExpression {
                return """
                let \(names.decodedArguments[index]): \(parameter.type)
                if \(names.arguments).indices.contains(\(index)), let \(names.values[index]) = \(names.arguments)[\(index)] {
                    \(names.decodedArguments[index]) = try \(names.values[index]).require((\(parameter.type)).self)
                } else {
                    \(names.decodedArguments[index]) = (\(defaultExpression))
                }
                """
            }
            return requiredDecodeStatements(
                for: parameters,
                names: names,
                including: [index]
            )[0]
        }
    }

    static func nativeDefaultInvocationBody(
        callable: ConstExprCallableModel,
        names: ConstExprAdapterNames,
        invocation: (_ includedParameters: Set<Int>) -> String
    ) -> String {
        let defaultIndices = callable.parameters.indices.filter {
            callable.parameters[$0].defaultExpression != nil
        }
        let requiredIndices = Set(callable.parameters.indices).subtracting(defaultIndices)
        var statements = requiredDecodeStatements(
            for: callable.parameters,
            names: names,
            including: requiredIndices
        )

        guard !defaultIndices.isEmpty else {
            statements.append(
                "return _ConstExprRuntime.Value((\(invocation(Set(callable.parameters.indices)))) as Any, preservingStaticType: \(metatypeSource(for: callable.resultType)), sourceTypeName: \(sourceTypeNameSource(for: callable.resultType)), isStaticallyAnyObject: \(staticallyAnyObjectSource(for: callable.resultType)))"
            )
            return statements.joined(separator: "\n")
        }

        statements.append("var \(names.defaultMask) = 0")
        for (bit, index) in defaultIndices.enumerated() {
            statements.append("""
            if \(names.arguments).indices.contains(\(index)), \(names.arguments)[\(index)] != nil {
                \(names.defaultMask) |= \(1 << bit)
            }
            """)
        }
        statements.append("switch \(names.defaultMask) {")

        for mask in 0..<(1 << defaultIndices.count) {
            var included = requiredIndices
            for (bit, index) in defaultIndices.enumerated() where mask & (1 << bit) != 0 {
                included.insert(index)
            }
            let decodeDefaults = requiredDecodeStatements(
                for: callable.parameters,
                names: names,
                including: included.intersection(defaultIndices)
            ).joined(separator: "\n")
            let body = [
                decodeDefaults,
                "return _ConstExprRuntime.Value((\(invocation(included))) as Any, preservingStaticType: \(metatypeSource(for: callable.resultType)), sourceTypeName: \(sourceTypeNameSource(for: callable.resultType)), isStaticallyAnyObject: \(staticallyAnyObjectSource(for: callable.resultType)))",
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            statements.append("case \(mask):\n\(indent(body, by: 4))")
        }
        statements.append("""
        default:
            throw _ConstExprRuntime.ValueError.malformedCollection("invalid default argument mask")
        }
        """)
        return statements.joined(separator: "\n")
    }

    static func memberDefaultInvocationBody(
        callable: ConstExprCallableModel,
        names: ConstExprAdapterNames,
        invocation: (_ includedParameters: Set<Int>) -> String
    ) -> String? {
        if callable.defaultsAreSelfContainedLiterals {
            var statements = copiedDefaultDecodeStatements(
                for: callable.parameters,
                names: names
            )
            let allParameters = Set(callable.parameters.indices)
            statements.append(
                "return _ConstExprRuntime.Value((\(invocation(allParameters))) as Any, preservingStaticType: \(metatypeSource(for: callable.resultType)), sourceTypeName: \(sourceTypeNameSource(for: callable.resultType)), isStaticallyAnyObject: \(staticallyAnyObjectSource(for: callable.resultType)))"
            )
            return statements.joined(separator: "\n")
        }
        guard !callable.requiresManualDefaultAdapter else { return nil }
        return nativeDefaultInvocationBody(
            callable: callable,
            names: names,
            invocation: invocation
        )
    }

    static func indent(_ source: String, by count: Int) -> String {
        let prefix = String(repeating: " ", count: count)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    static func callArguments(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> String {
        parameters.indices.compactMap { index in
            if let indices, !indices.contains(index) { return nil }
            return names.decodedArguments[index]
        }.joined(separator: ", ")
    }

    static func labeledCallArguments(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> String {
        parameters.indices.compactMap { index in
            if let indices, !indices.contains(index) { return nil }
            if let label = parameters[index].invocationLabel {
                return "\(label): \(names.decodedArguments[index])"
            }
            return names.decodedArguments[index]
        }.joined(separator: ", ")
    }

    static func labelsSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map { parameter in
            parameter.label.map(\.constExprStringLiteral) ?? "nil"
        }.joined(separator: ", ") + "]"
    }

    static func typesSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map { "(\($0.type)).self" }.joined(separator: ", ") + "]"
    }

    static func typeDescriptorsSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map(\.typeDescriptor).joined(separator: ", ") + "]"
    }

}
