import SwiftUI
import AppKit

// Menu-bar agent entry point.
//
// Deliberately AppKit-hosted rather than SwiftUI's MenuBarExtra: MenuBarExtra stutters
// on continuously-dragged sliders, which is most of what this app is.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = AppModel()
    private let keyTap = MediaKeyTap()
    private let hud = HUDController()
    /// Runs only while the panel is open, so its sliders track changes made elsewhere.
    private var syncTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "sun.max", accessibilityDescription: "nits")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient  // dismisses on click-away, like a menu
        popover.animates = false
        popover.delegate = self
        // Without .preferredContentSize the popover is positioned for its default
        // 320x320, then shrinks to the SwiftUI height with its bottom edge pinned,
        // leaving a gap between the arrow and the menu bar.
        let hosting = NSHostingController(rootView: ControlPanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        startKeyTap()

        // Dev affordance: lets the panel be opened without synthesising a click.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.togglePanel()
            }
        }

        // Renders the panel to a PNG and exits. The delay lets the initial DDC reads
        // land, so the snapshot shows real hardware values rather than zeroes.
        if let index = CommandLine.arguments.firstIndex(of: "--render-hud"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                let ok = PanelSnapshot.renderHUDs(to: path)
                exit(ok ? 0 : 1)
            }
            return
        }

        if let path = PanelSnapshot.requestedPath(from: CommandLine.arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [model] in
                let ok = PanelSnapshot.render(model: model, to: path)
                NSApp.terminate(nil)
                exit(ok ? 0 : 1)
            }
        }
    }

    // MARK: - Media keys

    private func startKeyTap() {
        keyTap.onKey = { [weak self] key, isFine, _ in
            self?.handle(key: key, isFine: isFine)
        }

        guard !keyTap.start() else { return }

        // Not granted yet. The app stays fully usable through the panel; prompt once,
        // then poll for the grant so the tap starts without needing a relaunch.
        MediaKeyTap.requestAccessibilityPermission()
        waitForAccessibilityPermission()
    }

    private func waitForAccessibilityPermission() {
        guard !keyTap.isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.keyTap.isRunning else { return }
            if MediaKeyTap.hasAccessibilityPermission {
                self.keyTap.start()
            } else {
                self.waitForAccessibilityPermission()
            }
        }
    }

    private func handle(key: MediaKeyTap.MediaKey, isFine: Bool) {
        // Step from the real level, not a stale one, in case it changed elsewhere.
        model.syncExternalChanges()
        let keyStep = model.keyStep
        let step = isFine ? keyStep.fineFraction : keyStep.fraction

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let target = KeyRouting.brightnessTarget(among: model.displays) else { return }
            let delta = key == .brightnessUp ? step : -step
            target.setBrightness(target.brightness + delta)
            showHUD(for: target, isBrightness: true)

        case .volumeUp, .volumeDown:
            guard let target = KeyRouting.volumeTarget(among: model.displays) else { return }
            let delta = key == .volumeUp ? step : -step
            target.setVolume(target.volume + delta)
            showHUD(for: target, isBrightness: false)

        case .mute:
            guard let target = KeyRouting.volumeTarget(among: model.displays) else { return }
            target.toggleMute()
            showHUD(for: target, isBrightness: false)
        }
    }

    private func showHUD(for display: DisplayViewModel, isBrightness: Bool) {
        let screen = NSScreen.screens.first { $0.displayID == display.controller.info.id }
        if isBrightness {
            hud.show(
                title: "Brightness", deviceName: display.name,
                systemImage: "sun.max.fill", level: display.brightness,
                isMuted: false, on: screen)
        } else {
            hud.show(
                title: "Volume", deviceName: display.name,
                systemImage: display.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                level: display.volume, isMuted: display.isMuted, on: screen)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshPermissionState()
            model.syncExternalChanges()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this the popover cannot take key events reliably.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

extension AppDelegate {
    func popoverDidShow(_ notification: Notification) {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.syncExternalChanges() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
