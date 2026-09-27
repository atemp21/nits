import Foundation
import CoreGraphics

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

    private let registry: DisplayRegistry
    private let api: PrivateDisplayAPI
    private let lock = NSLock()
    private let refreshQueue = DispatchQueue(label: "nits.refresh", qos: .userInitiated)
    private var isObserving = false

    public init(api: PrivateDisplayAPI = SystemPrivateAPI.shared) {
        self.api = api
        self.registry = DisplayRegistry(api: api)
    }

    /// Builds controllers and reads their current hardware state.
    ///
    /// Reads are slow (~110ms each over DDC), so they happen off the main thread and
    /// `onControllersChanged` fires once the values are in.
    public func start() {
        rebuild()
        beginObservingReconfiguration()
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
            for controller in built {
                controller.refresh()
            }
            self?.notifyControllersChanged()
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
