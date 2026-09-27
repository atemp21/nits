import SwiftUI
import AppKit

/// The on-screen level overlay.
///
/// macOS draws its own HUD, but it cannot show the level of a DDC display — and for a
/// monitor whose volume the system cannot read at all, it shows nothing useful. So we
/// draw our own on the display being adjusted.
///
/// Built from plain shapes rather than AppKit controls, which keeps it renderable
/// offscreen for design review.
struct HUDView: View {
    let systemImage: String
    /// 0...1.
    let level: Float
    let isMuted: Bool

    private let segmentCount = 16

    private var filledSegments: Int {
        isMuted ? 0 : Int((level * Float(segmentCount)).rounded())
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.primary)
                .frame(height: 56)

            HStack(spacing: 3) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filledSegments ? Color.primary : Color.primary.opacity(0.22))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
        .frame(width: 200, height: 200)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Material.thick))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Borderless panel that shows the HUD on a chosen screen and fades itself out.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private let visibleDuration: TimeInterval = 1.0

    func show(systemImage: String, level: Float, isMuted: Bool, on screen: NSScreen?) {
        let view = HUDView(systemImage: systemImage, level: level, isMuted: isMuted)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)

        let panel = existingPanel()
        panel.contentView = hosting
        position(panel, on: screen ?? NSScreen.main)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        scheduleDismiss()
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            // Non-activating is essential: showing the HUD must never steal focus
            // from whatever the user is working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        // Roughly where macOS puts its own HUD: horizontally centred, low.
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + frame.height * 0.12)
        panel.setFrameOrigin(origin)
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }
}
