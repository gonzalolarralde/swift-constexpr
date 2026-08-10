public extension _ConstExprRuntime {
    /// Normalizes generated peers into a typed registry fragment. Package-only
    /// peers erase their result to `[Any]` so a module can use `internal import
    /// ConstExpr` without exposing ConstExpr types in its interface.
    static func registrations(
        fromGeneratedPeer registrations: [Registration]
    ) -> [Registration] {
        registrations
    }

    static func registrations(
        fromGeneratedPeer registrations: [Any]
    ) -> [Registration] {
        registrations.compactMap { $0 as? Registration }
    }
}
