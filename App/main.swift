import SwiftUI
import AppKit

// Menu-bar agent entry point.
//
// Deliberately AppKit-hosted rather than SwiftUI's MenuBarExtra: MenuBarExtra stutters
// on continuously-dragged sliders, which is most of what this app is.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = AppModel()

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
        popover.contentViewController = NSHostingController(
            rootView: ControlPanelView(model: model))

        // Dev affordance: lets the panel be opened without synthesising a click.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.togglePanel()
            }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this the popover cannot take key events reliably.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
