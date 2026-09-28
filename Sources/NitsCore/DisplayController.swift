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

    /// Contrast has no native equivalent, so it exists only where DDC does.
    public enum ContrastBackend: String, Sendable {
        /// DDC VCP 0x12.
        case ddc
        case unavailable
    }

    public let info: DisplayInfo
    public let brightnessBackend: BrightnessBackend
    public let volumeBackend: VolumeBackend
    public let contrastBackend: ContrastBackend

    /// The audio device associated with this display, whether or not its volume is
    /// settable. Volume keys use this to target whichever display is actually playing.
    public let audioDeviceID: AudioDeviceID?

    /// Observers notified after state changes, on an arbitrary queue. Callers hop to
    /// their own queue. Several parties observe at once — the UI and the preference
    /// store — so this is a list rather than a single handler.
    private var stateObservers: [@Sendable () -> Void] = []

    public func addStateObserver(_ observer: @escaping @Sendable () -> Void) {
        stateLock.lock()
        stateObservers.append(observer)
        stateLock.unlock()
    }

    private func notifyStateChanged() {
        stateLock.lock()
        let observers = stateObservers
        stateLock.unlock()
        for observer in observers { observer() }
    }

    private let api: PrivateDisplayAPI
    private let stateLock = NSLock()

    private var _brightness: Float = 0
    private var _volume: Float = 0
    private var _isMuted = false
    private var _contrast: Float = 0

    /// Whether a real value was ever obtained from the hardware.
    ///
    /// Callers persist what they read, so an unread level must be distinguishable from
    /// a genuine zero. Without this a failed brightness read looks like 0, gets saved,
    /// and is restored onto the panel later — blacking out the display.
    private var _hasBrightnessReading = false
    private var _hasVolumeReading = false
    private var _hasContrastReading = false

    /// DDC reports its own scale; do not assume 100.
    private var brightnessMax: UInt16 = 100
    private var volumeMax: UInt16 = 100
    private var contrastMax: UInt16 = 100

    /// When this controller last changed a level itself. External syncs are skipped
    /// just after, so a read cannot land before our coalesced write and snap the level
    /// back to its old value.
    private var lastLocalWrite = Date.distantPast
    private static let syncQuietPeriod: TimeInterval = 1.0

    private let brightnessWriter: CoalescingWriter<Float>
    private let volumeWriter: CoalescingWriter<Float>
    private let muteWriter: CoalescingWriter<Bool>
    private let contrastWriter: CoalescingWriter<Float>

    public init(
        info: DisplayInfo,
        audioDevice: AudioDevice?,
        api: PrivateDisplayAPI = SystemPrivateAPI.shared
    ) {
        self.info = info
        self.api = api
        self.audioDeviceID = audioDevice?.id

        if info.isBuiltIn {
            brightnessBackend = api.canChangeNativeBrightness(info.id) ? .native : .unavailable
        } else {
            brightnessBackend = info.supportsDDC ? .ddc : .unavailable
        }

        // The built-in panel has no DDC channel at all, so contrast is external-only.
        contrastBackend = (!info.isBuiltIn && info.supportsDDC) ? .ddc : .unavailable

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
        var contrastApply: ((Float) -> Void)!

        brightnessWriter = CoalescingWriter(label: "nits.brightness.\(info.id)") {
            brightnessApply($0)
        }
        volumeWriter = CoalescingWriter(label: "nits.volume.\(info.id)") { volumeApply($0) }
        muteWriter = CoalescingWriter(label: "nits.mute.\(info.id)") { muteApply($0) }
        contrastWriter = CoalescingWriter(label: "nits.contrast.\(info.id)") {
            contrastApply($0)
        }

        brightnessApply = { [weak self] in self?.applyBrightness($0) }
        volumeApply = { [weak self] in self?.applyVolume($0) }
        muteApply = { [weak self] in self?.applyMute($0) }
        contrastApply = { [weak self] in self?.applyContrast($0) }
    }

    // MARK: - Observable state

    public var brightness: Float { stateLock.withLock { _brightness } }
    public var volume: Float { stateLock.withLock { _volume } }
    public var isMuted: Bool { stateLock.withLock { _isMuted } }

    public var contrast: Float { stateLock.withLock { _contrast } }

    public var canSetBrightness: Bool { brightnessBackend != .unavailable }
    public var canSetVolume: Bool { volumeBackend != .unavailable }
    public var canSetContrast: Bool { contrastBackend != .unavailable }

    /// True once brightness reflects the hardware, whether read or written.
    public var hasBrightnessReading: Bool { stateLock.withLock { _hasBrightnessReading } }
    public var hasVolumeReading: Bool { stateLock.withLock { _hasVolumeReading } }
    public var hasContrastReading: Bool { stateLock.withLock { _hasContrastReading } }

    // MARK: - Reading (once, on connect)

    /// Reads real values from the hardware. Blocking and slow (~110ms per DDC read),
    /// so callers must run this off the main thread.
    public func refresh() {
        switch brightnessBackend {
        case .native:
            if let value = api.nativeBrightness(info.id) {
                setLocal {
                    self._brightness = value
                    self._hasBrightnessReading = true
                }
            }
        case .ddc:
            if let reading = try? info.ddc?.get(.brightness, attempts: 3), reading.maximum > 0 {
                setLocal {
                    self.brightnessMax = reading.maximum
                    self._brightness = Float(reading.current) / Float(reading.maximum)
                    self._hasBrightnessReading = true
                }
            }
        case .unavailable:
            break
        }

        switch volumeBackend {
        case .coreAudio(let device):
            if let value = AudioControl.volume(device) {
                setLocal {
                    self._volume = value
                    self._hasVolumeReading = true
                }
            }
            if let muted = AudioControl.isMuted(device) {
                setLocal { self._isMuted = muted }
            }
        case .ddc:
            if let reading = try? info.ddc?.get(.audioVolume, attempts: 3), reading.maximum > 0 {
                setLocal {
                    self.volumeMax = reading.maximum
                    self._volume = Float(reading.current) / Float(reading.maximum)
                    self._hasVolumeReading = true
                }
            }
            // VCP 0x8D: 1 means muted, 2 means unmuted.
            if let reading = try? info.ddc?.get(.audioMute, attempts: 2) {
                setLocal { self._isMuted = reading.current == 1 }
            }
        case .unavailable:
            break
        }

        // Unlike brightness, contrast is genuinely optional in MCCS: a panel that does
        // not implement 0x12 answers with a non-zero result code, which the codec
        // rejects. That refusal is the only reliable signal we get, so the UI keys the
        // slider's existence off whether this read landed.
        if contrastBackend == .ddc,
           let reading = try? info.ddc?.get(.contrast, attempts: 3), reading.maximum > 0 {
            setLocal {
                self.contrastMax = reading.maximum
                self._contrast = Float(reading.current) / Float(reading.maximum)
                self._hasContrastReading = true
            }
        }

        notifyStateChanged()
    }

    // MARK: - Syncing with changes made elsewhere

    /// Adopts levels that something other than nits changed — macOS handling the
    /// brightness keys, Control Center, another app. Only the cheap local backends are
    /// read (DisplayServices and CoreAudio); DDC is never polled, so external DDC
    /// levels are still trusted to be whatever we last wrote.
    public func syncExternalChanges() {
        guard stateLock.withLock({
            Date().timeIntervalSince(lastLocalWrite) > Self.syncQuietPeriod
        }) else { return }

        var changed = false
        if brightnessBackend == .native, let value = api.nativeBrightness(info.id) {
            setLocal {
                if abs(self._brightness - value) > 0.005 || !self._hasBrightnessReading {
                    self._brightness = value
                    self._hasBrightnessReading = true
                    changed = true
                }
            }
        }
        if case .coreAudio(let device) = volumeBackend {
            let volume = AudioControl.volume(device)
            let muted = AudioControl.isMuted(device)
            setLocal {
                if let volume, abs(self._volume - volume) > 0.005 || !self._hasVolumeReading {
                    self._volume = volume
                    self._hasVolumeReading = true
                    changed = true
                }
                if let muted, muted != self._isMuted {
                    self._isMuted = muted
                    changed = true
                }
            }
        }
        if changed { notifyStateChanged() }
    }

    // MARK: - Writing (optimistic, coalesced)

    /// Sets brightness in 0...1. Returns immediately; the hardware write is coalesced.
    public func setBrightness(_ value: Float) {
        guard canSetBrightness else { return }
        let clamped = max(0, min(1, value))
        setLocal {
            self._brightness = clamped
            self._hasBrightnessReading = true
            self.lastLocalWrite = Date()
        }
        notifyStateChanged()
        brightnessWriter.submit(clamped)
    }

    public func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        let clamped = max(0, min(1, value))
        var unmutes = false
        setLocal {
            self._volume = clamped
            self._hasVolumeReading = true
            self.lastLocalWrite = Date()
            // Any deliberate volume change implies unmuting, matching macOS.
            if clamped > 0 && self._isMuted {
                self._isMuted = false
                unmutes = true
            }
        }
        notifyStateChanged()
        volumeWriter.submit(clamped)
        // The hardware must be told too: a muted device ignores its volume level, so
        // clearing only the local flag leaves the slider moving with no audible effect.
        if unmutes { muteWriter.submit(false) }
    }

    public func setMuted(_ muted: Bool) {
        guard canSetVolume else { return }
        setLocal {
            self._isMuted = muted
            self.lastLocalWrite = Date()
        }
        notifyStateChanged()
        muteWriter.submit(muted)
    }

    public func setContrast(_ value: Float) {
        guard canSetContrast else { return }
        let clamped = max(0, min(1, value))
        setLocal {
            self._contrast = clamped
            self._hasContrastReading = true
        }
        notifyStateChanged()
        contrastWriter.submit(clamped)
    }

    /// Nudges by a relative amount, for key presses. `step` is a fraction of full range.
    public func adjustBrightness(by step: Float) { setBrightness(brightness + step) }
    public func adjustVolume(by step: Float) { setVolume(volume + step) }

    /// Blocks until queued writes land. Tests and shutdown only.
    public func flush() {
        brightnessWriter.flush()
        volumeWriter.flush()
        muteWriter.flush()
        contrastWriter.flush()
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

    private func applyContrast(_ value: Float) {
        guard contrastBackend == .ddc else { return }
        let scaled = UInt16((value * Float(stateLock.withLock { contrastMax })).rounded())
        try? info.ddc?.set(.contrast, value: scaled)
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
