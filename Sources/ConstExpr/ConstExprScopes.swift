// Lexical state used by the source evaluator. This is intentionally small:
// only immutable, simple identifier bindings can carry a constant value.

struct ConstExprScopeStack {
    enum Binding {
        case constant(ConstExprValue)
        case unknown
    }

    private var scopes: [[String: Binding]] = [[:]]
    private var sourceTypes: [[String: String]] = [[:]]

    mutating func push() {
        scopes.append([:])
        sourceTypes.append([:])
    }

    mutating func pop() {
        precondition(scopes.count > 1, "cannot pop the root const-expression scope")
        scopes.removeLast()
        sourceTypes.removeLast()
    }

    mutating func declare(_ name: String, as binding: Binding = .unknown) {
        scopes[scopes.count - 1][name] = binding
    }

    mutating func assignConstant(_ value: ConstExprValue, to name: String) {
        scopes[scopes.count - 1][name] = .constant(value)
    }

    mutating func setSourceType(_ sourceType: String, for name: String) {
        sourceTypes[sourceTypes.count - 1][name] = sourceType
    }

    func sourceType(named name: String) -> String? {
        for scope in sourceTypes.reversed() {
            if let sourceType = scope[name] {
                return sourceType
            }
        }
        return nil
    }

    func binding(named name: String) -> Binding? {
        for scope in scopes.reversed() {
            if let binding = scope[name] {
                return binding
            }
        }
        return nil
    }

    func isShadowed(_ name: String) -> Bool {
        binding(named: name) != nil
    }
}
