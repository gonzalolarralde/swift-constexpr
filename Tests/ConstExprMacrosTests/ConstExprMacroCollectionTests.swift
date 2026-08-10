import ConstExprMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

extension ConstExprMacroTests {
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

}
