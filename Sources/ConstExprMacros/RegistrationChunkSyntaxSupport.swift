enum ConstExprRegistrationChunkSyntax {
    /// Bounds generated array and concatenation expressions so large API
    /// surfaces do not create a single pathological type-checker expression.
    static let limit = 32

    static func groups<Element>(_ elements: [Element]) -> [[Element]] {
        stride(from: 0, to: elements.count, by: limit).map { start in
            Array(elements[start..<min(start + limit, elements.count)])
        }
    }

    /// Produces a stable, order-preserving concatenation tree in which every
    /// array literal has at most ``limit`` children.
    static func boundedConcatenation(_ arrays: [String]) -> String {
        guard let only = arrays.first else { return "[]" }
        guard arrays.count > 1 else { return only }
        if arrays.count <= limit {
            return "([\(arrays.joined(separator: ", "))]).flatMap { $0 }"
        }
        return boundedConcatenation(groups(arrays).map(boundedConcatenation))
    }

    static func nominalProviderMembers(
        registrations: [String],
        arrayLiteralRegistrations: String?,
        arrayType: String,
        registrationAccess: String
    ) -> String {
        let chunks = groups(registrations)
        let names = chunks.indices.map { "__constExprRegistrationChunk\($0)" }
        let declarations = zip(names, chunks).map { name, registrations in
            let entries = registrations.map {
                ConstExprSyntaxSupport.indent($0, by: 12)
            }.joined(separator: ",\n")
            return """
            private static var \(name): \(arrayType) {
                [
            \(entries)
                ]
            }
            """
        }.joined(separator: "\n\n")

        var arrays = names
        if let arrayLiteralRegistrations {
            arrays.insert(arrayLiteralRegistrations, at: 0)
        }
        let root = boundedConcatenation(arrays)
        return """
        \(declarations)

        \(registrationAccess)static var registrations: \(arrayType) {
            \(root)
        }
        """
    }
}
