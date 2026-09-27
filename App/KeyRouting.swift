import AppKit
import CoreAudio
import NitsCore

/// Decides which display a media key should act on.
///
/// Brightness and volume want different answers. Brightness should follow the user's
/// attention, so it targets the display holding the focused window. Volume should
/// follow the sound, so it targets whichever display owns the current default output
/// device — pressing volume-up while audio plays through the monitor must not adjust
/// the laptop speakers.
@MainActor
enum KeyRouting {

    static func brightnessTarget(among displays: [DisplayViewModel]) -> DisplayViewModel? {
        let candidates = displays.filter(\.canSetBrightness)
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }

        if let screen = focusedScreen() ?? screenUnderCursor(),
           let match = candidates.first(where: { $0.controller.info.id == screen.displayID }) {
            return match
        }
        return candidates[0]
    }

    static func volumeTarget(among displays: [DisplayViewModel]) -> DisplayViewModel? {
        let candidates = displays.filter(\.canSetVolume)
        guard !candidates.isEmpty else { return nil }

        if let defaultDevice = AudioControl.defaultOutputDeviceID(),
           let match = candidates.first(where: { $0.controller.audioDeviceID == defaultDevice }) {
            return match
        }
        // Nothing claims the default output; fall back to attention.
        return brightnessTarget(among: candidates) ?? candidates[0]
    }

    // MARK: - Screen resolution

    /// Screen containing the frontmost window.
    ///
    /// Uses the window list rather than the Accessibility API on purpose: this must
    /// keep working before the user grants Accessibility permission.
    private static func focusedScreen() -> NSScreen? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }

        let frontWindow = windows.first { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == frontmost.processIdentifier
                && (window[kCGWindowLayer as String] as? Int) == 0
        }
        guard let bounds = frontWindow?[kCGWindowBounds as String] as? [String: CGFloat],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }

        // Most overlapped screen wins, matching how macOS assigns a window to a display.
        return NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
    }

    private static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}

extension NSScreen {
    /// The CoreGraphics display id backing this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
