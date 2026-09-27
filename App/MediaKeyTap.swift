import AppKit
import NitsCore

/// Intercepts the keyboard's brightness and volume keys.
///
/// These arrive as `systemDefined` events with subtype 8 rather than ordinary key
/// events, and reading them requires Accessibility permission. The app must stay
/// usable without it — the panel's sliders work regardless — so this reports its state
/// instead of insisting.
@MainActor
final class MediaKeyTap {

    enum MediaKey {
        case brightnessUp, brightnessDown
        case volumeUp, volumeDown, mute
    }

    /// Called on the main actor for each intercepted press.
    var onKey: ((MediaKey, _ isFine: Bool, _ isRepeat: Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRunning = false

    // Apple's NX_KEYTYPE constants; not exposed in any Swift header.
    private enum KeyType {
        static let soundUp: Int32 = 0
        static let soundDown: Int32 = 1
        static let mute: Int32 = 7
        static let brightnessUp: Int32 = 2
        static let brightnessDown: Int32 = 3
    }

    // MARK: - Permission

    /// Whether Accessibility permission has been granted. Never prompts.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show the Accessibility prompt.
    static func requestAccessibilityPermission() {
        // The constant is imported as a mutable global and so is not concurrency-safe
        // to touch; its value is stable API, so use the string directly.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.hasAccessibilityPermission else { return false }

        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // must be a default tap to consume events
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Event handling

    private nonisolated func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long, or on user input. Re-arming
        // is mandatory: without it the app silently stops responding to keys.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        let key: MediaKey
        switch keyCode {
        case KeyType.brightnessUp: key = .brightnessUp
        case KeyType.brightnessDown: key = .brightnessDown
        case KeyType.soundUp: key = .volumeUp
        case KeyType.soundDown: key = .volumeDown
        case KeyType.mute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        guard isKeyDown else {
            // Consume the key-up too, so nothing downstream sees a half event.
            return nil
        }

        // macOS uses Shift+Option for fine adjustment; mirror that.
        let flags = nsEvent.modifierFlags
        let isFine = flags.contains(.shift) && flags.contains(.option)

        Task { @MainActor in
            self.onKey?(key, isFine, isRepeat)
        }

        return nil  // consumed: macOS must not also act on it
    }
}
