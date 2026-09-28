import SwiftUI
import AppKit

/// The on-screen level overlay.
///
/// macOS draws its own HUD, but it cannot show the level of a DDC display — and for a
/// monitor whose volume the system cannot read at all, it shows nothing useful. So we
/// draw our own on the display being adjusted, styled after the system's own: a wide
/// card in the top-right corner with a title, the device, and a continuous bar.
///
/// Built from plain shapes rather than AppKit controls, which keeps it renderable
/// offscreen for design review.
struct HUDView: View {
    static let size = CGSize(width: 300, height: 70)

    let title: String
    let deviceName: String
    let systemImage: String
    /// 0...1.
    let level: Float
    let isMuted: Bool

    /// Continuous rather than stepped, so every key press visibly moves the bar, down
    /// to a Shift+Option quarter step.
    private var fill: CGFloat {
        isMuted ? 0 : CGFloat(max(0, min(1, level)))
    }

    private var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(deviceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(isMuted ? .secondary : .primary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule().fill(.primary)
                            .frame(width: proxy.size.width * fill)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: Self.size.width, height: Self.size.height)
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
            Color.clear.glassEffect(.regular, in: shape)
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

    func show(
        title: String, deviceName: String, systemImage: String,
        level: Float, isMuted: Bool, on screen: NSScreen?
    ) {
        let view = HUDView(
            title: title, deviceName: deviceName, systemImage: systemImage,
            level: level, isMuted: isMuted)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: HUDView.size)

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
            contentRect: NSRect(origin: .zero, size: HUDView.size),
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
        // The visible frame, so the HUD sits just under the menu bar where the
        // system's own does, rather than behind it.
        guard let frame = screen?.visibleFrame else { return }
        let inset: CGFloat = 12
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - inset,
            y: frame.maxY - panel.frame.height - inset)
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
