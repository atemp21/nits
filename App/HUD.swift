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

    /// How much of segment `index` is lit, 0...1. Fractional rather than rounded so
    /// every key press visibly moves the bar: a fine step is half a segment and a
    /// Shift+Option step an eighth, and whole segments would hide most of them.
    private func fill(ofSegment index: Int) -> CGFloat {
        guard !isMuted else { return 0 }
        return CGFloat(max(0, min(1, level * Float(segmentCount) - Float(index))))
    }

    private var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Clear glass shows whatever is behind it, so the content cannot rely on the
    /// light/dark appearance to contrast with it. White over a slight dim reads on any
    /// wallpaper, which is what macOS does for content on clear glass.
    private var ink: Color { glassAvailable ? .white : .primary }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(ink)
                .frame(height: 56)

            HStack(spacing: 3) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(ink.opacity(0.25))
                        Rectangle().fill(ink).frame(width: 8 * fill(ofSegment: index))
                    }
                    .frame(width: 8, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                }
            }
        }
        .shadow(color: .black.opacity(glassAvailable ? 0.25 : 0), radius: 3, y: 1)
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
        .frame(width: 200, height: 200)
        .background { HUDBackground(shape: shape, glass: glassAvailable) }
    }
}

/// Kept as a separate layer behind the content rather than applied to it: content
/// placed *inside* a glass effect is re-tinted by the system for vibrancy, which made
/// the icon and the filled level segments vanish.
private struct HUDBackground<S: Shape>: View {
    let shape: S
    let glass: Bool

    var body: some View {
        if #available(macOS 26, *), glass {
            Color.clear.glassEffect(.clear.tint(.black.opacity(0.18)), in: shape)
        } else {
            shape.fill(Material.thick)
        }
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
        // Glass draws its own edge and shadow; a window shadow on top doubles it.
        if #available(macOS 26, *) {
            panel.hasShadow = false
        } else {
            panel.hasShadow = true
        }
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        // The full frame, not the visible one, so the menu bar and Dock do not pull
        // the HUD off the screen's true centre.
        guard let frame = screen?.frame else { return }
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.midY - panel.frame.height / 2)
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
