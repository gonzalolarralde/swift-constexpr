import PacketKit
import Testing

@Test(arguments: [UInt8(0), 7, 255])
func mixedPacketMatchesTheOrdinaryBuilder(opcode: UInt8) {
    let payload: [UInt8] = [10, 20]
    let bytes = #packetBytes {
        let marker: UInt16 = 0xCAFE
        Packet.UInt16(marker, order: .bigEndian)
        Packet.UInt8(opcode)
        Packet.Bytes(payload)
        Packet.UInt16(0xBEEF, order: .bigEndian)
    }
    #expect(bytes == Packet.encode {
        Packet.UInt16(0xCAFE, order: .bigEndian)
        Packet.UInt8(opcode)
        Packet.Bytes(payload)
        Packet.UInt16(0xBEEF, order: .bigEndian)
    })
}

@Test func partialPacketsPreserveEvaluationOrderAndEvaluateDynamicBindingsOnce() {
    var events: [String] = []
    func read(_ event: String, _ value: UInt8) -> UInt8 {
        events.append(event)
        return value
    }
    let bytes = #packetBytes {
        Packet.UTF8("PKT")
        Packet.UInt8(read("first", 1))
        let middle = read("binding", 2)
        Packet.UInt8(middle)
        Packet.UInt8(middle)
        let _ = read("discarded", 99)
        Packet.UInt16(0xCAFE, order: .bigEndian)
        Packet.UInt8(read("last", 3))
        Packet.UTF8("END")
    }
    #expect(bytes == [80, 75, 84, 1, 2, 2, 202, 254, 3, 69, 78, 68])
    #expect(events == ["first", "binding", "discarded", "last"])
}

@Test func constantArgumentsInsideConsumerHelpersAreCompatibleWithRuntimeValues() {
    var calls = 0
    func combine(_ prefix: [UInt8], _ suffix: [UInt8]) -> [UInt8] {
        calls += 1
        return prefix + suffix
    }
    let payload: [UInt8] = [9, 8]
    let bytes = #packetBytes {
        combine(Packet.UTF8("AB"), payload)
        Packet.UInt8(0xFF)
    }
    #expect(bytes == [65, 66, 9, 8, 255])
    #expect(calls == 1)
}

@Test func dynamicTupleBindingRemainsAnOrdinarySwiftDeclaration() {
    var calls = 0
    func pair() -> (UInt8, UInt8) { calls += 1; return (7, 8) }
    let bytes = #packetBytes {
        Packet.UTF8("AB")
        let (left, right) = pair()
        Packet.UInt8(left)
        Packet.UInt8(right)
    }
    #expect(bytes == [65, 66, 7, 8])
    #expect(calls == 1)
}

@Test func outerBuilderTypeAliasesDoNotChangeTheLibraryOwnedBuilder() {
    typealias PacketBuilder = Int
    let opcode: UInt8 = 7
    let bytes = #packetBytes {
        Packet.UTF8("AB")
        Packet.UInt8(opcode)
    }
    #expect(PacketBuilder.max > 0)
    #expect(bytes == [65, 66, 7])
}
