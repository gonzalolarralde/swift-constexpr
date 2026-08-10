import ConstExpr

/// A small literal-expressible value from a library that has opted in to
/// ConstExpr. The initializer is deliberately in the primary declaration so
/// the attached macro can generate its adapter.
@ConstExpr
public struct Segment: ExpressibleByStringLiteral, Sendable {
    public let value: String

    public init(stringLiteral value: String) {
        self.value = value
    }
}

/// A user-owned `ExpressibleByArrayLiteral` value. Its generated literal
/// adapter receives the already-evaluated Segment elements, demonstrating the
/// custom-array-literal -> custom-string-literal chain in the consumer package.
@ConstExpr
public struct SegmentList: ExpressibleByArrayLiteral, Sendable {
    private let segments: [Segment]

    public init(arrayLiteral elements: Segment...) {
        segments = elements
    }

    public func route() -> Route {
        Route(segments)
    }
}

@ConstExpr
public struct Route: Sendable {
    private let segments: [Segment]

    public init(_ segments: [Segment]) {
        self.segments = segments
    }

    public func rendered() -> String {
        "/" + segments.map(\.value).joined(separator: "/")
    }
}

@ConstExpr
public struct Endpoint: Sendable {
    private let route: Route
    private let port: Int

    public init(route: Route, port: Int = 443) {
        self.route = route
        self.port = port
    }

    public func url(scheme: String = "https") -> String {
        "\(scheme)://example.test\(route.rendered()):\(port)"
    }
}

@ConstExpr
public func makePort(_ base: Int) -> Int {
    base + 3
}
