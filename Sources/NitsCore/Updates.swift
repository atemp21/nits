import Foundation

/// A dotted numeric version, as in a release tag: `v0.2.0`, `0.2`, `1.10.3`.
///
/// Anything else, a pre-release suffix included, fails to parse. An update check
/// that cannot order two versions must offer nothing rather than guess.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Without trailing zeros, so `0.2` and `0.2.0` are equal.
    private let components: [Int]
    public let description: String

    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        description = trimmed
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// The parts of a GitHub release the updater needs.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    /// The release's page on GitHub, for when installing in place is not possible.
    public let pageURL: URL
    public let dmgURL: URL
    /// Lowercase hex. GitHub computes it on upload; older assets have none.
    public let dmgSHA256: String?

    public enum DecodeError: Error, Equatable {
        case notPublished
        case unreadableVersion(String)
        case noDiskImage
    }

    /// Decodes the body of `GET /repos/{owner}/{repo}/releases/latest`.
    public static func decode(githubRelease data: Data) throws -> ReleaseInfo {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard release.draft != true, release.prerelease != true else {
            throw DecodeError.notPublished
        }
        guard let version = AppVersion(release.tag_name) else {
            throw DecodeError.unreadableVersion(release.tag_name)
        }
        // https only: the download is checked before it is installed, but there is
        // no reason to fetch it over anything an on-path attacker can rewrite.
        guard let asset = release.assets.first(where: {
            $0.name.hasSuffix(".dmg") && $0.browser_download_url.scheme == "https"
        }) else {
            throw DecodeError.noDiskImage
        }
        var sha256: String?
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        }
        return ReleaseInfo(
            version: version, pageURL: release.html_url,
            dmgURL: asset.browser_download_url, dmgSHA256: sha256)
    }

    public init(version: AppVersion, pageURL: URL, dmgURL: URL, dmgSHA256: String?) {
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.dmgSHA256 = dmgSHA256
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
    }
}

/// When the next automatic update check should happen.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        // A last check in the future means the clock was moved back; without this
        // the checks would stop until it caught up.
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
    }
}
