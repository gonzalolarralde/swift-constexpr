import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ConstExprMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "ConstExpr": ConstExprMacro.self,
        "constExprRegistry": ConstExprRegistryMacro.self,
    ]

    func testFreeFunctionPeer() {
        assertMacroExpansion(
            #"""
            @ConstExpr
            public func foo(_ value: Int) -> Int {
                value + 1
            }
            """#,
            expandedSource: #"""
            public func foo(_ value: Int) -> Int {
                value + 1
            }

            public func foo__constExpr(
                __constExprSelector_1_1__ __constExprMacro_1yr4tz5o8f7s4: @escaping (Int) -> Int
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "foo",
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: [nil],
                        parameterTypes: [(Int).self],
                        parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil)],
                        defaultedParameters: [],
                        resultType: (Int).self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil),
                        invoke: { _, __constExprMacro_2rc1xmc5oqovu in
                            guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                            }
                            let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require((Int).self)
                            return _ConstExprRuntime.Value(
                                (foo(__constExprMacro_92au563oqcr7) as Int) as Any,
                                preservingStaticType: (Int).self,
                                sourceTypeName: "Int",
                                isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none)
                            )
                        }
                    )
                ]
            }
            """#,
            macros: macros
        )
    }

    func testThrowingLabeledFunctionWithDefault() {
        assertMacroExpansion(
            """
            @ConstExpr
            func parse(text: String, radix: Int = 10) throws -> Int {
                0
            }
            """,
            expandedSource: """
            func parse(text: String, radix: Int = 10) throws -> Int {
                0
            }

            func parse__constExpr(
                __constExprSelector_2_4_text__5_radix __constExprMacro_1yr4tz5o8f7s4: @escaping (String, Int) throws -> Int
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "parse",
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: ["text", "radix"],
                        parameterTypes: [(String).self, (Int).self],
                        parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil), _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil)],
                        defaultedParameters: [1],
                        resultType: (Int).self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil),
                        isThrowing: true,
                        invoke: { _, __constExprMacro_2rc1xmc5oqovu in
                            guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                            }
                            let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require((String).self)
                            let __constExprMacro_35pmacguj45ew: Int
                            if __constExprMacro_2rc1xmc5oqovu.indices.contains(1), let __constExprMacro_3rvlm46fscoix = __constExprMacro_2rc1xmc5oqovu[1] {
                                __constExprMacro_35pmacguj45ew = try __constExprMacro_3rvlm46fscoix.require((Int).self)
                            } else {
                                __constExprMacro_35pmacguj45ew = (10)
                            }
                            return _ConstExprRuntime.Value(
                                (try parse(text: __constExprMacro_92au563oqcr7, radix: __constExprMacro_35pmacguj45ew) as Int) as Any,
                                preservingStaticType: (Int).self,
                                sourceTypeName: "Int",
                                isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none)
                            )
                        }
                    )
                ]
            }
            """,
            macros: macros
        )
    }

    func testGlobalConstantPeer() {
        assertMacroExpansion(
            """
            @ConstExpr
            package let answer = 42
            """,
            expandedSource: """
            package let answer = 42

            package func answer__constExpr<__constExprMacro_328t7xglufb97>(
                __constExprSelector_0 __constExprMacro_2ar4ww8oba5r: @autoclosure @escaping () -> __constExprMacro_328t7xglufb97
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "answer",
                        kind: .constant,
                        ownerType: nil,
                        parameterLabels: [],
                        parameterTypes: [],
                        parameterTypeDescriptors: [],
                        defaultedParameters: [],
                        resultType: __constExprMacro_328t7xglufb97.self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.inferred(__constExprMacro_328t7xglufb97.self),
                        invoke: { _, _ in
                            _ConstExprRuntime.Value(
                                (answer) as Any,
                                preservingStaticType: __constExprMacro_328t7xglufb97.self,
                                sourceTypeName: nil
                            )
                        }
                    )
                ]
            }
            """,
            macros: macros
        )
    }

    func testExistentialResultKeepsSourceTypeName() {
        assertMacroExpansion(
            """
            @ConstExpr
            func rendered() -> (any CustomStringConvertible)? {
                1
            }
            """,
            expandedSource: """
            func rendered() -> (any CustomStringConvertible)? {
                1
            }

            func rendered__constExpr(
                __constExprSelector_0 __constExprMacro_1yr4tz5o8f7s4: @escaping () -> (any CustomStringConvertible)?
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "rendered",
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: [],
                        parameterTypes: [],
                        parameterTypeDescriptors: [],
                        defaultedParameters: [],
                        resultType: ((any CustomStringConvertible)?).self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.optional(_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (any CustomStringConvertible).self, sourceName: "any CustomStringConvertible", isExistential: true, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<any CustomStringConvertible>.none), acceptsSourceType: {
                                    $0 is any (CustomStringConvertible).Type
                                })),
                        invoke: { _, __constExprMacro_2rc1xmc5oqovu in

                            return _ConstExprRuntime.Value(
                                (rendered() as (any CustomStringConvertible)?) as Any,
                                preservingStaticType: ((any CustomStringConvertible)?).self,
                                sourceTypeName: "(any CustomStringConvertible)?",
                                isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<(any CustomStringConvertible)?>.none)
                            )
                        }
                    )
                ]
            }
            """,
            macros: macros
        )
    }

    func testLabeledTupleParameterAndResultDescriptors() {
        assertMacroExpansion(
            """
            @ConstExpr
            func preserveTuple(
                _ value: (x: Int, y: String)
            ) -> (x: Int, y: String) {
                value
            }
            """,
            expandedSource: """
            func preserveTuple(
                _ value: (x: Int, y: String)
            ) -> (x: Int, y: String) {
                value
            }

            func preserveTuple__constExpr(
                __constExprSelector_1_1__ __constExprMacro_1yr4tz5o8f7s4: @escaping ((x: Int, y: String)) -> (x: Int, y: String)
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "preserveTuple",
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: [nil],
                        parameterTypes: [((x: Int, y: String)).self],
                        parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.tuple([_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil), _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil)])],
                        defaultedParameters: [],
                        resultType: ((x: Int, y: String)).self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.tuple([_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil), _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil)]),
                        invoke: { _, __constExprMacro_2rc1xmc5oqovu in
                            guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                            }
                            let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require(((x: Int, y: String)).self)
                            return _ConstExprRuntime.Value(
                                (preserveTuple(__constExprMacro_92au563oqcr7) as (x: Int, y: String)) as Any,
                                preservingStaticType: ((x: Int, y: String)).self,
                                sourceTypeName: "(x: Int, y: String)",
                                isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<(x: Int, y: String)>.none)
                            )
                        }
                    )
                ]
            }
            """,
            macros: macros
        )
    }

    func testNestedProtocolCompositionDescriptors() {
        assertMacroExpansion(
            """
            @ConstExpr
            func nestedComposition()
                -> [[String: (any P & Q)?]?]
            {
                []
            }
            """,
            expandedSource: """
            func nestedComposition()
                -> [[String: (any P & Q)?]?]
            {
                []
            }

            func nestedComposition__constExpr(
                __constExprSelector_0 __constExprMacro_1yr4tz5o8f7s4: @escaping () -> [[String: (any P & Q)?]?]
            ) -> [_ConstExprRuntime.Registration] {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: "nestedComposition",
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: [],
                        parameterTypes: [],
                        parameterTypeDescriptors: [],
                        defaultedParameters: [],
                        resultType: ([[String: (any P & Q)?]?]).self,
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.array(_ConstExprRuntime.StaticTypeDescriptor.optional(_ConstExprRuntime.StaticTypeDescriptor.dictionary(key: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil), value: _ConstExprRuntime.StaticTypeDescriptor.optional(_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (any P & Q).self, sourceName: "any P & Q", isExistential: true, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<any P & Q>.none), acceptsSourceType: {
                                                $0 is any (P & Q).Type
                                            }))))),
                        invoke: { _, __constExprMacro_2rc1xmc5oqovu in

                            return _ConstExprRuntime.Value(
                                (nestedComposition() as [[String: (any P & Q)?]?]) as Any,
                                preservingStaticType: ([[String: (any P & Q)?]?]).self,
                                sourceTypeName: "[[String: (any P & Q)?]?]",
                                isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<[[String: (any P & Q)?]?]>.none)
                            )
                        }
                    )
                ]
            }
            """,
            macros: macros
        )
    }

    func testStructProvider() {
        assertMacroExpansion(
            #"""
            @ConstExpr
            public struct Bar {
                let value: Int

                public init(_ value: Int) throws {
                    self.value = value
                }

                public func build(prefix: String = "Bar") throws -> String {
                    "\(prefix) \(value)"
                }
            }
            """#,
            expandedSource: #"""
            public struct Bar {
                let value: Int

                public init(_ value: Int) throws {
                    self.value = value
                }

                public func build(prefix: String = "Bar") throws -> String {
                    "\(prefix) \(value)"
                }
            }

            public enum Bar__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [
                        _ConstExprRuntime.Registration(
                            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                            name: "Bar",
                            kind: .initializer,
                            ownerType: (Bar).self,
                            parameterLabels: [nil],
                            parameterTypes: [(Int).self],
                            parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil)],
                            defaultedParameters: [],
                            resultType: (Bar).self,
                            resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Bar).self, sourceName: "Bar", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Bar>.none), acceptsSourceType: nil),
                            isThrowing: true,
                            invoke: { __constExprMacro_34rnyvxwncjzi, __constExprMacro_2rc1xmc5oqovu in
                                guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                    throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                                }
                                let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require((Int).self)
                                return _ConstExprRuntime.Value((try Bar(__constExprMacro_92au563oqcr7)) as Any, preservingStaticType: (Bar).self, sourceTypeName: "Bar", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Bar>.none))
                            }
                        ),
                        _ConstExprRuntime.Registration(
                            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                            name: "build",
                            kind: .instanceMethod,
                            ownerType: (Bar).self,
                            parameterLabels: ["prefix"],
                            parameterTypes: [(String).self],
                            parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil)],
                            defaultedParameters: [0],
                            resultType: (String).self,
                            resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil),
                            isThrowing: true,
                            invoke: { __constExprMacro_31papgl0ekbzk, __constExprMacro_3hdcnlrqcrt90 in
                                guard let __constExprMacro_31papgl0ekbzk else {
                                    throw _ConstExprRuntime.ValueError.malformedCollection("missing Bar receiver")
                                }
                                let __constExprMacro_c3kff39ylv3m = try __constExprMacro_31papgl0ekbzk.require((Bar).self)
                                var __constExprMacro_3dvb139dccz5i = 0
                                if __constExprMacro_3hdcnlrqcrt90.indices.contains(0), __constExprMacro_3hdcnlrqcrt90[0] != nil {
                                    __constExprMacro_3dvb139dccz5i |= 1
                                }
                                switch __constExprMacro_3dvb139dccz5i {
                                case 0:
                                    return _ConstExprRuntime.Value((try __constExprMacro_c3kff39ylv3m.build()) as Any, preservingStaticType: (String).self, sourceTypeName: "String", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none))
                                case 1:
                                    guard __constExprMacro_3hdcnlrqcrt90.indices.contains(0), let __constExprMacro_3gh81d027xfl4 = __constExprMacro_3hdcnlrqcrt90[0] else {
                                        throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                                    }
                                    let __constExprMacro_2hs6acgjvp5gv = try __constExprMacro_3gh81d027xfl4.require((String).self)
                                    return _ConstExprRuntime.Value((try __constExprMacro_c3kff39ylv3m.build(prefix: __constExprMacro_2hs6acgjvp5gv)) as Any, preservingStaticType: (String).self, sourceTypeName: "String", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none))
                                default:
                                    throw _ConstExprRuntime.ValueError.malformedCollection("invalid default argument mask")
                                }
                            }
                        )
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    func testArrayLiteralProviderUsesDedicatedRegistration() {
        assertMacroExpansion(
            """
            @ConstExpr
            public struct ItemBag: Swift.ExpressibleByArrayLiteral {
                public struct Item {}

                public init(arrayLiteral elements: Item...) {}
            }
            """,
            expandedSource: """
            public struct ItemBag: Swift.ExpressibleByArrayLiteral {
                public struct Item {}

                public init(arrayLiteral elements: Item...) {}
            }

            public enum ItemBag__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    _ConstExprRuntime.arrayLiteralRegistrations(
                        result: (ItemBag).self,
                        element: (ItemBag.Item).self,
                        elementTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (ItemBag.Item).self, sourceName: "ItemBag.Item", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<ItemBag.Item>.none), acceptsSourceType: nil),
                        resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (ItemBag).self, sourceName: "ItemBag", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<ItemBag>.none), acceptsSourceType: nil),
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!)
                    ) + [

                    ]
                }
            }
            """,
            macros: macros
        )
    }

    func testArrayLiteralConformanceRequiresVisibleUnambiguousWitness() {
        assertMacroExpansion(
            """
            @ConstExpr
            struct ExtensionConformance {}

            extension ExtensionConformance: ExpressibleByArrayLiteral {
                init(arrayLiteral elements: Int...) {}
            }
            """,
            expandedSource: """
            struct ExtensionConformance {}

            enum ExtensionConformance__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }

            extension ExtensionConformance: ExpressibleByArrayLiteral {
                init(arrayLiteral elements: Int...) {}
            }
            """,
            macros: macros
        )

        assertMacroExpansion(
            """
            @ConstExpr
            struct ExtensionWitness: ExpressibleByArrayLiteral {}

            extension ExtensionWitness {
                init(arrayLiteral elements: Int...) {}
            }
            """,
            expandedSource: """
            struct ExtensionWitness: ExpressibleByArrayLiteral {}

            enum ExtensionWitness__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }

            extension ExtensionWitness {
                init(arrayLiteral elements: Int...) {}
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "ExpressibleByArrayLiteral conformance was not registered because its init(arrayLiteral:) witness is not visible in the annotated primary declaration",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: macros
        )

        assertMacroExpansion(
            """
            @ConstExpr
            struct AmbiguousBag: ExpressibleByArrayLiteral {
                init(arrayLiteral elements: Int...) {}
                init(arrayLiteral elements: String...) {}
            }
            """,
            expandedSource: """
            struct AmbiguousBag: ExpressibleByArrayLiteral {
                init(arrayLiteral elements: Int...) {}
                init(arrayLiteral elements: String...) {}
            }

            enum AmbiguousBag__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "ExpressibleByArrayLiteral conformance was not registered because multiple eligible init(arrayLiteral:) witnesses are visible",
                    line: 1,
                    column: 1,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    func testInvalidArrayLiteralWitnessesAreNotRegistered() {
        assertFilteredArrayLiteralWitness(
            declaration: "init?(arrayLiteral elements: Int...) {}",
            message: "init(arrayLiteral:) was not registered because an array-literal witness must be a nonfailable, nonthrowing, nongeneric initializer with exactly one nondefaulted variadic parameter"
        )
        assertFilteredArrayLiteralWitness(
            declaration: "init(arrayLiteral elements: Int) {}",
            message: "init(arrayLiteral:) was not registered because an array-literal witness must be a nonfailable, nonthrowing, nongeneric initializer with exactly one nondefaulted variadic parameter"
        )
        assertFilteredArrayLiteralWitness(
            declaration: "private init(arrayLiteral elements: Int...) {}",
            message: "private init(arrayLiteral:) witness was not registered"
        )
        assertFilteredArrayLiteralWitness(
            declaration: "@MainActor init(arrayLiteral elements: Int...) {}",
            message: "array-literal initializer was not registered because @MainActor isolation cannot be called by a synchronous adapter"
        )
        assertFilteredArrayLiteralWitness(
            declaration: "init(arrayLiteral elements: (() -> Int)...) {}",
            message: "init(arrayLiteral:) was not registered: function-typed values are not supported by @ConstExpr"
        )
    }

    func testAssociatedValueEnumCaseProvider() {
        assertMacroExpansion(
            """
            @ConstExpr
            public enum Status {
                case code(Int)
            }
            """,
            expandedSource: """
            public enum Status {
                case code(Int)
            }

            public enum Status__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [
                        _ConstExprRuntime.Registration(
                            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                            name: "code",
                            kind: .staticMethod,
                            ownerType: (Status).self,
                            parameterLabels: [nil],
                            parameterTypes: [(Int).self],
                            parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil)],
                            defaultedParameters: [],
                            resultType: (Status).self,
                            resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Status).self, sourceName: "Status", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Status>.none), acceptsSourceType: nil),
                            invoke: { __constExprMacro_34rnyvxwncjzi, __constExprMacro_2rc1xmc5oqovu in
                                guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                    throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                                }
                                let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require((Int).self)
                                return _ConstExprRuntime.Value((Status.code(__constExprMacro_92au563oqcr7)) as Any, preservingStaticType: (Status).self, sourceTypeName: "Status", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Status>.none))
                            }
                        )
                    ]
                }
            }
            """,
            macros: macros
        )
    }

    func testReadOnlySubscriptProvider() {
        assertMacroExpansion(
            """
            @ConstExpr
            struct Lookup {
                subscript(index: Int) -> String {
                    String(index)
                }
            }
            """,
            expandedSource: """
            struct Lookup {
                subscript(index: Int) -> String {
                    String(index)
                }
            }

            enum Lookup__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [
                        _ConstExprRuntime.Registration(
                            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                            name: "subscript",
                            kind: .subscriptGetter,
                            ownerType: (Lookup).self,
                            parameterLabels: [nil],
                            parameterTypes: [(Int).self],
                            parameterTypeDescriptors: [_ConstExprRuntime.StaticTypeDescriptor.leaf(type: (Int).self, sourceName: "Int", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<Int>.none), acceptsSourceType: nil)],
                            defaultedParameters: [],
                            resultType: (String).self,
                            resultTypeDescriptor: _ConstExprRuntime.StaticTypeDescriptor.leaf(type: (String).self, sourceName: "String", isExistential: false, isClassBound: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none), acceptsSourceType: nil),
                            invoke: { __constExprMacro_34rnyvxwncjzi, __constExprMacro_2rc1xmc5oqovu in
                                guard let __constExprMacro_34rnyvxwncjzi else {
                                    throw _ConstExprRuntime.ValueError.malformedCollection("missing Lookup receiver")
                                }
                                let __constExprMacro_3hi7iidqfphac = try __constExprMacro_34rnyvxwncjzi.require((Lookup).self)
                                guard __constExprMacro_2rc1xmc5oqovu.indices.contains(0), let __constExprMacro_5jo0l9urtg2e = __constExprMacro_2rc1xmc5oqovu[0] else {
                                    throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index 0")
                                }
                                let __constExprMacro_92au563oqcr7 = try __constExprMacro_5jo0l9urtg2e.require((Int).self)
                                return _ConstExprRuntime.Value((__constExprMacro_3hi7iidqfphac[__constExprMacro_92au563oqcr7]) as Any, preservingStaticType: (String).self, sourceTypeName: "String", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none))
                            }
                        )
                    ]
                }
            }
            """,
            macros: macros
        )
    }

    func testPrivateStoredStateIsSilentlyIgnored() {
        assertMacroExpansion(
            """
            @ConstExpr
            struct State {
                private let raw: Int
            }
            """,
            expandedSource: """
            struct State {
                private let raw: Int
            }

            enum State__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )
    }

    func testUnsupportedAsyncFunctionDiagnostic() {
        assertMacroExpansion(
            """
            @ConstExpr
            func load() async -> String { "value" }
            """,
            expandedSource: """
            func load() async -> String { "value" }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "async declarations are not supported by @ConstExpr",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testUnsupportedFunctionShapes() {
        assertRejected(
            "@ConstExpr\nfunc identity<T>(_ value: T) -> T { value }",
            expanded: "func identity<T>(_ value: T) -> T { value }",
            message: "generic declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc update(_ value: inout Int) -> Int { value }",
            expanded: "func update(_ value: inout Int) -> Int { value }",
            message: "inout parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc apply(_ body: (Int) -> Int) -> Int { body(1) }",
            expanded: "func apply(_ body: (Int) -> Int) -> Int { body(1) }",
            message: "function-typed parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc lazy(_ value: @autoclosure () -> Int) -> Int { value() }",
            expanded: "func lazy(_ value: @autoclosure () -> Int) -> Int { value() }",
            message: "@autoclosure parameters are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc perform(_ body: () throws -> Int) rethrows -> Int { try body() }",
            expanded: "func perform(_ body: () throws -> Int) rethrows -> Int { try body() }",
            message: "rethrows declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc log(line: Int = #line) -> Int { line }",
            expanded: "func log(line: Int = #line) -> Int { line }",
            message: "caller-location default arguments are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc notify() {}",
            expanded: "func notify() {}",
            message: "@ConstExpr callables must return a value"
        )
        assertRejected(
            "@ConstExpr\nfunc forced(_ value: Int!) -> Int { value }",
            expanded: "func forced(_ value: Int!) -> Int { value }",
            message: "implicitly unwrapped optional parameter types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc borrow(_ value: borrowing String) -> String { value }",
            expanded: "func borrow(_ value: borrowing String) -> String { value }",
            message: "'borrowing' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc consume(_ value: consuming String) -> String { value }",
            expanded: "func consume(_ value: consuming String) -> String { value }",
            message: "'consuming' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc isolatedValue(_ value: isolated Worker) -> Int { 1 }",
            expanded: "func isolatedValue(_ value: isolated Worker) -> Int { 1 }",
            message: "'isolated' parameter specifiers are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc opaque() -> some Equatable { 1 }",
            expanded: "func opaque() -> some Equatable { 1 }",
            message: "function and opaque result types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc opaqueInput(_ value: some Equatable) -> String { \"value\" }",
            expanded: "func opaqueInput(_ value: some Equatable) -> String { \"value\" }",
            message: "opaque parameter types are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc count(_ value: any Collection<Int>) -> Int { value.count }",
            expanded: "func count(_ value: any Collection<Int>) -> Int { value.count }",
            message: "parameterized existential parameter types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nfunc values() -> any Collection<Int> { [1, 2] }",
            expanded: "func values() -> any Collection<Int> { [1, 2] }",
            message: "parameterized existential result types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nlet values: any Collection<Int> = [1, 2]",
            expanded: "let values: any Collection<Int> = [1, 2]",
            message: "global constant 'values' was not registered: parameterized existential value types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
        )
        assertRejected(
            "@ConstExpr\nfunc typedThrow() throws(Failure) -> Int { 1 }",
            expanded: "func typedThrow() throws(Failure) -> Int { 1 }",
            message: "typed throws declarations are not supported by @ConstExpr"
        )
        assertRejected(
            "@ConstExpr\nfunc variadic(_ values: Int...) -> Int { values.count }",
            expanded: "func variadic(_ values: Int...) -> Int { values.count }",
            message: "variadic parameters are not supported by @ConstExpr"
        )
    }

    func testGlobalActorAndUnsupportedLexicalContexts() {
        assertMacroExpansion(
            """
            @MainActor
            @ConstExpr
            func isolatedGlobal() -> Int { 1 }
            """,
            expandedSource: """
            @MainActor
            func isolatedGlobal() -> Int { 1 }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "global-actor-isolated declarations such as @MainActor are not supported by synchronous @ConstExpr adapters",
                    line: 2,
                    column: 1
                )
            ],
            macros: macros
        )

        assertMacroExpansion(
            """
            @globalActor actor Isolation {
                static let shared = Isolation()
            }
            @Isolation
            @ConstExpr
            func customIsolatedGlobal() -> Int { 1 }
            """,
            expandedSource: """
            @globalActor actor Isolation {
                static let shared = Isolation()
            }
            @Isolation
            func customIsolatedGlobal() -> Int { 1 }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "declaration attribute @Isolation may impose isolation or semantic transforms that @ConstExpr cannot prove safe; use manual registration",
                    line: 5,
                    column: 1
                )
            ],
            macros: macros
        )

        assertContextRejected(
            """
            struct Host {
                @ConstExpr
                func value() -> Int { 1 }
            }
            """,
            expanded: """
            struct Host {
                func value() -> Int { 1 }
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead"
        )
        assertContextRejected(
            """
            struct Host {}
            extension Host {
                @ConstExpr
                func value() -> Int { 1 }
            }
            """,
            expanded: """
            struct Host {}
            extension Host {
                func value() -> Int { 1 }
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead",
            line: 3
        )
        assertContextRejected(
            """
            protocol Host {
                @ConstExpr
                func value() -> Int
            }
            """,
            expanded: """
            protocol Host {
                func value() -> Int
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead"
        )
        assertContextRejected(
            """
            actor Host {
                @ConstExpr
                func value() -> Int { 1 }
            }
            """,
            expanded: """
            actor Host {
                func value() -> Int { 1 }
            }
            """,
            message: "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead"
        )
        assertContextRejected(
            """
            func outer() {
                @ConstExpr
                struct Local {}
            }
            """,
            expanded: """
            func outer() {
                struct Local {}
            }
            """,
            message: "@ConstExpr nominal types cannot be local declarations"
        )
        assertContextRejected(
            """
            actor Container {
                @ConstExpr
                struct Nested {}
            }
            """,
            expanded: """
            actor Container {
                struct Nested {}
            }
            """,
            message: "@ConstExpr nominal types are not supported in extensions, protocols, or actors"
        )
        assertContextRejected(
            """
            struct Container {}
            extension Container {
                @ConstExpr
                struct Nested {}
            }
            """,
            expanded: """
            struct Container {}
            extension Container {
                struct Nested {}
            }
            """,
            message: "@ConstExpr nominal types are not supported in extensions, protocols, or actors",
            line: 3
        )
    }

    func testUnsafeMembersAreFiltered() {
        assertFilteredMember(
            declaration: "lazy var value = 1",
            message: "lazy property was not registered because reading it may mutate the receiver"
        )
        assertFilteredMember(
            declaration: "var value: Int { mutating get { 1 } }",
            message: "mutating or consuming property getter was not registered",
            column: 9
        )
        assertFilteredMember(
            declaration: "@available(macOS 99, *)\n    func value() -> Int { 1 }",
            message: "method 'value' was not registered because member-level availability cannot be represented safely in the generated registration array"
        )
        assertFilteredMember(
            declaration: "@MainActor\n    func value() -> Int { 1 }",
            message: "method 'value' was not registered because @MainActor isolation cannot be called by a synchronous adapter"
        )
        assertFilteredMember(
            declaration: "static subscript(index: Int) -> Int { index }",
            message: "static subscripts are not supported by @ConstExpr"
        )
        assertFilteredMember(
            declaration: "subscript(index: Int) -> Int { get throws { index } }",
            message: "async or throwing subscript accessor was not registered"
        )
        assertFilteredMember(
            declaration: "@Isolation\n    func value() -> Int { 1 }",
            message: "method 'value' was not registered because @Isolation may impose isolation or semantic transforms that a generated adapter cannot prove safe; use manual registration"
        )
        assertFilteredMember(
            declaration: "var values: any Collection<Int> { [1, 2] }",
            message: "property 'values' was not registered: parameterized existential value types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target",
            column: 9
        )

        assertMacroExpansion(
            """
            @ConstExpr
            public struct PublicAPI {
                func hidden() -> Int { 1 }
            }
            """,
            expandedSource: """
            public struct PublicAPI {
                func hidden() -> Int { 1 }
            }

            public enum PublicAPI__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )

        assertMacroExpansion(
            """
            @ConstExpr
            public struct SPIProvider {
                @_spi(Secret)
                public func secret() -> Int { 1 }
            }
            """,
            expandedSource: """
            public struct SPIProvider {
                @_spi(Secret)
                public func secret() -> Int { 1 }
            }

            public enum SPIProvider__constExpr {
                public static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )

        assertFilteredClassMember(
            declaration: "func value() -> Int { 1 }",
            message: "overridable instance method 'value' was not registered; mark the class or member final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "var value: Int { 1 }",
            message: "overridable instance property was not registered; mark the class or property final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "subscript(index: Int) -> Int { index }",
            message: "overridable instance subscript was not registered; mark the class or subscript final to prevent dispatch to an unregistered override"
        )
        assertFilteredClassMember(
            declaration: "dynamic func value() -> Int { 1 }",
            message: "dynamic method 'value' was not registered because runtime replacement or dispatch can invoke an unregistered implementation",
            isFinalClass: true
        )
        assertFilteredClassMember(
            declaration: "dynamic static func value() -> Int { 1 }",
            message: "dynamic method 'value' was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
        assertFilteredClassMember(
            declaration: "dynamic var value: Int { 1 }",
            message: "dynamic property was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
        assertFilteredClassMember(
            declaration: "dynamic subscript(index: Int) -> Int { index }",
            message: "dynamic subscript was not registered because runtime replacement or dispatch can invoke an unregistered implementation"
        )
    }

    func testGenericNominalTypeDiagnostic() {
        assertMacroExpansion(
            """
            @ConstExpr
            struct Box<Value> {
                let value: Value
            }
            """,
            expandedSource: """
            struct Box<Value> {
                let value: Value
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "generic nominal types are not supported by @ConstExpr",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testMutableAndMultipleGlobalDiagnostics() {
        assertMacroExpansion(
            """
            @ConstExpr
            var mutable = 1
            @ConstExpr
            let first = 1, second = 2
            """,
            expandedSource: """
            var mutable = 1
            let first = 1, second = 2
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ConstExpr can only register immutable global let bindings",
                    line: 1,
                    column: 1
                ),
                DiagnosticSpec(
                    message: "peer macro can only be applied to a single variable",
                    line: 3,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    private func assertRejected(_ source: String, expanded: String, message: String) {
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
            macros: macros
        )
    }

    private func assertContextRejected(
        _ source: String,
        expanded: String,
        message: String,
        line: Int = 2
    ) {
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [DiagnosticSpec(message: message, line: line, column: 5)],
            macros: macros
        )
    }

    private func assertFilteredMember(
        declaration: String,
        message: String,
        column: Int = 5
    ) {
        let source = """
        @ConstExpr
        struct Filtered {
            \(declaration)
        }
        """
        let expanded = """
        struct Filtered {
            \(declaration)
        }

        enum Filtered__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [
                DiagnosticSpec(
                    message: message,
                    line: 3,
                    column: column,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    private func assertFilteredClassMember(
        declaration: String,
        message: String,
        isFinalClass: Bool = false
    ) {
        let classModifier = isFinalClass ? "final " : ""
        let source = """
        @ConstExpr
        \(classModifier)class FilteredClass {
            \(declaration)
        }
        """
        let expanded = """
        \(classModifier)class FilteredClass {
            \(declaration)
        }

        enum FilteredClass__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [
                DiagnosticSpec(
                    message: message,
                    line: 3,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    private func assertFilteredArrayLiteralWitness(
        declaration: String,
        message: String
    ) {
        let source = """
        @ConstExpr
        struct FilteredBag: ExpressibleByArrayLiteral {
            \(declaration)
        }
        """
        let expanded = """
        struct FilteredBag: ExpressibleByArrayLiteral {
            \(declaration)
        }

        enum FilteredBag__constExpr {
            static var registrations: [_ConstExprRuntime.Registration] {
                [

                ]
            }
        }
        """
        assertMacroExpansion(
            source,
            expandedSource: expanded,
            diagnostics: [
                DiagnosticSpec(
                    message: message,
                    line: 3,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }
}
