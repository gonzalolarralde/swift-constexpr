import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ConstExprMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
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
                                let __constExprMacro_2hs6acgjvp5gv: String
                                if __constExprMacro_3hdcnlrqcrt90.indices.contains(0), let __constExprMacro_3gh81d027xfl4 = __constExprMacro_3hdcnlrqcrt90[0] {
                                    __constExprMacro_2hs6acgjvp5gv = try __constExprMacro_3gh81d027xfl4.require((String).self)
                                } else {
                                    __constExprMacro_2hs6acgjvp5gv = ("Bar")
                                }
                                return _ConstExprRuntime.Value((try __constExprMacro_c3kff39ylv3m.build(prefix: __constExprMacro_2hs6acgjvp5gv)) as Any, preservingStaticType: (String).self, sourceTypeName: "String", isStaticallyAnyObject: _ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<String>.none))
                            }
                        )
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

}
