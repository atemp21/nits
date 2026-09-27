import Foundation

/// Last known level for one display.
public struct DisplaySettings: Codable, Equatable, Sendable {
    public var brightness: Float?
    public var volume: Float?
    public var isMuted: Bool?

    public init(brightness: Float? = nil, volume: Float? = nil, isMuted: Bool? = nil) {
        self.brightness = brightness
        self.volume = volume
        self.isMuted = isMuted
    }
}

/// Persisted per-display state, keyed by `DisplayIdentity.key` rather than by
/// `CGDirectDisplayID`, which changes across reconnects.
///
/// Writes are debounced: dragging a slider would otherwise hit the disk hundreds of
/// times a second.
public final class PreferencesStore: @unchecked Sendable {

    public struct Root: Codable, Equatable, Sendable {
        public var displays: [String: DisplaySettings] = [:]
        /// Whether to push stored levels back to a display when it reconnects.
        public var restoreOnConnect: Bool = true
    }

    private let url: URL
    private let lock = NSLock()
    private var root: Root
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "nits.prefs", qos: .utility)

    public static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("nits/settings.json")
    }()

    public init(url: URL = PreferencesStore.defaultURL) {
        self.url = url
        self.root = Self.load(from: url) ?? Root()
    }

    // MARK: - Access

    public var restoreOnConnect: Bool {
        get { lock.withLock { root.restoreOnConnect } }
        set {
            lock.withLock { root.restoreOnConnect = newValue }
            scheduleSave()
        }
    }

    public func settings(for key: String) -> DisplaySettings? {
        lock.withLock { root.displays[key] }
    }

    public func update(_ key: String, _ mutate: (inout DisplaySettings) -> Void) {
        lock.lock()
        var settings = root.displays[key] ?? DisplaySettings()
        mutate(&settings)
        root.displays[key] = settings
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> Root? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Root.self, from: data)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately. Called on termination, where a debounce would lose data.
    public func saveNow() {
        let snapshot = lock.withLock { root }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // Losing preferences must never take the app down.
            NSLog("nits: failed to save preferences: \(error)")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
