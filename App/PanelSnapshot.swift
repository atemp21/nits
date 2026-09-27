import SwiftUI
import AppKit

/// Renders the panel straight to a PNG, for design iteration and verification.
///
/// This needs no Screen Recording permission because nothing is captured from the
/// screen: SwiftUI draws the same view hierarchy the popover shows into an offscreen
/// bitmap. The one difference from the real thing is window chrome — the popover's
/// arrow and its vibrancy backdrop belong to AppKit, so a flat approximation of the
/// material stands in for them here.
@MainActor
enum PanelSnapshot {

    /// Parses `--render-panel <path>` and returns the destination, if requested.
    static func requestedPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--render-panel"),
              index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    static func render(model: AppModel, to path: String, scale: CGFloat = 2) -> Bool {
        let view = ControlPanelView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
            .background(Color(nsColor: .underPageBackgroundColor))

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
