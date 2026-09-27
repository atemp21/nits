import SwiftUI
import AppKit

/// Renders the panel straight to a PNG, for design iteration and verification.
///
/// This needs no Screen Recording permission because nothing is captured from the
/// screen: SwiftUI draws the same view hierarchy the popover shows into an offscreen
/// bitmap. The one difference from the real thing is window chrome — the popover's
/// arrow and its vibrancy backdrop belong to AppKit, so a flat approximation of the
/// material stands in for them here.
///
/// Known limitation: `ImageRenderer` cannot draw AppKit-backed controls, so SwiftUI's
/// `Slider` appears as a placeholder. Layout, text, symbols and state are all
/// faithful. Two alternatives were tried and are worse: `cacheDisplay` renders the
/// controls but drops the SwiftUI text layers, and `CALayer.render(in:)` comes out
/// blank because SwiftUI has no layer contents until it draws on screen. Design new UI
/// (such as the HUD) in pure SwiftUI and it renders here in full.
@MainActor
enum PanelSnapshot {

    /// Parses `--render-panel <path>` and returns the destination, if requested.
    static func requestedPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--render-panel"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// Renders HUD variants side by side, for design review.
    static func renderHUDs(to path: String, scale: CGFloat = 2) -> Bool {
        let samples = HStack(spacing: 16) {
            HUDView(systemImage: "sun.max.fill", level: 0.75, isMuted: false)
            HUDView(systemImage: "speaker.wave.2.fill", level: 0.35, isMuted: false)
            HUDView(systemImage: "speaker.slash.fill", level: 0.35, isMuted: true)
            HUDView(systemImage: "sun.max.fill", level: 0.0, isMuted: false)
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))

        return renderView(AnyView(samples), to: path, scale: scale)
    }

    static func render(model: AppModel, to path: String, scale: CGFloat = 2) -> Bool {
        let view = ControlPanelView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
            .background(Color(nsColor: .underPageBackgroundColor))

        return renderView(AnyView(view), to: path, scale: scale)
    }

    private static func renderView(_ view: AnyView, to path: String, scale: CGFloat) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return false
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
            return true
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            return false
        }
    }
}
