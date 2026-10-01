import AppKit
import CryptoKit
import NitsCore
import UserNotifications

/// Finds new releases on GitHub and installs them in place.
///
/// There is no update server and no notarisation, so trust rests on the code
/// signature: a download is installed only if it satisfies the running copy's own
/// designated requirement, which means the same bundle id signed by the same
/// certificate. That is also exactly the condition under which the Accessibility
/// grant carries over. A copy built from source is signed by a different certificate,
/// so it is told about releases but sent to the release page rather than replaced.
///
/// Installing is always the user's click. An app holding Accessibility permission
/// should not swap its own binary unasked.
@MainActor
final class Updater: NSObject, ObservableObject {

    enum Activity: Equatable {
        case idle, checking, downloading, installing
    }

    nonisolated static let repository = "atemp21/nits"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var activity: Activity = .idle
    /// Outcome of the last thing the user asked for, shown in the panel.
    @Published private(set) var status: String?
    /// Set when installing in place failed, so the panel offers the release page.
    @Published private(set) var installFailed = false

    /// Called when the user clicks the notification itself rather than its button.
    var onShowPanel: (() -> Void)?

    let currentVersionString =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    private var currentVersion: AppVersion? { AppVersion(currentVersionString) }
    private let preferences: PreferencesStore
    private var timer: Timer?

    private static let notificationCategory = "nits.update"
    private static let installAction = "nits.update.install"

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    // MARK: - Checking

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.notificationCategory,
                actions: [UNNotificationAction(
                    identifier: Self.installAction, title: "Install and Relaunch")],
                intentIdentifiers: [])
        ])

        // Hourly, but only to ask whether a day has passed: a single 24-hour timer
        // would drift across sleep and restart from zero on every launch.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkIfDue()
    }

    private func checkIfDue() {
        // A debug build carries the placeholder version from project.yml, so every
        // launch would announce the latest release.
        #if !DEBUG
        guard preferences.automaticUpdateChecks,
              UpdateSchedule.isDue(lastCheck: preferences.lastUpdateCheck)
        else { return }
        Task { await check(userInitiated: false) }
        #endif
    }

    func check(userInitiated: Bool) async {
        guard activity == .idle else { return }
        activity = .checking
        defer { activity = .idle }
        if userInitiated {
            status = nil
            installFailed = false
        }

        do {
            let release = try await Self.fetchLatestRelease()
            // Recorded only on success, so a check made offline is retried within
            // the hour instead of tomorrow.
            preferences.lastUpdateCheck = Date()
            if let currentVersion, release.version > currentVersion {
                available = release
                if !userInitiated { await announce(release) }
            } else {
                available = nil
                if userInitiated { status = "nits \(currentVersionString) is the latest version." }
            }
        } catch {
            NSLog("nits: update check failed: \(error)")
            if userInitiated { status = "Could not check for updates." }
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try ReleaseInfo.decode(githubRelease: data)
    }

    // MARK: - Notification

    private func announce(_ release: ReleaseInfo) async {
        guard preferences.notifiedUpdateVersion != release.version.description else { return }
        let center = UNUserNotificationCenter.current()
        // Asked for only now, when there is something to say, rather than at first
        // launch. If it is refused the panel still shows the update.
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "nits \(release.version) is available"
        content.body = "You have \(currentVersionString). Install it from the nits menu-bar panel."
        content.categoryIdentifier = Self.notificationCategory
        do {
            try await center.add(UNNotificationRequest(
                identifier: Self.notificationCategory, content: content, trigger: nil))
            preferences.notifiedUpdateVersion = release.version.description
        } catch {
            NSLog("nits: update notification failed: \(error)")
        }
    }

    private func handleNotification(action: String) async {
        guard action == Self.installAction else {
            onShowPanel?()
            return
        }
        // Clicking the notification can also launch nits, in which case nothing has
        // been checked yet.
        if available == nil { await check(userInitiated: true) }
        install()
    }

    // MARK: - Installing

    func install() {
        guard let release = available, activity == .idle else { return }
        status = nil
        installFailed = false
        activity = .downloading

        Task {
            do {
                let (download, response) = try await URLSession.shared.download(from: release.dmgURL)
                defer { try? FileManager.default.removeItem(at: download) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }

                activity = .installing
                let bundle = Bundle.main.bundleURL
                let installed = currentVersion
                try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.install(
                        diskImage: download, release: release,
                        replacing: bundle, newerThan: installed)
                }.value
                relaunch()
            } catch {
                NSLog("nits: update failed: \(error)")
                activity = .idle
                status = error.localizedDescription
                installFailed = true
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(available?.pageURL ?? Self.releasesPage)
    }

    /// Hands the relaunch to a shell that outlives this process: it waits for this
    /// copy to exit, so two instances never hold the event tap at once.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; "
                + "do sleep 0.2; done; open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            activity = .idle
            status = "nits \(available?.version.description ?? "") is installed. Quit and reopen nits to use it."
        }
    }
}

extension Updater: UNUserNotificationCenterDelegate {
    // nonisolated: the system calls these off the main thread, which a method
    // inheriting the class's main-actor isolation would trap on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await handleNotification(action: action)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

enum UpdateError: LocalizedError {
    case server(Int)
    case checksumMismatch
    case tool(String, Int32)
    case noAppInDiskImage
    case signatureMismatch(OSStatus)
    case notNewer
    case translocated
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .server(let code):
            return "GitHub answered with status \(code)."
        case .checksumMismatch:
            return "The download was corrupted. Try again."
        case .tool(let name, let code):
            return "\(name) failed with status \(code)."
        case .noAppInDiskImage:
            return "The download does not contain nits."
        case .signatureMismatch:
            return "The download is not signed with the same certificate as this copy of "
                + "nits, so it was not installed. A copy built from source updates with "
                + "git pull and make install."
        case .notNewer:
            return "The download is not newer than this copy of nits."
        case .translocated:
            return "Move nits to the Applications folder, reopen it, then update."
        case .notWritable(let path):
            return "nits cannot replace itself in \(path)."
        }
    }
}

/// The blocking half of an update: verify, mount, copy, verify, swap. No UI state, so
/// it runs off the main actor.
enum UpdateInstaller {

    static func install(
        diskImage: URL, release: ReleaseInfo, replacing bundle: URL, newerThan installed: AppVersion?
    ) throws {
        let files = FileManager.default

        // Gatekeeper runs a quarantined app that was never moved from a read-only
        // randomised path, where there is nothing to replace.
        guard !bundle.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
        guard files.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable(bundle.deletingLastPathComponent().path)
        }

        // Catches a truncated download early. It is not the security check: the
        // digest and the image come from the same place.
        if let expected = release.dmgSHA256 {
            let digest = SHA256.hash(data: try Data(contentsOf: diskImage, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
                throw UpdateError.checksumMismatch
            }
        }

        let mount = files.temporaryDirectory.appendingPathComponent("nits-update-\(UUID().uuidString)")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: mount) }

        try run("/usr/bin/hdiutil", [
            "attach", diskImage.path, "-mountpoint", mount.path,
            "-nobrowse", "-readonly", "-noautoopen", "-quiet",
        ])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }

        guard let source = try files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError.noAppInDiskImage }

        // Staged on the destination's volume so the final step is a rename, and
        // verified there: the copy that was checked is the copy that gets installed.
        let staging = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(bundle.lastPathComponent)
        try files.copyItem(at: source, to: staged)

        try verifySignatureMatchesRunningApp(staged)
        // Refuses an older, genuinely signed release being served as the latest.
        guard let version = (Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"]
                             as? String).flatMap(AppVersion.init),
              installed.map({ version > $0 }) ?? true
        else { throw UpdateError.notNewer }

        do {
            _ = try files.replaceItemAt(bundle, withItemAt: staged, options: .usingNewMetadataOnly)
        } catch {
            NSLog("nits: replacing \(bundle.path) failed: \(error)")
            throw UpdateError.notWritable(bundle.deletingLastPathComponent().path)
        }
    }

    /// Checks `candidate` against the designated requirement of the running app. An
    /// ad-hoc or unsigned running copy has no requirement another build could meet,
    /// so this fails for those, which is the intent.
    static func verifySignatureMatchesRunningApp(_ candidate: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidateCode: SecStaticCode?

        var status = SecCodeCopySelf([], &running)
        if status == errSecSuccess, let running {
            status = SecCodeCopyStaticCode(running, [], &runningStatic)
        }
        if status == errSecSuccess, let runningStatic {
            status = SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement)
        }
        if status == errSecSuccess {
            status = SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode)
        }
        guard status == errSecSuccess, let requirement, let candidateCode else {
            throw UpdateError.signatureMismatch(status)
        }

        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(candidateCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signatureMismatch(status) }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.tool((tool as NSString).lastPathComponent, process.terminationStatus)
        }
    }
}
