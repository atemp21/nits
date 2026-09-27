import Foundation
import CoreAudio
import CoreGraphics

/// Live control surface for one display.
///
/// Holds optimistic local state: DDC reads cost over 100ms and are unreliable, so the
/// value is read once on connect and thereafter trusted to be whatever we last wrote.
/// Everything the UI binds to is here; the UI never talks to DDC directly.
public final class DisplayController: @unchecked Sendable {

    public enum BrightnessBackend: String, Sendable {
        /// DisplayServices, for the built-in panel.
        case native
        /// DDC VCP 0x10, for external displays.
        case ddc
        case unavailable
    }

    public enum VolumeBackend: Sendable, Equatable {
        /// Public CoreAudio HAL. Preferred whenever the device allows it.
        case coreAudio(AudioDeviceID)
        /// DDC VCP 0x62. Required for panels that own their own level — which
        /// includes the Samsung C34J79x; see docs/hardware.md.
        case ddc
        case unavailable

        public var isDDC: Bool { self == .ddc }
    }

    public let info: DisplayInfo
    public let brightnessBackend: BrightnessBackend
    public let volumeBackend: VolumeBackend

    /// Called after state changes, on an arbitrary queue. The UI hops to main itself.
    public var onStateChange: (@Sendable () -> Void)?

    private let api: PrivateDisplayAPI
    private let stateLock = NSLock()

    private var _brightness: Float = 0
    private var _volume: Float = 0
    private var _isMuted = false

    /// DDC reports its own scale; do not assume 100.
    private var brightnessMax: UInt16 = 100
    private var volumeMax: UInt16 = 100

    private let brightnessWriter: CoalescingWriter<Float>
    private let volumeWriter: CoalescingWriter<Float>
    private let muteWriter: CoalescingWriter<Bool>

    public init(
        info: DisplayInfo,
        audioDevice: AudioDevice?,
        api: PrivateDisplayAPI = SystemPrivateAPI.shared
    ) {
        self.info = info
        self.api = api

        if info.isBuiltIn {
            brightnessBackend = api.canChangeNativeBrightness(info.id) ? .native : .unavailable
        } else {
            brightnessBackend = info.supportsDDC ? .ddc : .unavailable
        }

        // Capability decides the volume path, never the display type. A monitor whose
        // audio device exposes a settable level is better served by CoreAudio; one
        // that does not must go over DDC.
        if let audioDevice, audioDevice.hasSettableVolume {
            volumeBackend = .coreAudio(audioDevice.id)
        } else if info.supportsDDC {
            volumeBackend = .ddc
        } else {
            volumeBackend = .unavailable
        }

        // Writers are created before the closures can run, so capture is safe.
        var brightnessApply: ((Float) -> Void)!
        var volumeApply: ((Float) -> Void)!
        var muteApply: ((Bool) -> Void)!

        brightnessWriter = CoalescingWriter(label: "nits.brightness.\(info.id)") {
            brightnessApply($0)
        }
        volumeWriter = CoalescingWriter(label: "nits.volume.\(info.id)") { volumeApply($0) }
        muteWriter = CoalescingWriter(label: "nits.mute.\(info.id)") { muteApply($0) }

        brightnessApply = { [weak self] in self?.applyBrightness($0) }
        volumeApply = { [weak self] in self?.applyVolume($0) }
        muteApply = { [weak self] in self?.applyMute($0) }
    }

    // MARK: - Observable state

    public var brightness: Float { stateLock.withLock { _brightness } }
    public var volume: Float { stateLock.withLock { _volume } }
    public var isMuted: Bool { stateLock.withLock { _isMuted } }

    public var canSetBrightness: Bool { brightnessBackend != .unavailable }
    public var canSetVolume: Bool { volumeBackend != .unavailable }

    // MARK: - Reading (once, on connect)

    /// Reads real values from the hardware. Blocking and slow (~110ms per DDC read),
    /// so callers must run this off the main thread.
    public func refresh() {
        switch brightnessBackend {
        case .native:
            if let value = api.nativeBrightness(info.id) {
                setLocal { self._brightness = value }
            }
        case .ddc:
            if let reading = try? info.ddc?.get(.brightness), reading.maximum > 0 {
                setLocal {
                    self.brightnessMax = reading.maximum
                    self._brightness = Float(reading.current) / Float(reading.maximum)
                }
            }
        case .unavailable:
            break
        }

        switch volumeBackend {
        case .coreAudio(let device):
            if let value = AudioControl.volume(device) {
                setLocal { self._volume = value }
            }
            if let muted = AudioControl.isMuted(device) {
                setLocal { self._isMuted = muted }
            }
        case .ddc:
            if let reading = try? info.ddc?.get(.audioVolume), reading.maximum > 0 {
                setLocal {
                    self.volumeMax = reading.maximum
                    self._volume = Float(reading.current) / Float(reading.maximum)
                }
            }
            // VCP 0x8D: 1 means muted, 2 means unmuted.
            if let reading = try? info.ddc?.get(.audioMute) {
                setLocal { self._isMuted = reading.current == 1 }
            }
        case .unavailable:
            break
        }

        onStateChange?()
    }

    // MARK: - Writing (optimistic, coalesced)

    /// Sets brightness in 0...1. Returns immediately; the hardware write is coalesced.
    public func setBrightness(_ value: Float) {
        guard canSetBrightness else { return }
        let clamped = max(0, min(1, value))
        setLocal { self._brightness = clamped }
        onStateChange?()
        brightnessWriter.submit(clamped)
    }

    public func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        let clamped = max(0, min(1, value))
        setLocal {
            self._volume = clamped
            // Any deliberate volume change implies unmuting, matching macOS.
            if clamped > 0 { self._isMuted = false }
        }
        onStateChange?()
        volumeWriter.submit(clamped)
    }

    public func setMuted(_ muted: Bool) {
        guard canSetVolume else { return }
        setLocal { self._isMuted = muted }
        onStateChange?()
        muteWriter.submit(muted)
    }

    /// Nudges by a relative amount, for key presses. `step` is a fraction of full range.
    public func adjustBrightness(by step: Float) { setBrightness(brightness + step) }
    public func adjustVolume(by step: Float) { setVolume(volume + step) }

    /// Blocks until queued writes land. Tests and shutdown only.
    public func flush() {
        brightnessWriter.flush()
        volumeWriter.flush()
        muteWriter.flush()
    }

    // MARK: - Hardware application

    private func applyBrightness(_ value: Float) {
        switch brightnessBackend {
        case .native:
            _ = api.setNativeBrightness(info.id, value)
        case .ddc:
            let scaled = UInt16((value * Float(stateLock.withLock { brightnessMax })).rounded())
            try? info.ddc?.set(.brightness, value: scaled)
        case .unavailable:
            break
        }
    }

    private func applyVolume(_ value: Float) {
        switch volumeBackend {
        case .coreAudio(let device):
            AudioControl.setVolume(device, value)
        case .ddc:
            let scaled = UInt16((value * Float(stateLock.withLock { volumeMax })).rounded())
            try? info.ddc?.set(.audioVolume, value: scaled)
        case .unavailable:
            break
        }
    }

    private func applyMute(_ muted: Bool) {
        switch volumeBackend {
        case .coreAudio(let device):
            AudioControl.setMuted(device, muted)
        case .ddc:
            try? info.ddc?.set(.audioMute, value: muted ? 1 : 2)
        case .unavailable:
            break
        }
    }

    private func setLocal(_ body: () -> Void) {
        stateLock.lock()
        body()
        stateLock.unlock()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
