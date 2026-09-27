import Foundation
import IOKit

/// DDC/CI (VESA MCCS) over I2C, via the IOAVService private transport.
public enum VCP: UInt8, CaseIterable, Sendable {
    case brightness = 0x10
    case contrast = 0x12
    case audioVolume = 0x62
    case audioMute = 0x8D
    case inputSource = 0x60

    public var label: String {
        switch self {
        case .brightness: return "brightness"
        case .contrast: return "contrast"
        case .audioVolume: return "audio volume"
        case .audioMute: return "audio mute"
        case .inputSource: return "input source"
        }
    }
}

public struct VCPReading: Sendable, Equatable {
    public let code: UInt8
    public let current: UInt16
    public let maximum: UInt16
    /// Raw reply bytes, kept so the probe can show exactly what the panel sent.
    public let raw: [UInt8]
}

public enum DDCError: Error, CustomStringConvertible {
    case unsupported
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    /// The panel answered, but not with a well-formed VCP feature reply.
    case malformedReply([UInt8])
    case checksumMismatch(expected: UInt8, got: UInt8, raw: [UInt8])
    case wrongFeature(expected: UInt8, got: UInt8)

    public var description: String {
        switch self {
        case .unsupported:
            return "DDC transport unavailable (IOAVService symbols missing)"
        case .writeFailed(let r):
            return "I2C write failed: \(String(format: "0x%08x", UInt32(bitPattern: r)))"
        case .readFailed(let r):
            return "I2C read failed: \(String(format: "0x%08x", UInt32(bitPattern: r)))"
        case .malformedReply(let bytes):
            return "malformed reply: \(bytes.hex)"
        case .checksumMismatch(let expected, let got, let raw):
            return String(
                format: "checksum mismatch (expected 0x%02x, got 0x%02x) in %@",
                expected, got, raw.hex)
        case .wrongFeature(let expected, let got):
            return String(format: "reply was for VCP 0x%02x, asked for 0x%02x", got, expected)
        }
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

/// Stateless DDC codec. Separated from I/O so the framing is unit-testable
/// without any hardware or private API present.
public enum DDCCodec {
    /// I2C address of the DDC/CI slave (7-bit 0x37 == 8-bit 0x6E).
    public static let chipAddress: UInt32 = 0x37
    public static let dataOffset: UInt32 = 0x51

    /// Checksum seed: destination address 0x6E XOR source address 0x51.
    private static let seed: UInt8 = 0x6E ^ 0x51

    public static func setPacket(_ code: UInt8, value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [
            0x84,  // 0x80 | payload length (4)
            0x03,  // "set VCP feature" opcode
            code,
            UInt8(value >> 8),
            UInt8(value & 0xFF),
        ]
        bytes.append(bytes.reduce(seed, ^))
        return bytes
    }

    public static func getPacket(_ code: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [
            0x82,  // 0x80 | payload length (2)
            0x01,  // "get VCP feature" opcode
            code,
        ]
        bytes.append(bytes.reduce(seed, ^))
        return bytes
    }

    /// Parses a VCP feature reply.
    ///
    /// Implementations disagree on whether the reply buffer includes a leading
    /// source-address byte, so rather than hardcoding an offset we locate the
    /// 0x88 length byte (0x80 | 8) and read relative to it. The raw bytes travel
    /// with the result either way, which is what makes the probe useful for
    /// working out a panel's actual quirks.
    public static func parseReply(_ buffer: [UInt8], expecting code: UInt8) throws -> VCPReading {
        guard let idx = buffer.firstIndex(where: { $0 == 0x88 }),
              idx + 9 < buffer.count
        else { throw DDCError.malformedReply(buffer) }

        guard buffer[idx + 1] == 0x02 else { throw DDCError.malformedReply(buffer) }
        // buffer[idx + 2] is the MCCS result code; non-zero means the panel
        // refused the feature (commonly 0x01 "unsupported VCP code").
        guard buffer[idx + 2] == 0x00 else { throw DDCError.malformedReply(buffer) }

        let replyCode = buffer[idx + 3]
        guard replyCode == code else {
            throw DDCError.wrongFeature(expected: code, got: replyCode)
        }

        let maximum = UInt16(buffer[idx + 5]) << 8 | UInt16(buffer[idx + 6])
        let current = UInt16(buffer[idx + 7]) << 8 | UInt16(buffer[idx + 8])

        return VCPReading(code: code, current: current, maximum: maximum, raw: buffer)
    }
}

/// Live DDC channel for one display.
public final class DDCChannel: @unchecked Sendable {
    private let service: IOAVServiceRef
    private let api: PrivateDisplayAPI
    private let lock = NSLock()

    /// DDC/CI requires a gap between transactions; panels drop messages otherwise.
    private static let interMessageDelay: TimeInterval = 0.05

    public init(service: IOAVServiceRef, api: PrivateDisplayAPI = SystemPrivateAPI.shared) {
        self.service = service
        self.api = api
    }

    public func set(_ code: UInt8, value: UInt16) throws {
        guard api.supportsDDC else { throw DDCError.unsupported }
        lock.lock()
        defer { lock.unlock() }

        let packet = DDCCodec.setPacket(code, value: value)
        let result = api.writeI2C(
            service, chip: DDCCodec.chipAddress, offset: DDCCodec.dataOffset, bytes: packet)
        guard result == kIOReturnSuccess else { throw DDCError.writeFailed(result) }
        Thread.sleep(forTimeInterval: Self.interMessageDelay)
    }

    public func get(_ code: UInt8) throws -> VCPReading {
        guard api.supportsDDC else { throw DDCError.unsupported }
        lock.lock()
        defer { lock.unlock() }

        let request = DDCCodec.getPacket(code)
        let written = api.writeI2C(
            service, chip: DDCCodec.chipAddress, offset: DDCCodec.dataOffset, bytes: request)
        guard written == kIOReturnSuccess else { throw DDCError.writeFailed(written) }

        Thread.sleep(forTimeInterval: Self.interMessageDelay)

        let (result, buffer) = api.readI2C(
            service, chip: DDCCodec.chipAddress, offset: DDCCodec.dataOffset, count: 12)
        guard result == kIOReturnSuccess else { throw DDCError.readFailed(result) }
        Thread.sleep(forTimeInterval: Self.interMessageDelay)

        return try DDCCodec.parseReply(buffer, expecting: code)
    }

    public func set(_ vcp: VCP, value: UInt16) throws { try set(vcp.rawValue, value: value) }
    public func get(_ vcp: VCP) throws -> VCPReading { try get(vcp.rawValue) }
}
