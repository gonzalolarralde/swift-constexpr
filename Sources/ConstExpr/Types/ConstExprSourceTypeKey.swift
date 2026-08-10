import Foundation

/// A canonical, structural spelling for the subset of Swift types that the
/// runtime can recover without asking the compiler for semantic information.
///
/// This is intentionally an implementation detail. Public registrations keep
/// their authoritative metatypes and descriptors; the key only prevents hot
/// lookup paths from repeatedly reflecting and reparsing those types.
indirect enum ConstExprSourceTypeKey: Hashable, Sendable {
    struct TupleElement: Hashable, Sendable {
        let label: String?
        let type: ConstExprSourceTypeKey
    }

    case leaf(String)
    case optional(Self)
    case array(Self)
    case dictionary(key: Self, value: Self)
    case set(Self)
    case tuple([TupleElement])

    init?(sourceName: String) {
        guard let parsed = Self.parse(sourceName) else { return nil }
        self = parsed
    }

    /// Keys accepted for source lookup. Swift source commonly omits a module
    /// qualification that is present in `String(reflecting:)`; retaining both
    /// forms preserves ambiguity when two registered modules define the same
    /// basename instead of choosing one arbitrarily.
    var lookupAliases: Set<Self> {
        var result: Set<Self> = [self]
        result.insert(droppingLeafConstructorModules())
        result.insert(droppingLeafModules())
        return result
    }

    var sourceName: String {
        switch self {
        case .leaf(let name):
            return name
        case .optional(let wrapped):
            return "\(wrapped.sourceName)?"
        case .array(let element):
            return "[\(element.sourceName)]"
        case .dictionary(let key, let value):
            return "[\(key.sourceName): \(value.sourceName)]"
        case .set(let element):
            return "Set<\(element.sourceName)>"
        case .tuple(let elements):
            return "(" + elements.map {
                if let label = $0.label { return "\(label): \($0.type.sourceName)" }
                return $0.type.sourceName
            }.joined(separator: ", ") + ")"
        }
    }

    private func droppingLeafModules() -> Self {
        switch self {
        case .leaf(let name):
            return .leaf(Self.unqualifiedLeaf(name))
        case .optional(let wrapped):
            return .optional(wrapped.droppingLeafModules())
        case .array(let element):
            return .array(element.droppingLeafModules())
        case .dictionary(let key, let value):
            return .dictionary(
                key: key.droppingLeafModules(),
                value: value.droppingLeafModules()
            )
        case .set(let element):
            return .set(element.droppingLeafModules())
        case .tuple(let elements):
            return .tuple(elements.map {
                TupleElement(label: $0.label, type: $0.type.droppingLeafModules())
            })
        }
    }

    /// Removes the module from a nominal generic constructor while retaining
    /// qualification on its arguments. Reflected types such as
    /// `Swift.Range<MyModule.Version>` are commonly fed back into the
    /// evaluator as `Range<MyModule.Version>`; indexing this intermediate
    /// spelling avoids treating it as an unrelated or ambiguous unqualified
    /// `Range<Version>`.
    private func droppingLeafConstructorModules() -> Self {
        switch self {
        case .leaf(let name):
            if name.hasSuffix(".Type") {
                let base = name.dropLast(".Type".count)
                guard let separator = base.firstIndex(of: ".") else {
                    return self
                }
                return .leaf(String(base[base.index(after: separator)...]) + ".Type")
            }
            guard let opening = name.firstIndex(of: "<"), name.hasSuffix(">") else {
                return self
            }
            let constructor = String(name[..<opening])
            let unqualifiedConstructor = constructor.split(separator: ".")
                .last.map(String.init) ?? constructor
            return .leaf(unqualifiedConstructor + String(name[opening...]))
        case .optional(let wrapped):
            return .optional(wrapped.droppingLeafConstructorModules())
        case .array(let element):
            return .array(element.droppingLeafConstructorModules())
        case .dictionary(let key, let value):
            return .dictionary(
                key: key.droppingLeafConstructorModules(),
                value: value.droppingLeafConstructorModules()
            )
        case .set(let element):
            return .set(element.droppingLeafConstructorModules())
        case .tuple(let elements):
            return .tuple(elements.map {
                TupleElement(
                    label: $0.label,
                    type: $0.type.droppingLeafConstructorModules()
                )
            })
        }
    }

    private static func parse(_ source: String) -> Self? {
        var source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        if source.hasPrefix("any ") { source.removeFirst(4) }
        if source.hasPrefix("some ") { source.removeFirst(5) }
        source = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if source.hasSuffix("?") {
            source.removeLast()
            var wrapped = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSingleOuterParenthesizedType(wrapped) {
                wrapped.removeFirst()
                wrapped.removeLast()
            }
            return parse(wrapped).map(Self.optional)
        }

        if let arguments = genericArguments(in: source, constructors: ["Optional", "Swift.Optional"]),
           arguments.count == 1
        {
            return parse(arguments[0]).map(Self.optional)
        }
        if let arguments = genericArguments(in: source, constructors: ["Array", "Swift.Array"]),
           arguments.count == 1
        {
            return parse(arguments[0]).map(Self.array)
        }
        if let arguments = genericArguments(
            in: source,
            constructors: ["Dictionary", "Swift.Dictionary"]
        ), arguments.count == 2, let key = parse(arguments[0]), let value = parse(arguments[1]) {
            return .dictionary(key: key, value: value)
        }
        if let arguments = genericArguments(in: source, constructors: ["Set", "Swift.Set"]),
           arguments.count == 1
        {
            return parse(arguments[0]).map(Self.set)
        }

        if source.hasPrefix("["), source.hasSuffix("]") {
            let body = String(source.dropFirst().dropLast())
            if let colon = topLevelDelimiter(":", in: body) {
                let keyText = String(body[..<colon])
                let valueText = String(body[body.index(after: colon)...])
                guard let key = parse(keyText), let value = parse(valueText) else { return nil }
                return .dictionary(key: key, value: value)
            }
            return parse(body).map(Self.array)
        }

        if source.hasPrefix("("), source.hasSuffix(")") {
            let body = String(source.dropFirst().dropLast())
            let pieces = topLevelComponents(in: body)
            if pieces.count >= 2 {
                var elements: [TupleElement] = []
                for piece in pieces {
                    if let colon = topLevelDelimiter(":", in: piece) {
                        let label = String(piece[..<colon])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let typeText = String(piece[piece.index(after: colon)...])
                        guard isIdentifier(label), let type = parse(typeText) else { return nil }
                        elements.append(TupleElement(label: label, type: type))
                    } else {
                        guard let type = parse(piece) else { return nil }
                        elements.append(TupleElement(label: nil, type: type))
                    }
                }
                return .tuple(elements)
            }
            if isSingleOuterParenthesizedType(source) {
                return parse(body)
            }
        }

        let compact = normalizedLeaf(source)
        guard !compact.isEmpty else { return nil }
        return .leaf(compact)
    }

    private static func normalizedLeaf(_ source: String) -> String {
        let composition = topLevelComponents(in: source, separatedBy: "&")
        if composition.count > 1 {
            return composition.map(normalizedLeaf).joined(separator: " & ")
        }

        // Whitespace is not otherwise semantically significant in a type
        // spelling. Canonicalize nested protocol compositions too, including
        // those inside nominal generic arguments that remain leaf keys.
        let joined = source
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "&", with: " & ")
        if joined.hasPrefix("Swift.") {
            let candidate = String(joined.dropFirst("Swift.".count))
            if swiftLeafNames.contains(candidate) { return candidate }
        }
        return joined
    }

    private static func unqualifiedLeaf(_ name: String) -> String {
        let composition = topLevelComponents(in: name, separatedBy: "&")
        if composition.count > 1 {
            return composition.map(unqualifiedLeaf).joined(separator: " & ")
        }
        if name.hasSuffix(".Type") {
            let base = name.dropLast(".Type".count)
            return (base.split(separator: ".").last.map(String.init) ?? String(base))
                + ".Type"
        }
        if let opening = name.firstIndex(of: "<"), name.hasSuffix(">") {
            let constructor = String(name[..<opening])
            let argumentStart = name.index(after: opening)
            let argumentEnd = name.index(before: name.endIndex)
            let arguments = topLevelComponents(
                in: String(name[argumentStart..<argumentEnd])
            ).map { argument in
                parse(argument)?.droppingLeafModules().sourceName
                    ?? unqualifiedLeaf(argument)
            }
            let unqualifiedConstructor = constructor.split(separator: ".")
                .last.map(String.init) ?? constructor
            return "\(unqualifiedConstructor)<\(arguments.joined(separator: ","))>"
        }
        return name.split(separator: ".").last.map(String.init) ?? name
    }

    private static func genericArguments(
        in source: String,
        constructors: [String]
    ) -> [String]? {
        guard let constructor = constructors.first(where: {
            source.hasPrefix($0 + "<") && source.hasSuffix(">")
        }) else { return nil }
        let start = source.index(source.startIndex, offsetBy: constructor.count + 1)
        let end = source.index(before: source.endIndex)
        return topLevelComponents(in: String(source[start..<end]))
    }

    private static func topLevelComponents(
        in source: String,
        separatedBy separator: Character = ","
    ) -> [String] {
        var depth = 0
        var start = source.startIndex
        var result: [String] = []
        for index in source.indices {
            switch source[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case separator where depth == 0:
                result.append(String(source[start..<index]))
                start = source.index(after: index)
            default: break
            }
        }
        result.append(String(source[start...]))
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func topLevelDelimiter(
        _ delimiter: Character,
        in source: String
    ) -> String.Index? {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case delimiter where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    private static func isSingleOuterParenthesizedType(_ source: String) -> Bool {
        guard source.hasPrefix("("), source.hasSuffix(")") else { return false }
        let body = String(source.dropFirst().dropLast())
        return topLevelComponents(in: body).count == 1
    }

    private static func isIdentifier(_ source: String) -> Bool {
        guard let first = source.first, first == "_" || first.isLetter else { return false }
        return source.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static let swiftLeafNames: Set<String> = [
        "Any", "AnyHashable", "AnyObject", "Bool", "Character", "Double", "Float",
        "Int", "Int8", "Int16", "Int32", "Int64", "Never", "String", "Substring",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Unicode.Scalar", "Void",
    ]
}
