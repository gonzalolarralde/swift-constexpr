import ConstExpr
import Testing

@ConstExpr
private struct LargeProviderChunkFixture {
    static let providerValue00: Int = 0
    static let providerValue01: Int = 1
    static let providerValue02: Int = 2
    static let providerValue03: Int = 3
    static let providerValue04: Int = 4
    static let providerValue05: Int = 5
    static let providerValue06: Int = 6
    static let providerValue07: Int = 7
    static let providerValue08: Int = 8
    static let providerValue09: Int = 9
    static let providerValue10: Int = 10
    static let providerValue11: Int = 11
    static let providerValue12: Int = 12
    static let providerValue13: Int = 13
    static let providerValue14: Int = 14
    static let providerValue15: Int = 15
    static let providerValue16: Int = 16
    static let providerValue17: Int = 17
    static let providerValue18: Int = 18
    static let providerValue19: Int = 19
    static let providerValue20: Int = 20
    static let providerValue21: Int = 21
    static let providerValue22: Int = 22
    static let providerValue23: Int = 23
    static let providerValue24: Int = 24
    static let providerValue25: Int = 25
    static let providerValue26: Int = 26
    static let providerValue27: Int = 27
    static let providerValue28: Int = 28
    static let providerValue29: Int = 29
    static let providerValue30: Int = 30
    static let providerValue31: Int = 31
    static let providerValue32: Int = 32
    static let providerValue33: Int = 33
    static let providerValue34: Int = 34
    static let providerValue35: Int = 35
    static let providerValue36: Int = 36
    static let providerValue37: Int = 37
    static let providerValue38: Int = 38
    static let providerValue39: Int = 39
    static let providerValue40: Int = 40
    static let providerValue41: Int = 41
    static let providerValue42: Int = 42
    static let providerValue43: Int = 43
    static let providerValue44: Int = 44
    static let providerValue45: Int = 45
    static let providerValue46: Int = 46
    static let providerValue47: Int = 47
    static let providerValue48: Int = 48
    static let providerValue49: Int = 49
    static let providerValue50: Int = 50
    static let providerValue51: Int = 51
    static let providerValue52: Int = 52
    static let providerValue53: Int = 53
    static let providerValue54: Int = 54
    static let providerValue55: Int = 55
    static let providerValue56: Int = 56
    static let providerValue57: Int = 57
    static let providerValue58: Int = 58
    static let providerValue59: Int = 59
    static let providerValue60: Int = 60
    static let providerValue61: Int = 61
    static let providerValue62: Int = 62
    static let providerValue63: Int = 63
    static let providerValue64: Int = 64
}

private let largeProviderChunkRegistry = #constExprRegistry(
    LargeProviderChunkFixture.self
)

@ConstExpr private let registryValue00: Int = 0
@ConstExpr private let registryValue01: Int = 1
@ConstExpr private let registryValue02: Int = 2
@ConstExpr private let registryValue03: Int = 3
@ConstExpr private let registryValue04: Int = 4
@ConstExpr private let registryValue05: Int = 5
@ConstExpr private let registryValue06: Int = 6
@ConstExpr private let registryValue07: Int = 7
@ConstExpr private let registryValue08: Int = 8
@ConstExpr private let registryValue09: Int = 9
@ConstExpr private let registryValue10: Int = 10
@ConstExpr private let registryValue11: Int = 11
@ConstExpr private let registryValue12: Int = 12
@ConstExpr private let registryValue13: Int = 13
@ConstExpr private let registryValue14: Int = 14
@ConstExpr private let registryValue15: Int = 15
@ConstExpr private let registryValue16: Int = 16
@ConstExpr private let registryValue17: Int = 17
@ConstExpr private let registryValue18: Int = 18
@ConstExpr private let registryValue19: Int = 19
@ConstExpr private let registryValue20: Int = 20
@ConstExpr private let registryValue21: Int = 21
@ConstExpr private let registryValue22: Int = 22
@ConstExpr private let registryValue23: Int = 23
@ConstExpr private let registryValue24: Int = 24
@ConstExpr private let registryValue25: Int = 25
@ConstExpr private let registryValue26: Int = 26
@ConstExpr private let registryValue27: Int = 27
@ConstExpr private let registryValue28: Int = 28
@ConstExpr private let registryValue29: Int = 29
@ConstExpr private let registryValue30: Int = 30
@ConstExpr private let registryValue31: Int = 31
@ConstExpr private let registryValue32: Int = 32

private let largeFreestandingChunkRegistry = #constExprRegistry(
    registryValue00,
    registryValue01,
    registryValue02,
    registryValue03,
    registryValue04,
    registryValue05,
    registryValue06,
    registryValue07,
    registryValue08,
    registryValue09,
    registryValue10,
    registryValue11,
    registryValue12,
    registryValue13,
    registryValue14,
    registryValue15,
    registryValue16,
    registryValue17,
    registryValue18,
    registryValue19,
    registryValue20,
    registryValue21,
    registryValue22,
    registryValue23,
    registryValue24,
    registryValue25,
    registryValue26,
    registryValue27,
    registryValue28,
    registryValue29,
    registryValue30,
    registryValue31,
    registryValue32
)

@Test func generatedNominalProviderChunksPreserveRegistrationOrder() {
    #expect(largeProviderChunkRegistry.registrations.map(\.name) == [
        "providerValue00", "providerValue01", "providerValue02", "providerValue03", "providerValue04", "providerValue05", "providerValue06", "providerValue07", "providerValue08", "providerValue09", "providerValue10", "providerValue11", "providerValue12", "providerValue13", "providerValue14", "providerValue15", "providerValue16", "providerValue17", "providerValue18", "providerValue19", "providerValue20", "providerValue21", "providerValue22", "providerValue23", "providerValue24", "providerValue25", "providerValue26", "providerValue27", "providerValue28", "providerValue29", "providerValue30", "providerValue31", "providerValue32", "providerValue33", "providerValue34", "providerValue35", "providerValue36", "providerValue37", "providerValue38", "providerValue39", "providerValue40", "providerValue41", "providerValue42", "providerValue43", "providerValue44", "providerValue45", "providerValue46", "providerValue47", "providerValue48", "providerValue49", "providerValue50", "providerValue51", "providerValue52", "providerValue53", "providerValue54", "providerValue55", "providerValue56", "providerValue57", "providerValue58", "providerValue59", "providerValue60", "providerValue61", "providerValue62", "providerValue63", "providerValue64"
    ])
}

@Test func generatedFreestandingRegistryChunksPreserveRegistrationOrder() {
    #expect(largeFreestandingChunkRegistry.registrations.map(\.name) == [
        "registryValue00", "registryValue01", "registryValue02", "registryValue03", "registryValue04", "registryValue05", "registryValue06", "registryValue07", "registryValue08", "registryValue09", "registryValue10", "registryValue11", "registryValue12", "registryValue13", "registryValue14", "registryValue15", "registryValue16", "registryValue17", "registryValue18", "registryValue19", "registryValue20", "registryValue21", "registryValue22", "registryValue23", "registryValue24", "registryValue25", "registryValue26", "registryValue27", "registryValue28", "registryValue29", "registryValue30", "registryValue31", "registryValue32"
    ])
}
