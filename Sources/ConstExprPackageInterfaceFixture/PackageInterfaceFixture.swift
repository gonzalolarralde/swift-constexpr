internal import ConstExpr

public struct PackageInterfaceFixture {
    public let value: Int

    @ConstExpr(registrationAccess: .package)
    public init(value: Int = 1) {
        self.value = value
    }
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
