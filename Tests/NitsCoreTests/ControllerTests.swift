import Testing
import Foundation
import CoreGraphics
@testable import NitsCore

/// Stands in for the whole private-API surface, and decodes the DDC packets it is
/// handed so tests can assert on what the hardware would actually have received.
final class FakePrivateAPI: PrivateDisplayAPI, @unchecked Sendable {
    let supportsDDC: Bool
    let supportsNativeBrightness = true

    private let lock = NSLock()
    private var _writes: [(code: UInt8, value: UInt16)] = []
    private var _nativeBrightness: Float = 0.5
    /// Value the fake panel reports, keyed by VCP code.
    var readValues: [UInt8: (current: UInt16, maximum: UInt16)] = [:]
    /// Last VCP code requested by a read, so a reply can be framed for it.
    private var lastRequestedCode: UInt8?

    /// When true, reads return a garbage frame, as a flaky panel does.
    var failReads = false
    /// Counts read attempts, to verify retry behaviour.
    private(set) var readAttempts = 0

    init(supportsDDC: Bool = true) { self.supportsDDC = supportsDDC }

    var writes: [(code: UInt8, value: UInt16)] { lock.withLock { _writes } }
    var nativeBrightnessValue: Float { lock.withLock { _nativeBrightness } }

    func makeAVService(for service: io_service_t) -> IOAVServiceRef? { "fake" as CFString }

    func writeI2C(
        _ service: IOAVServiceRef, chip: UInt32, offset: UInt32, bytes: [UInt8]
    ) -> IOReturn {
        lock.lock()
        defer { lock.unlock() }
        // Distinguish a get request (0x82/0x01) from a set (0x84/0x03).
        if bytes.count >= 3, bytes[1] == 0x01 {
            lastRequestedCode = bytes[2]
        } else if bytes.count >= 5, bytes[1] == 0x03 {
            _writes.append((code: bytes[2], value: UInt16(bytes[3]) << 8 | UInt16(bytes[4])))
        }
        return KERN_SUCCESS
    }

    func readI2C(
        _ service: IOAVServiceRef, chip: UInt32, offset: UInt32, count: Int
    ) -> (IOReturn, [UInt8]) {
        lock.lock()
        readAttempts += 1
        let code = lastRequestedCode ?? 0x10
        let reported = readValues[code] ?? (current: 0, maximum: 100)
        let shouldFail = failReads
        lock.unlock()

        if shouldFail {
            return (KERN_SUCCESS, [UInt8](repeating: 0, count: count))
        }

        var bytes: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, code, 0x00,
            UInt8(reported.maximum >> 8), UInt8(reported.maximum & 0xFF),
            UInt8(reported.current >> 8), UInt8(reported.current & 0xFF),
        ]
        bytes.append(bytes.reduce(0, ^))
        while bytes.count < count { bytes.append(0) }
        return (KERN_SUCCESS, bytes)
    }

    func nativeBrightness(_ display: CGDirectDisplayID) -> Float? { nativeBrightnessValue }

    func setNativeBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        lock.lock()
        _nativeBrightness = value
        lock.unlock()
        return true
    }

    func canChangeNativeBrightness(_ display: CGDirectDisplayID) -> Bool { true }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Minimal locked box. `Synchronization.Mutex` needs macOS 15 and this package
/// targets 14.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Helpers

private func makeDisplay(
    api: FakePrivateAPI, builtIn: Bool, ddc: Bool = true
) -> DisplayInfo {
    let channel = ddc
        ? DDCChannel(service: "fake" as CFString, api: api, interMessageDelay: 0)
        : nil
    return DisplayInfo(
        id: builtIn ? 1 : 3,
        identity: DisplayIdentity(
            vendor: 19501, model: 3870, serial: 809056048,
            location: builtIn ? nil : "External"),
        name: builtIn ? "Built-in Display" : "C34J79x",
        isBuiltIn: builtIn,
        ddc: channel)
}

private func audioDevice(settable: Bool) -> AudioDevice {
    AudioDevice(
        id: 42, name: "C34J79x", uid: "uid", transport: "DisplayPort",
        hasSettableVolume: settable, hasMute: settable, isDefaultOutput: true)
}

// MARK: - Tests

@Suite("Coalescing writer")
struct CoalescerTests {

    @Test("a burst collapses but the final value always lands")
    func burstCollapses() {
        let recorded = Locked<[Int]>([])
        let writer = CoalescingWriter<Int>(label: "test.burst") { value in
            // Simulate a slow hardware write so a burst overlaps it.
            Thread.sleep(forTimeInterval: 0.01)
            recorded.withLock { $0.append(value) }
        }

        for value in 1...50 { writer.submit(value) }
        writer.flush()

        let values = recorded.withLock { $0 }
        #expect(values.last == 50, "the newest value must always be written")
        #expect(values.count < 50, "a burst should coalesce, not queue every value")
        #expect(values == values.sorted(), "writes must stay in order")
    }

    @Test("an isolated value is written with no added latency")
    func singleValue() {
        let recorded = Locked<[Int]>([])
        let writer = CoalescingWriter<Int>(label: "test.single") { value in
            recorded.withLock { $0.append(value) }
        }
        writer.submit(7)
        writer.flush()
        #expect(recorded.withLock { $0 } == [7])
    }
}

@Suite("Display controller")
struct DisplayControllerTests {

    @Test("external display scales brightness onto the panel's own range")
    func externalBrightnessScaling() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false),
            audioDevice: nil, api: api)

        #expect(controller.brightnessBackend == .ddc)

        controller.setBrightness(0.5)
        controller.flush()

        #expect(api.writes.contains { $0.code == 0x10 && $0.value == 50 })
        #expect(controller.brightness == 0.5)
    }

    @Test("brightness uses the panel's reported maximum, not an assumed 100")
    func respectsReportedMaximum() {
        let api = FakePrivateAPI()
        // A panel that reports a 0-255 range.
        api.readValues[0x10] = (current: 128, maximum: 255)
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.refresh()
        controller.setBrightness(1.0)
        controller.flush()

        #expect(api.writes.contains { $0.code == 0x10 && $0.value == 255 })
    }

    @Test("built-in display uses the native backend, never DDC")
    func builtInUsesNative() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: true, ddc: false),
            audioDevice: nil, api: api)

        #expect(controller.brightnessBackend == .native)
        controller.setBrightness(0.25)
        controller.flush()

        #expect(api.nativeBrightnessValue == 0.25)
        #expect(api.writes.isEmpty, "the built-in panel must not be driven over DDC")
    }

    @Test("volume falls back to DDC when the audio device has no settable volume")
    func volumeFallsBackToDDC() {
        // This is the C34J79x case: audio plays over DisplayPort but the panel owns
        // the level, so CoreAudio cannot set it.
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false),
            audioDevice: audioDevice(settable: false), api: api)

        #expect(controller.volumeBackend == .ddc)
        controller.setVolume(0.45)
        controller.flush()
        #expect(api.writes.contains { $0.code == 0x62 && $0.value == 45 })
    }

    @Test("volume prefers CoreAudio when the device allows it")
    func volumePrefersCoreAudio() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false),
            audioDevice: audioDevice(settable: true), api: api)

        #expect(controller.volumeBackend == .coreAudio(42))
        controller.setVolume(0.45)
        controller.flush()
        #expect(
            !api.writes.contains { $0.code == 0x62 },
            "CoreAudio-capable devices must not be driven over DDC")
    }

    @Test("mute maps onto the MCCS encoding, where 1 is muted and 2 is not")
    func muteEncoding() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false),
            audioDevice: audioDevice(settable: false), api: api)

        controller.setMuted(true)
        controller.flush()
        #expect(api.writes.last?.code == 0x8D)
        #expect(api.writes.last?.value == 1)

        controller.setMuted(false)
        controller.flush()
        #expect(api.writes.last?.value == 2)
    }

    @Test("contrast scales onto the panel's own range")
    func contrastScaling() {
        let api = FakePrivateAPI()
        api.readValues[0x12] = (current: 75, maximum: 100)
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        #expect(controller.contrastBackend == .ddc)
        controller.refresh()
        #expect(abs(controller.contrast - 0.75) < 0.001)

        controller.setContrast(0.4)
        controller.flush()
        #expect(api.writes.contains { $0.code == 0x12 && $0.value == 40 })
    }

    @Test("the built-in panel offers no contrast, having no DDC channel")
    func builtInHasNoContrast() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: true, ddc: false),
            audioDevice: nil, api: api)

        #expect(controller.contrastBackend == .unavailable)
        controller.setContrast(0.5)
        controller.flush()
        #expect(api.writes.isEmpty)
    }

    @Test("state updates before the hardware write, so the UI never lags")
    func optimisticState() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.setBrightness(0.8)
        // Deliberately no flush: the reported value must already be current.
        #expect(controller.brightness == 0.8)
    }

    @Test("values are clamped to the valid range")
    func clamping() {
        let api = FakePrivateAPI()
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.setBrightness(5.0)
        #expect(controller.brightness == 1.0)
        controller.setBrightness(-2.0)
        #expect(controller.brightness == 0.0)
    }

    @Test("a display with neither backend reports itself uncontrollable")
    func noBackends() {
        let api = FakePrivateAPI(supportsDDC: false)
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false, ddc: false),
            audioDevice: nil, api: api)

        #expect(controller.brightnessBackend == .unavailable)
        #expect(controller.volumeBackend == .unavailable)
        #expect(!controller.canSetBrightness)
        #expect(!controller.canSetVolume)
        // Must not crash or write anything.
        controller.setBrightness(0.5)
        controller.flush()
        #expect(api.writes.isEmpty)
    }
}


@Suite("Failed reads")
struct FailedReadTests {

    /// Regression: a failed brightness read used to look like a genuine 0. That value
    /// was persisted and restored on the next connect, blacking out the display.
    @Test("a failed read is not mistaken for zero")
    func failedReadIsNotZero() {
        let api = FakePrivateAPI()
        api.failReads = true
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.refresh()

        #expect(!controller.hasBrightnessReading, "an unread level must not look valid")
        #expect(!controller.hasVolumeReading)
    }

    @Test("a successful read marks the level valid")
    func successfulReadIsValid() {
        let api = FakePrivateAPI()
        api.readValues[0x10] = (current: 80, maximum: 100)
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.refresh()

        #expect(controller.hasBrightnessReading)
        #expect(abs(controller.brightness - 0.8) < 0.001)
    }

    @Test("reads are retried before being given up on")
    func readsAreRetried() {
        let api = FakePrivateAPI()
        api.failReads = true
        let channel = DDCChannel(service: "fake" as CFString, api: api, interMessageDelay: 0)

        #expect(throws: DDCError.self) { try channel.get(.brightness, attempts: 3) }
        #expect(api.readAttempts == 3, "a flaky panel deserves more than one attempt")
    }

    /// The UI hides the contrast slider unless this is true, because a panel that does
    /// not implement 0x12 is indistinguishable from one that does except by its refusal
    /// to answer the read.
    @Test("an unanswered contrast read leaves contrast unreported")
    func unsupportedContrastHasNoReading() {
        let api = FakePrivateAPI()
        api.failReads = true
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.refresh()

        #expect(controller.canSetContrast, "the transport is there even if the panel refused")
        #expect(!controller.hasContrastReading)
    }

    @Test("a deliberate write makes the level authoritative despite a failed read")
    func writeEstablishesValidity() {
        let api = FakePrivateAPI()
        api.failReads = true
        let controller = DisplayController(
            info: makeDisplay(api: api, builtIn: false), audioDevice: nil, api: api)

        controller.refresh()
        #expect(!controller.hasBrightnessReading)

        controller.setBrightness(0.6)
        #expect(controller.hasBrightnessReading, "we know the level: we just set it")
    }
}
