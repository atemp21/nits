import Foundation
import IOKit
import CoreGraphics

/// The ONLY file in this project that touches undeclared Apple symbols.
///
/// Every symbol is resolved at runtime with `dlopen`/`dlsym` rather than bound at
/// link time. That is deliberate: if Apple removes or renames one of these in a
/// future macOS, the affected feature degrades to unavailable and the app still
/// launches. Link-time binding would instead make the whole binary fail to start,
/// which is how comparable tools have broken across OS upgrades.
///
/// Verified present on macOS 26.6.2 (Darwin 25.6.0), arm64.

public typealias IOAVServiceRef = CFTypeRef

// MARK: - Function signatures

private typealias FnCreateWithService = @convention(c) (
    CFAllocator?, io_service_t
) -> Unmanaged<CFTypeRef>?

private typealias FnWriteI2C = @convention(c) (
    IOAVServiceRef, UInt32, UInt32, UnsafeRawPointer, UInt32
) -> IOReturn

private typealias FnReadI2C = @convention(c) (
    IOAVServiceRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
) -> IOReturn

private typealias FnGetBrightness = @convention(c) (
    CGDirectDisplayID, UnsafeMutablePointer<Float>
) -> Int32

private typealias FnSetBrightness = @convention(c) (
    CGDirectDisplayID, Float
) -> Int32

private typealias FnCanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

// MARK: - Protocol seam (lets tests fake the whole private surface)

public protocol PrivateDisplayAPI: Sendable {
    /// True when the DDC/I2C symbols resolved. Nothing DDC-related works without it.
    var supportsDDC: Bool { get }
    /// True when the DisplayServices brightness symbols resolved (built-in panel).
    var supportsNativeBrightness: Bool { get }

    func makeAVService(for service: io_service_t) -> IOAVServiceRef?
    func writeI2C(_ service: IOAVServiceRef, chip: UInt32, offset: UInt32, bytes: [UInt8]) -> IOReturn
    func readI2C(_ service: IOAVServiceRef, chip: UInt32, offset: UInt32, count: Int) -> (IOReturn, [UInt8])

    func nativeBrightness(_ display: CGDirectDisplayID) -> Float?
    func setNativeBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Bool
    func canChangeNativeBrightness(_ display: CGDirectDisplayID) -> Bool
}

// MARK: - Real implementation

public final class SystemPrivateAPI: PrivateDisplayAPI, @unchecked Sendable {
    public static let shared = SystemPrivateAPI()

    private let createWithService: FnCreateWithService?
    private let writeFn: FnWriteI2C?
    private let readFn: FnReadI2C?
    private let getBrightnessFn: FnGetBrightness?
    private let setBrightnessFn: FnSetBrightness?
    private let canChangeBrightnessFn: FnCanChangeBrightness?

    /// Symbols that failed to resolve, for the probe to report.
    public let missingSymbols: [String]

    private static let ioKitPath =
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"
    private static let displayServicesPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private init() {
        var missing: [String] = []

        // RTLD_NOLOAD-friendly: IOKit is already resident in every process.
        let ioKit = dlopen(Self.ioKitPath, RTLD_LAZY)
        let ds = dlopen(Self.displayServicesPath, RTLD_LAZY)

        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let ptr = dlsym(handle, name) else {
                missing.append(name)
                return nil
            }
            return unsafeBitCast(ptr, to: type)
        }

        createWithService = sym(ioKit, "IOAVServiceCreateWithService", FnCreateWithService.self)
        writeFn = sym(ioKit, "IOAVServiceWriteI2C", FnWriteI2C.self)
        readFn = sym(ioKit, "IOAVServiceReadI2C", FnReadI2C.self)
        getBrightnessFn = sym(ds, "DisplayServicesGetBrightness", FnGetBrightness.self)
        setBrightnessFn = sym(ds, "DisplayServicesSetBrightness", FnSetBrightness.self)
        canChangeBrightnessFn = sym(ds, "DisplayServicesCanChangeBrightness", FnCanChangeBrightness.self)

        missingSymbols = missing
    }

    public var supportsDDC: Bool {
        createWithService != nil && writeFn != nil && readFn != nil
    }

    public var supportsNativeBrightness: Bool {
        getBrightnessFn != nil && setBrightnessFn != nil
    }

    public func makeAVService(for service: io_service_t) -> IOAVServiceRef? {
        guard let createWithService else { return nil }
        return createWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    public func writeI2C(
        _ service: IOAVServiceRef, chip: UInt32, offset: UInt32, bytes: [UInt8]
    ) -> IOReturn {
        guard let writeFn else { return kIOReturnUnsupported }
        return bytes.withUnsafeBytes { raw in
            writeFn(service, chip, offset, raw.baseAddress!, UInt32(bytes.count))
        }
    }

    public func readI2C(
        _ service: IOAVServiceRef, chip: UInt32, offset: UInt32, count: Int
    ) -> (IOReturn, [UInt8]) {
        guard let readFn else { return (kIOReturnUnsupported, []) }
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { raw in
            readFn(service, chip, offset, raw.baseAddress!, UInt32(count))
        }
        return (result, buffer)
    }

    public func nativeBrightness(_ display: CGDirectDisplayID) -> Float? {
        guard let getBrightnessFn else { return nil }
        var value: Float = 0
        guard getBrightnessFn(display, &value) == 0 else { return nil }
        return value
    }

    public func setNativeBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setBrightnessFn else { return false }
        return setBrightnessFn(display, max(0, min(1, value))) == 0
    }

    public func canChangeNativeBrightness(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightnessFn?(display) ?? false
    }
}
