internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public struct PackageInterfaceFixture {
    public let value: Int

    public init(value: Int = 1) {
        self.value = value
    }
}

@ConstExprMembers(named: "Factories", registrationAccess: .package)
public extension PackageInterfaceFixture {
    static func doubled(_ value: Int) -> Int { value * 2 }
}

public enum PackageInterfaceNamespace {}

extension PackageInterfaceNamespace {
    @ConstExpr(registrationAccess: .package)
    public struct NestedVersion {
        public let value: Int

        public init(_ value: Int) {
            self.value = value
        }

        public func adding(_ amount: Int) -> Int {
            value + amount
        }

        @available(macOS 11, *)
        public static var introduced: Self { Self(10) }

        @available(macOS, introduced: 11, deprecated: 99)
        public static var legacy: Self { Self(20) }

        @available(*, unavailable, renamed: "introduced")
        public static var unavailableAlias: Self { Self(0) }
    }
}
