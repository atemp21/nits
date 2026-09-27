import Foundation
import CoreGraphics
import AppKit

/// Owns a controller per attached display and keeps the set current as displays come
/// and go.
///
/// Rebuilds wholesale on reconfiguration rather than diffing: `CGDirectDisplayID` is
/// not stable across reconnect, so the DDC channels and audio device ids have to be
/// re-derived anyway. Settings are reattached by `DisplayIdentity.key`.
public final class DisplayManager: @unchecked Sendable {

    public private(set) var controllers: [DisplayController] = []

    /// Called after the controller set changes, on the main queue.
    public var onControllersChanged: (@Sendable () -> Void)?

    public let preferences: PreferencesStore

    private let registry: DisplayRegistry
    private let api: PrivateDisplayAPI
    private let lock = NSLock()
    private let refreshQueue = DispatchQueue(label: "nits.refresh", qos: .userInitiated)
    private var isObserving = false

    public init(
        api: PrivateDisplayAPI = SystemPrivateAPI.shared,
        preferences: PreferencesStore = PreferencesStore()
    ) {
        self.api = api
        self.registry = DisplayRegistry(api: api)
        self.preferences = preferences
    }

    /// Builds controllers and reads their current hardware state.
    ///
    /// Reads are slow (~110ms each over DDC), so they happen off the main thread and
    /// `onControllersChanged` fires once the values are in.
    public func start() {
        rebuild()
        beginObservingReconfiguration()
        beginObservingWake()
    }

    public func controller(for displayID: CGDirectDisplayID) -> DisplayController? {
        lock.lock()
        defer { lock.unlock() }
        return controllers.first { $0.info.id == displayID }
    }

    public func controller(identityKey: String) -> DisplayController? {
        lock.lock()
        defer { lock.unlock() }
        return controllers.first { $0.info.identity.key == identityKey }
    }

    // MARK: - Building

    private func rebuild() {
        let displays = registry.displays()
        let built = displays.map { display in
            DisplayController(
                info: display,
                audioDevice: AudioControl.device(
                    forDisplayNamed: display.name, isBuiltIn: display.isBuiltIn),
                api: api)
        }

        lock.lock()
        controllers = built
        lock.unlock()

        notifyControllersChanged()

        refreshQueue.async { [weak self] in
            guard let self else { return }
            for controller in built {
                controller.refresh()
                self.restoreIfWanted(controller)
                self.observeForPersistence(controller)
            }
            self.notifyControllersChanged()
        }
    }

    // MARK: - Persistence

    /// Pushes stored levels back to a display that has just appeared.
    ///
    /// Monitors forget their level across a power cycle or an input switch, which is
    /// the main reason this exists. Runs after `refresh()` so a display with no stored
    /// settings simply keeps whatever it already had.
    private func restoreIfWanted(_ controller: DisplayController) {
        guard preferences.restoreOnConnect,
              let stored = preferences.settings(for: controller.info.identity.key)
        else { return }

        if let brightness = stored.brightness, controller.canSetBrightness {
            controller.setBrightness(brightness)
        }
        if let volume = stored.volume, controller.canSetVolume {
            controller.setVolume(volume)
        }
        if let muted = stored.isMuted, controller.canSetVolume {
            controller.setMuted(muted)
        }
    }

    private func observeForPersistence(_ controller: DisplayController) {
        // Seed immediately. Observers only fire on change, and refresh() has already
        // run by now, so without this a display's levels are never recorded until the
        // user happens to touch something — leaving restore-on-connect with nothing to
        // restore.
        persist(controller)

        controller.addStateObserver { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.persist(controller)
        }
    }

    /// Records only values known to reflect the hardware. A level that was never read
    /// must not be written down, or a failed read becomes a stored zero.
    private func persist(_ controller: DisplayController) {
        guard controller.hasBrightnessReading || controller.hasVolumeReading else { return }
        preferences.update(controller.info.identity.key) { settings in
            if controller.canSetBrightness, controller.hasBrightnessReading {
                settings.brightness = controller.brightness
            }
            if controller.canSetVolume, controller.hasVolumeReading {
                settings.volume = controller.volume
                settings.isMuted = controller.isMuted
            }
        }
    }

    // MARK: - Wake

    private func beginObservingWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    /// Re-applies known levels after sleep.
    ///
    /// A monitor commonly drops back to its own defaults across sleep, and since state
    /// here is optimistic the app would otherwise keep reporting a level the panel no
    /// longer has. Delayed because DDC is not reliable the instant a display wakes.
    private func handleWake() {
        refreshQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            for controller in self.controllers {
                self.restoreIfWanted(controller)
            }
        }
    }

    private func notifyControllersChanged() {
        guard let handler = onControllersChanged else { return }
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async { handler() }
        }
    }

    // MARK: - Reconfiguration

    private func beginObservingReconfiguration() {
        guard !isObserving else { return }
        isObserving = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, context)
    }

    fileprivate func handleReconfiguration() {
        // Displays report several times while a connection settles; coalesce so the
        // expensive rebuild runs once things are stable.
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private var rebuildWorkItem: DispatchWorkItem?
}

private func displayReconfigured(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // Only the events that can change which displays exist or how they connect.
    let relevant: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .enabledFlag, .disabledFlag, .setModeFlag,
    ]
    guard !flags.intersection(relevant).isEmpty else { return }

    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    manager.handleReconfiguration()
}
