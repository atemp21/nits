import SwiftUI
import NitsCore

/// Observable mirror of one `DisplayController`.
///
/// The controller already holds optimistic state, so this exists only to publish it
/// to SwiftUI. Writes go straight through; nothing waits on hardware.
@MainActor
final class DisplayViewModel: ObservableObject, Identifiable {
    let controller: DisplayController

    @Published var brightness: Float
    @Published var volume: Float
    @Published var isMuted: Bool
    @Published var contrast: Float

    /// Mirrored rather than computed, because it can turn true after the first DDC
    /// read lands. A computed property off the controller would not republish, and the
    /// slider would stay hidden on a panel that does support contrast.
    @Published var canSetContrast: Bool

    /// True while the user is dragging, so hardware-originated updates do not fight
    /// the slider under their cursor.
    private var isEditing = false

    nonisolated var id: String { controller.info.identity.key }
    var name: String { controller.info.name }
    var canSetBrightness: Bool { controller.canSetBrightness }
    var canSetVolume: Bool { controller.canSetVolume }

    /// Shown in the panel so it is obvious which transport a display is using.
    var backendSummary: String {
        let brightnessLabel: String
        switch controller.brightnessBackend {
        case .native: brightnessLabel = "native"
        case .ddc: brightnessLabel = "DDC"
        case .unavailable: brightnessLabel = "unavailable"
        }
        let volumeLabel: String
        switch controller.volumeBackend {
        case .coreAudio: volumeLabel = "CoreAudio"
        case .ddc: volumeLabel = "DDC"
        case .unavailable: volumeLabel = "no audio"
        }
        return "\(brightnessLabel) · \(volumeLabel)"
    }

    init(controller: DisplayController) {
        self.controller = controller
        self.brightness = controller.brightness
        self.volume = controller.volume
        self.isMuted = controller.isMuted
        self.contrast = controller.contrast
        // Contrast is optional in MCCS, so it is offered only once the panel has
        // actually answered a 0x12 read.
        self.canSetContrast = controller.canSetContrast && controller.hasContrastReading

        controller.addStateObserver { [weak self] in
            Task { @MainActor in self?.syncFromHardware() }
        }
    }

    func setBrightness(_ value: Float) {
        brightness = value
        controller.setBrightness(value)
    }

    func setVolume(_ value: Float) {
        volume = value
        if value > 0 { isMuted = false }
        controller.setVolume(value)
    }

    func setContrast(_ value: Float) {
        contrast = value
        controller.setContrast(value)
    }

    func toggleMute() {
        isMuted.toggle()
        controller.setMuted(isMuted)
    }

    func beginEditing() { isEditing = true }
    func endEditing() { isEditing = false }

    private func syncFromHardware() {
        guard !isEditing else { return }
        // Only adopt meaningful changes; DDC rounds to integers, so exact equality
        // would cause the slider to twitch on every refresh.
        if abs(brightness - controller.brightness) > 0.005 {
            brightness = controller.brightness
        }
        if abs(volume - controller.volume) > 0.005 {
            volume = controller.volume
        }
        if isMuted != controller.isMuted {
            isMuted = controller.isMuted
        }
        if abs(contrast - controller.contrast) > 0.005 {
            contrast = controller.contrast
        }
        let contrastAvailable = controller.canSetContrast && controller.hasContrastReading
        if canSetContrast != contrastAvailable {
            canSetContrast = contrastAvailable
        }
    }
}

/// Top-level app state: one view model per attached display.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayViewModel] = []

    @Published var restoreOnConnect: Bool {
        didSet { manager.preferences.restoreOnConnect = restoreOnConnect }
    }

    /// How far one media-key press moves a level.
    @Published var keyStep: KeyStep {
        didSet { manager.preferences.keyStep = keyStep }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            LaunchAtLogin.setEnabled(launchAtLogin)
            launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
        }
    }

    @Published var launchAtLoginNeedsApproval = false
    @Published var hasAccessibilityPermission = MediaKeyTap.hasAccessibilityPermission

    private let manager = DisplayManager()

    /// Flushes preferences on quit, where the debounced save would lose the last edit.
    func saveNow() { manager.preferences.saveNow() }

    func refreshPermissionState() {
        hasAccessibilityPermission = MediaKeyTap.hasAccessibilityPermission
    }

    init() {
        self.restoreOnConnect = true
        self.keyStep = .standard
        self.launchAtLogin = LaunchAtLogin.isEnabled
        manager.onControllersChanged = { [weak self] in
            Task { @MainActor in self?.rebuild() }
        }
        restoreOnConnect = manager.preferences.restoreOnConnect
        keyStep = manager.preferences.keyStep
        launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
        manager.start()
        rebuild()
    }

    private func rebuild() {
        let controllers = manager.controllers
        // Reuse a view model only when it still wraps the *same* controller instance.
        // A reconnect builds fresh controllers, and a stale view model would keep
        // writing to a dead DDC channel.
        let existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displays = controllers.map { controller in
            if let reusable = existing[controller.info.identity.key],
               reusable.controller === controller {
                return reusable
            }
            return DisplayViewModel(controller: controller)
        }
    }
}
