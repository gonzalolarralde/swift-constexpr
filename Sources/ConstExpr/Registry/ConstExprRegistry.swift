import Foundation

private final class ConstExprRegistryStorage: @unchecked Sendable {
    let registrations: [ConstExprRegistration]

    private let lock = NSLock()
    private var cachedIndex: ConstExprRegistryIndex?

    init(registrations: [ConstExprRegistration]) {
        self.registrations = registrations
    }

    var index: ConstExprRegistryIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIndex { return cachedIndex }
        let index = ConstExprRegistryIndex(registrations: registrations)
        cachedIndex = index
        return index
    }
}

public struct ConstExprRegistry: Sendable {
    private let storage: ConstExprRegistryStorage

    public var registrations: [ConstExprRegistration] { storage.registrations }
    var index: ConstExprRegistryIndex { storage.index }

    public init(registrations: [ConstExprRegistration] = []) {
        self.storage = ConstExprRegistryStorage(registrations: registrations)
    }

    /// Convenience initialization for one or more registrations without an
    /// intermediate array. `ConstExprRegistry()` remains available through the
    /// defaulted array initializer.
    public init(
        _ registration: ConstExprRegistration,
        _ additionalRegistrations: ConstExprRegistration...
    ) {
        self.init(registrations: [registration] + additionalRegistrations)
    }

    public static var empty: Self { Self() }

    public func appending(_ registration: ConstExprRegistration) -> Self {
        Self(registrations: registrations + [registration])
    }

    public func appending(contentsOf registrations: [ConstExprRegistration]) -> Self {
        Self(registrations: self.registrations + registrations)
    }

    public func appending(contentsOf registry: Self) -> Self {
        appending(contentsOf: registry.registrations)
    }

    public func candidates(
        named name: String,
        kind: ConstExprRegistrationKind? = nil,
        ownerType: Any.Type? = nil,
        ownerName: String? = nil
    ) -> [ConstExprRegistration] {
        index.candidates(
            named: name,
            kind: kind,
            ownerType: ownerType,
            ownerName: ownerName
        )
    }

    public var validationDiagnostics: [ConstExprDiagnostic] {
        index.validationDiagnostics
    }

    public var isValid: Bool {
        !validationDiagnostics.contains { $0.severity == .error }
    }
}
