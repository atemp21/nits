import Testing
@testable import NitsCore

// The DDC framing is the one piece of this project that can be tested without a
// monitor, a private API, or root. Worth pinning down precisely.

@Suite("DDC codec")
struct DDCCodecTests {

    @Test("set packet framing and checksum")
    func setPacket() {
        // Brightness (0x10) to 50.
        let packet = DDCCodec.setPacket(0x10, value: 50)
        #expect(packet.count == 6)
        #expect(packet[0] == 0x84)  // 0x80 | length 4
        #expect(packet[1] == 0x03)  // set VCP feature
        #expect(packet[2] == 0x10)
        #expect(packet[3] == 0x00)  // high byte
        #expect(packet[4] == 50)    // low byte

        // Checksum is XOR of the 0x6E^0x51 seed with every preceding byte.
        let expected = packet.dropLast().reduce(UInt8(0x6E ^ 0x51), ^)
        #expect(packet[5] == expected)
    }

    @Test("set packet carries 16-bit values across both bytes")
    func setPacketWideValue() {
        let packet = DDCCodec.setPacket(0x10, value: 0x1234)
        #expect(packet[3] == 0x12)
        #expect(packet[4] == 0x34)
    }

    @Test("get packet framing and checksum")
    func getPacket() {
        let packet = DDCCodec.getPacket(0x62)
        #expect(packet.count == 4)
        #expect(packet[0] == 0x82)  // 0x80 | length 2
        #expect(packet[1] == 0x01)  // get VCP feature
        #expect(packet[2] == 0x62)
        #expect(packet[3] == packet.dropLast().reduce(UInt8(0x6E ^ 0x51), ^))
    }

    /// Builds a well-formed VCP feature reply for tests.
    private func reply(
        code: UInt8, current: UInt16, maximum: UInt16, leading: [UInt8] = [], result: UInt8 = 0x00
    ) -> [UInt8] {
        var bytes = leading
        bytes += [
            0x88,  // 0x80 | length 8
            0x02,  // VCP feature reply
            result,
            code,
            0x00,  // value type
            UInt8(maximum >> 8), UInt8(maximum & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        bytes.append(bytes.reduce(UInt8(0x50 ^ 0x6E), ^))
        while bytes.count < 12 { bytes.append(0x00) }
        return bytes
    }

    @Test("parses a well-formed reply")
    func parseReply() throws {
        let reading = try DDCCodec.parseReply(
            reply(code: 0x10, current: 42, maximum: 100), expecting: 0x10)
        #expect(reading.current == 42)
        #expect(reading.maximum == 100)
        #expect(reading.code == 0x10)
    }

    @Test("parses regardless of a leading source-address byte")
    func parseReplyWithLeadingBytes() throws {
        // Implementations disagree about whether the buffer starts at the address
        // byte; the parser locates the 0x88 length marker instead of assuming.
        let withPrefix = try DDCCodec.parseReply(
            reply(code: 0x10, current: 42, maximum: 100, leading: [0x6E]), expecting: 0x10)
        #expect(withPrefix.current == 42)
        #expect(withPrefix.maximum == 100)
    }

    @Test("parses 16-bit current values")
    func parseWideValue() throws {
        let reading = try DDCCodec.parseReply(
            reply(code: 0x10, current: 0x0140, maximum: 0x0190), expecting: 0x10)
        #expect(reading.current == 0x0140)
        #expect(reading.maximum == 0x0190)
    }

    @Test("rejects a reply for a different feature")
    func rejectsWrongFeature() {
        #expect(throws: DDCError.self) {
            try DDCCodec.parseReply(
                reply(code: 0x12, current: 1, maximum: 100), expecting: 0x10)
        }
    }

    @Test("rejects a non-zero MCCS result code")
    func rejectsErrorResult() {
        // 0x01 means the panel does not support the requested VCP code.
        #expect(throws: DDCError.self) {
            try DDCCodec.parseReply(
                reply(code: 0x10, current: 0, maximum: 0, result: 0x01), expecting: 0x10)
        }
    }

    @Test("rejects an all-zero buffer")
    func rejectsEmptyBuffer() {
        #expect(throws: DDCError.self) {
            try DDCCodec.parseReply([UInt8](repeating: 0, count: 12), expecting: 0x10)
        }
    }

    @Test("rejects a truncated reply")
    func rejectsTruncated() {
        #expect(throws: DDCError.self) {
            try DDCCodec.parseReply([0x88, 0x02, 0x00], expecting: 0x10)
        }
    }
}

@Suite("Display identity")
struct DisplayIdentityTests {

    @Test("key is stable and includes every component")
    func keyIncludesComponents() {
        let identity = DisplayIdentity(
            vendor: 1129, model: 4660, serial: 7, location: "External")
        #expect(identity.key == "1129-4660-7-External")
    }

    @Test("degrades gracefully when the panel reports no serial")
    func keyWithoutSerial() {
        // Some Samsung EDIDs omit a usable serial; identity must still be formed.
        let identity = DisplayIdentity(
            vendor: 1129, model: 4660, serial: nil, location: "External")
        #expect(identity.key == "1129-4660-noserial-External")
    }

    @Test("different displays do not collide")
    func distinctIdentities() {
        let a = DisplayIdentity(vendor: 1129, model: 1, serial: nil, location: "External")
        let b = DisplayIdentity(vendor: 1129, model: 2, serial: nil, location: "External")
        #expect(a != b)
        #expect(a.key != b.key)
    }
}
